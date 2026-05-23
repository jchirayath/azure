#!/usr/bin/env bash
# =============================================================================
# restore.sh — push a previously-captured local backup back onto the VM
# (typically after a fresh deploy). Restores home dirs + scripts; not logs.
#
#   ./restore.sh                       # restores the newest backup
#   ./restore.sh backups/aza-20260522-101500   # restore a specific snapshot
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
load_config
require_cmd rsync
az_preflight

RESTORE_DIR="${1:-$BACKUP_DIR/${VM_HOSTNAME}-latest}"
[[ -d "$RESTORE_DIR" ]] || die "Backup directory not found: $RESTORE_DIR"
RESTORE_DIR="$(cd "$RESTORE_DIR" && pwd)"

vm_exists || die "VM $VM_HOSTNAME not found in $VM_RESOURCE_GROUP."
HOST="$(vm_fqdn)"; [[ -z "$HOST" ]] && HOST="$(vm_public_ip)"
[[ -z "$HOST" ]] && die "Could not determine VM address."

warn "About to push $RESTORE_DIR onto $HOST (overwrites matching files)."
read -r -p "Continue? (y/N) " reply
[[ "$reply" =~ ^[Yy]$ ]] || die "Aborted."

SSH_OPTS="-o StrictHostKeyChecking=no -i $VM_SSH_KEY"
for src in "${BACKUP_SOURCES[@]}"; do
  local_path="$RESTORE_DIR$src"      # e.g. <dir>/home  (matches /home on the VM)
  [[ -d "$local_path" ]] || { warn "  no captured data for $src; skipping"; continue; }
  log "  restoring $src"
  rsync -az -e "ssh $SSH_OPTS" --rsync-path="sudo rsync" \
    "$local_path/" "${VM_ADMIN_USER}@${HOST}:${src}/" \
    || warn "restore of $src reported errors."
done

ok "Restore complete. You may need to restart affected services."
