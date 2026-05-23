#!/usr/bin/env bash
# Webmin admin UI on :10000 (HTTPS), reachable directly and proxied at /webmin/.
set -uo pipefail
source "$AZA_HOME/lib/remote.sh"

apt_install wget
log "Adding Webmin repository..."
curl -fsSL -o /tmp/webmin-setup-repo.sh https://raw.githubusercontent.com/webmin/webmin/master/webmin-setup-repo.sh
# -f forces; piping 'y' covers older script versions that prompt on stdin.
yes | sudo sh /tmp/webmin-setup-repo.sh -f
sudo -E apt-get update

log "Installing Webmin (with recommended deps)..."
# Webmin needs its recommended Perl modules, so do NOT use --no-install-recommends here.
sudo -E apt-get install -y webmin || die "Webmin package install failed."

# Make the /webmin/ reverse-proxy path work (Webmin needs to know its URL prefix).
if [[ -f /etc/webmin/miniserv.conf ]]; then
  log "Configuring Webmin for the /webmin/ reverse-proxy path..."
  sudo sed -i '/^webprefix=/d;/^webprefixnoredir=/d' /etc/webmin/miniserv.conf
  echo "webprefix=/webmin"     | sudo tee -a /etc/webmin/miniserv.conf >/dev/null
  echo "webprefixnoredir=1"    | sudo tee -a /etc/webmin/miniserv.conf >/dev/null
  sudo systemctl enable --now webmin
  sudo systemctl restart webmin
fi

# Set the Webmin 'root' login password to the vaulted value (azureuser is SSH-key-only).
WEBMIN_PW="$(kv_get webminPassword)"
if [[ -n "$WEBMIN_PW" ]]; then
  log "Setting Webmin root password from Key Vault..."
  sudo /usr/share/webmin/changepass.pl /etc/webmin root "$WEBMIN_PW" 2>/dev/null || warn "webmin changepass failed"
  sudo systemctl restart webmin 2>/dev/null || true
fi

sleep 3
if sudo ss -ltn | grep -q ':10000'; then
  ok "Webmin running on :10000 (https://$(vm_fqdn):10000/ and /webmin/). Login: root"
else
  die "Webmin installed but not listening on :10000."
fi
