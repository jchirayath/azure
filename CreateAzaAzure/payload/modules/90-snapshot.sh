#!/usr/bin/env bash
# Timeshift snapshot of the freshly provisioned system (a local restore point).
set -uo pipefail
source "$AZA_HOME/lib/remote.sh"

apt_install timeshift
log "Creating initial Timeshift snapshot..."
sudo timeshift --create --comments "aza initial provisioning" --tags D \
  && ok "Snapshot created." \
  || warn "Snapshot failed (timeshift needs a supported filesystem layout)."
