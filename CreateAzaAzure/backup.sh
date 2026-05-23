#!/usr/bin/env bash
# =============================================================================
# backup.sh — pull user data (home dirs + scripts) off the VM into a local,
# timestamped, gitignored folder. Logs are excluded. Run manually before
# destroy.sh, or any time you want a snapshot.
#
#   ./backup.sh
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
load_config
require_cmd rsync
az_preflight

vm_exists || die "VM $VM_HOSTNAME not found in $VM_RESOURCE_GROUP."
HOST="$(vm_fqdn)"; [[ -z "$HOST" ]] && HOST="$(vm_public_ip)"
[[ -z "$HOST" ]] && die "Could not determine VM address."

STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="$BACKUP_DIR/${VM_HOSTNAME}-${STAMP}"
mkdir -p "$DEST"
log "Backing up $HOST -> $DEST"

# Build rsync excludes from config.
EXCLUDES=()
for e in "${BACKUP_EXCLUDES[@]}"; do EXCLUDES+=( --exclude="$e" ); done

SSH_OPTS="-o StrictHostKeyChecking=no -i $VM_SSH_KEY"
# --rsync-path=sudo lets us read /root and other users' homes.
for src in "${BACKUP_SOURCES[@]}"; do
  log "  pulling $src"
  rsync -az --delete --relative "${EXCLUDES[@]}" \
    -e "ssh $SSH_OPTS" \
    --rsync-path="sudo rsync" \
    "${VM_ADMIN_USER}@${HOST}:${src}/" "$DEST/" \
    || warn "rsync of $src reported errors (path may not exist)."
done

# Record what was captured.
{
  echo "host=$HOST"
  echo "vm=$VM_HOSTNAME"
  echo "timestamp=$STAMP"
  echo "sources=${BACKUP_SOURCES[*]}"
} > "$DEST/BACKUP_MANIFEST.txt"

ln -sfn "$DEST" "$BACKUP_DIR/${VM_HOSTNAME}-latest"
ok "Backup complete: $DEST"
ok "Latest symlink: $BACKUP_DIR/${VM_HOSTNAME}-latest"
