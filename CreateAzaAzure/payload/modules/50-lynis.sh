#!/usr/bin/env bash
# Lynis security audit; report saved to /etc/aza for review / backup.
set -uo pipefail
source "$AZA_HOME/lib/remote.sh"

apt_install lynis
log "Running Lynis audit (this takes a minute)..."
sudo mkdir -p /etc/aza
sudo lynis audit system -Q --no-colors | sudo tee /etc/aza/lynis_report.txt >/dev/null
ok "Lynis audit saved to /etc/aza/lynis_report.txt"
