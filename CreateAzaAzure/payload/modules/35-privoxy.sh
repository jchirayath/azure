#!/usr/bin/env bash
# Privoxy filtering proxy, listening on :8118.
set -uo pipefail
source "$AZA_HOME/lib/remote.sh"

apt_install privoxy

log "Configuring Privoxy to listen on all interfaces..."
sudo cp -n /etc/privoxy/config /etc/privoxy/config.backup || true
sudo sed -i 's/^listen-address.*127.0.0.1:8118/listen-address  0.0.0.0:8118/' /etc/privoxy/config

# Restrict who may use the proxy. Edit this list to suit your network.
# NOTE: a bare "0.0.0.0" matches only that literal address; use CIDR to allow a range.
sudo sed -i '/^#* *permit-access /d' /etc/privoxy/config
ALLOWED=( "0.0.0.0/0" )   # allow all (UFW/NSG still gate it). Tighten to your CIDR as needed.
for cidr in "${ALLOWED[@]}"; do
  echo "permit-access $cidr" | sudo tee -a /etc/privoxy/config >/dev/null
done

sudo systemctl restart privoxy
sleep 2
curl -s -x http://localhost:8118 http://example.com >/dev/null && ok "Privoxy proxying OK." || warn "Privoxy test failed."
