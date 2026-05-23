#!/usr/bin/env bash
# UFW firewall. SSH is allowed FIRST so enabling the firewall never locks us out.
set -uo pipefail
source "$AZA_HOME/lib/remote.sh"

apt_install ufw

log "Allowing SSH before enabling UFW..."
sudo ufw allow OpenSSH

# The NSG (Azure network firewall) is the authoritative public boundary AND the
# on-demand gate: by default it exposes only 22/80/443/8118 (see NSG_RULES in
# config.sh), and the portal opens/closes the other service ports on demand.
# UFW therefore ALLOWS the full service-port set so it never blocks an on-demand
# NSG open; the NSG default-deny is what keeps these closed until requested.
# (Truly-internal backends — MySQL, Elasticsearch, oauth2-proxy, ttyd, Adminer,
# node_exporter — bind to localhost regardless and are never exposed.)
PORTS=(80 443 8118 8080 10000 3000 8000 5601 9090 25 587 465 143 993)
for p in "${PORTS[@]}"; do
  sudo ufw allow "${p}/tcp" || warn "ufw allow ${p}/tcp failed"
done

log "Enabling UFW..."
sudo ufw --force enable
sudo ufw status verbose
ok "Firewall configured."
