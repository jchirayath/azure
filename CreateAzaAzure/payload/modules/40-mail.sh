#!/usr/bin/env bash
# Postfix as an AUTHENTICATED submission relay (587 + cyrus SASL + TLS) that signs
# outbound with OpenDKIM and delivers directly (port 25 out). NOT an open relay.
# Multi-domain: signs/sends for every domain in MAIL_DOMAINS (space/comma list;
# first is primary/myorigin). Each domain gets its own DKIM key + selector.
set -uo pipefail
source "$AZA_HOME/lib/remote.sh"

FQDN="$(vm_fqdn)"
[[ -z "$FQDN" || "$FQDN" == *localhost* ]] && die "Invalid FQDN: $FQDN"
SELECTOR="mail"
# Domains this relay signs/sends for. Default: the custom domain's parent zone.
DOMAINS="${MAIL_DOMAINS:-${MAIL_DOMAIN:-${CUSTOM_FQDN#*.}}}"
DOMAINS="${DOMAINS//,/ }"
[[ -z "${DOMAINS// }" ]] && DOMAINS="$FQDN"
PRIMARY="$(echo "$DOMAINS" | awk '{print $1}')"

log "Installing Postfix + SASL + OpenDKIM (relay domains: $DOMAINS)..."
sudo debconf-set-selections <<< "postfix postfix/mailname string $FQDN"
sudo debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"
apt_install postfix mailutils certbot sasl2-bin libsasl2-modules opendkim opendkim-tools

# --- TLS cert (reuse nginx's if present) -------------------------------------
if [[ -n "${MAIL_USER:-}" && ! -d "/etc/letsencrypt/live/$FQDN" ]]; then
  sudo certbot certonly --standalone -d "$FQDN" --non-interactive --agree-tos -m "$MAIL_USER" \
    || warn "Could not obtain mail certificate; STARTTLS may be limited."
fi
if [[ -f "/etc/letsencrypt/live/$FQDN/fullchain.pem" ]]; then
  sudo postconf -e "smtpd_tls_cert_file=/etc/letsencrypt/live/$FQDN/fullchain.pem"
  sudo postconf -e "smtpd_tls_key_file=/etc/letsencrypt/live/$FQDN/privkey.pem"
fi

# --- SASL (cyrus sasldb, dedicated relay user — not system accounts) ----------
RELAY_PW="$(kv_get mailRelayPassword)"
if [[ -n "$RELAY_PW" ]]; then
  sudo mkdir -p /etc/postfix/sasl
  sudo tee /etc/postfix/sasl/smtpd.conf >/dev/null <<EOF
pwcheck_method: auxprop
auxprop_plugin: sasldb
mech_list: PLAIN LOGIN
EOF
  echo "$RELAY_PW" | sudo saslpasswd2 -p -c -u "$FQDN" relay
  sudo chgrp postfix /etc/sasldb2 && sudo chmod 640 /etc/sasldb2
  sudo adduser postfix sasl >/dev/null 2>&1 || true
else
  warn "mailRelayPassword not in Key Vault — submission auth will have no users."
fi

# --- OpenDKIM: one key+selector per relay domain ------------------------------
sudo mkdir -p /etc/opendkim
: | sudo tee /etc/opendkim/KeyTable >/dev/null
: | sudo tee /etc/opendkim/SigningTable >/dev/null
{ echo "127.0.0.1"; echo "localhost"; echo "$FQDN"; } | sudo tee /etc/opendkim/TrustedHosts >/dev/null
for d in $DOMAINS; do
  sudo mkdir -p "/etc/opendkim/keys/$d"
  if [[ ! -f "/etc/opendkim/keys/$d/$SELECTOR.private" ]]; then
    sudo opendkim-genkey -b 2048 -s "$SELECTOR" -d "$d" -D "/etc/opendkim/keys/$d/"
  fi
  echo "${SELECTOR}._domainkey.${d} ${d}:${SELECTOR}:/etc/opendkim/keys/${d}/${SELECTOR}.private" \
    | sudo tee -a /etc/opendkim/KeyTable >/dev/null
  echo "*@${d} ${SELECTOR}._domainkey.${d}" | sudo tee -a /etc/opendkim/SigningTable >/dev/null
  echo "$d" | sudo tee -a /etc/opendkim/TrustedHosts >/dev/null
