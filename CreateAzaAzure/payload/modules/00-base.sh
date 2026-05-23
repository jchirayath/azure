#!/usr/bin/env bash
# Base host setup: update packages, install core tooling, set FQDN/timezone/locale.
set -uo pipefail
source "$AZA_HOME/lib/remote.sh"

log "Updating package lists and upgrading installed packages..."
sudo -E apt-get update
sudo -E apt-get upgrade -y

log "Installing core tooling..."
apt_install \
  git curl wget unzip expect rsync screen diffutils lsof tcpdump telnet \
  netcat-openbsd traceroute perl python3 python3-pip net-tools jq ca-certificates \
  software-properties-common apt-transport-https gnupg docker.io php php-mysql mysql-client nmap

log "Enabling Docker..."
sudo systemctl enable --now docker || warn "docker enable failed"

# --- FQDN / hostname (matches Azure cloudapp DNS) ----------------------------
FQDN="$(hostname -f 2>/dev/null || true)"
VM_HOST="$(hostname -s)"
# Region from instance metadata so the box is self-describing.
VM_REGION="$(curl -s -H Metadata:true 'http://169.254.169.254/metadata/instance/compute/location?api-version=2021-02-01&format=text' | tr '[:upper:]' '[:lower:]' || true)"

if [[ -n "$VM_HOST" && -n "$VM_REGION" ]]; then
  FQDN="${VM_HOST}.${VM_REGION}.cloudapp.azure.com"
  log "Setting FQDN to $FQDN"
  echo "$FQDN" | sudo tee /etc/hostname >/dev/null
  sudo sed -i "s/^127\.0\.1\.1.*/127.0.1.1 $FQDN $VM_HOST/" /etc/hosts
  grep -q "127.0.1.1" /etc/hosts || echo "127.0.1.1 $FQDN $VM_HOST" | sudo tee -a /etc/hosts >/dev/null
  sudo hostnamectl set-hostname "$FQDN" 2>/dev/null || true
fi

# --- timezone by region ------------------------------------------------------
case "$VM_REGION" in
  eastus|eastus2)   TZ="America/New_York" ;;
  centralus)        TZ="America/Chicago" ;;
  westus|westus2|westus3) TZ="America/Los_Angeles" ;;
  *)                TZ="UTC" ;;
esac
log "Setting timezone to $TZ"
sudo timedatectl set-timezone "$TZ" || warn "timezone set failed"

# --- locale ------------------------------------------------------------------
log "Setting locale to en_US.UTF-8"
sudo locale-gen en_US.UTF-8 && sudo update-locale LANG=en_US.UTF-8 || warn "locale set failed"

# --- record host facts for humans / backups ----------------------------------
sudo mkdir -p /etc/aza
# Bake the configuration reference onto the box (shipped in the payload).
if [[ -f "$AZA_HOME/files/CONFIGURATION.md" ]]; then
  sudo cp "$AZA_HOME/files/CONFIGURATION.md" /etc/aza/CONFIGURATION.md
  log "Configuration reference baked to /etc/aza/CONFIGURATION.md"
fi
{
  echo "FQDN=$FQDN"
  echo "VM_HOST=$VM_HOST"
  echo "VM_REGION=$VM_REGION"
  echo "TIMEZONE=$TZ"
  echo "PROVISIONED=$(date -u +%FT%TZ)"
} | sudo tee /etc/aza/hostinfo >/dev/null

ok "Base host setup complete."
