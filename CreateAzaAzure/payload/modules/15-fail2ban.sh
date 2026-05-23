#!/usr/bin/env bash
# fail2ban — brute-force protection across ALL exposed services:
#   - sshd            : SSH (key-only, but still jail probes)
#   - aza-weblogin    : failed POST logins to the password apps proxied by nginx
#                       (Guacamole, Grafana, Webmin, Splunk) — covers them via the
#                       shared nginx access log without false-banning the AAD/oauth2
#                       redirect flow (which uses GETs, not these POST endpoints).
#   - nginx-botsearch : vulnerability scanners probing bad URLs.
#   - postfix/dovecot : mail brute-force (only matters if mail ports are opened).
#   - recidive        : repeat offenders (banned across jails) get a long ban.
# The AAD-gated tools (/shell,/db,/kibana,/prometheus) are protected by Azure AD
# itself, so brute force there is handled by Microsoft, not the VM.
set -uo pipefail
source "$AZA_HOME/lib/remote.sh"

apt_install fail2ban

# --- custom filter: failed web-app logins seen in the nginx access log --------
log "Installing aza-weblogin fail2ban filter..."
sudo tee /etc/fail2ban/filter.d/aza-weblogin.conf >/dev/null <<'EOF'
# Match brute-force POSTs to the password-protected apps that return 401/403.
# These are real login endpoints (not the oauth2-proxy GET redirect flow).
[Definition]
failregex = ^<HOST> -.*"POST (/guacamole/api/tokens|/grafana/login|/grafana/api/login|[^"]*/session_login\.cgi|/splunk/[^"]*account/login[^"]*)[^"]*" (401|403)\b
ignoreregex =
EOF

log "Configuring fail2ban jails..."
sudo tee /etc/fail2ban/jail.d/aza.local >/dev/null <<'EOF'
[DEFAULT]
backend  = auto
bantime  = 3600
findtime = 600
maxretry = 3
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled  = true
backend  = systemd
port     = ssh
filter   = sshd

[aza-weblogin]
enabled  = true
port     = http,https
filter   = aza-weblogin
logpath  = /var/log/nginx/access.log
maxretry = 5
findtime = 600
bantime  = 3600

[nginx-botsearch]
enabled  = true
port     = http,https
filter   = nginx-botsearch
logpath  = /var/log/nginx/access.log
maxretry = 6
bantime  = 3600

# Mail brute-force on the submission relay (587) and inbound SMTP.
[postfix-sasl]
enabled  = true
backend  = systemd
filter   = postfix[mode=auth]
maxretry = 4

[dovecot]
enabled  = true
backend  = systemd
filter   = dovecot
maxretry = 5

# Repeat offenders (re-banned across any jail) get a week-long all-ports ban.
[recidive]
enabled   = true
logpath   = /var/log/fail2ban.log
banaction = %(banaction_allports)s
bantime   = 604800
findtime  = 86400
maxretry  = 5
EOF

# Remove the old single-jail file from earlier builds so settings don't conflict.
sudo rm -f /etc/fail2ban/jail.d/sshd.local 2>/dev/null || true

# Validate the custom filter compiles before (re)starting, so a bad regex can't
# wedge the whole service.
if ! sudo fail2ban-regex /dev/null /etc/fail2ban/filter.d/aza-weblogin.conf >/dev/null 2>&1; then
  warn "aza-weblogin filter failed to compile — disabling that jail."
  sudo sed -i 's/^enabled  = true  *# aza-weblogin//' /etc/fail2ban/jail.d/aza.local 2>/dev/null || true
fi

sudo systemctl enable fail2ban
sudo systemctl restart fail2ban
sleep 3
log "fail2ban jails:"
sudo fail2ban-client status 2>/dev/null || warn "fail2ban not reporting yet"
ok "fail2ban configured (ssh + web logins + scanners + mail + recidive)."