done
sudo tee /etc/opendkim.conf >/dev/null <<EOF
Syslog yes
UMask 007
Mode sv
Canonicalization relaxed/simple
Socket inet:8891@localhost
PidFile /run/opendkim/opendkim.pid
OversignHeaders From
ExternalIgnoreList refile:/etc/opendkim/TrustedHosts
InternalHosts refile:/etc/opendkim/TrustedHosts
KeyTable refile:/etc/opendkim/KeyTable
SigningTable refile:/etc/opendkim/SigningTable
UserID opendkim
EOF
echo 'SOCKET="inet:8891@localhost"' | sudo tee /etc/default/opendkim >/dev/null
sudo chown -R opendkim:opendkim /etc/opendkim
sudo find /etc/opendkim/keys -name '*.private' -exec sudo chmod 600 {} \;
sudo systemctl enable opendkim >/dev/null 2>&1
sudo systemctl restart opendkim || warn "opendkim failed to start"

# --- Postfix main.cf + submission (587) --------------------------------------
sudo postconf -e "myhostname=$FQDN"
sudo postconf -e "myorigin=$PRIMARY"
sudo postconf -e "smtpd_sasl_type=cyrus"
sudo postconf -e "smtpd_sasl_path=smtpd"
sudo postconf -e "smtpd_sasl_local_domain=$FQDN"
sudo postconf -e "smtpd_sasl_security_options=noanonymous"
sudo postconf -e "smtpd_tls_security_level=may"
sudo postconf -e "smtp_tls_security_level=may"
sudo postconf -e "smtpd_relay_restrictions=permit_mynetworks permit_sasl_authenticated reject_unauth_destination"
sudo postconf -e "milter_default_action=accept"
sudo postconf -e "milter_protocol=6"
sudo postconf -e "smtpd_milters=inet:localhost:8891"
sudo postconf -e "non_smtpd_milters=inet:localhost:8891"
sudo postconf -e "inet_interfaces=all"

sudo postconf -M "submission/inet=submission inet n - n - - smtpd"
sudo postconf -P "submission/inet/syslog_name=postfix/submission"
sudo postconf -P "submission/inet/smtpd_tls_security_level=encrypt"
sudo postconf -P "submission/inet/smtpd_sasl_auth_enable=yes"
sudo postconf -P "submission/inet/smtpd_sasl_security_options=noanonymous"
sudo postconf -P "submission/inet/smtpd_client_restrictions=permit_sasl_authenticated,reject"
sudo postconf -P "submission/inet/smtpd_relay_restrictions=permit_sasl_authenticated,reject"

sudo systemctl restart postfix || warn "postfix restart failed"

# --- write the DNS records the operator must publish (per domain) -------------
sudo mkdir -p /etc/aza
{
  echo "# Mail deliverability DNS — publish these in each domain's zone."
  echo "# (SPF references the VM host whose A record tracks the public IP.)"
  echo "PTR  reverse-DNS of the VM IP = ${FQDN}   (set on the Azure public IP)"
  for d in $DOMAINS; do
    echo "---- $d ----"
    if [[ -f "/etc/opendkim/keys/$d/$SELECTOR.txt" ]]; then
      v="$(sudo grep -o '"[^"]*"' "/etc/opendkim/keys/$d/$SELECTOR.txt" | tr -d '"\n' | tr -d '[:space:]')"
      echo "TXT  ${SELECTOR}._domainkey.${d}  =  ${v}"
    fi
    echo "TXT  ${d}  =  v=spf1 a:${CUSTOM_FQDN:-$FQDN} mx ~all"
    echo "TXT  _dmarc.${d}  =  v=DMARC1; p=none; rua=mailto:postmaster@${d}"
  done
} | sudo tee /etc/aza/mail-dns.txt >/dev/null

ok "Authenticated submission relay (587) + OpenDKIM ready for: $DOMAINS. Publish DNS from /etc/aza/mail-dns.txt + set reverse DNS (PTR)."
