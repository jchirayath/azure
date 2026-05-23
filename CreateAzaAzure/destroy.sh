#!/usr/bin/env bash
# =============================================================================
# destroy.sh — one-touch teardown of the entire resource group (VM + all deps).
#
#   ./destroy.sh          # prompts for confirmation
#   ./destroy.sh --yes    # no prompt (scripted)
#
# NOTE: this does NOT back up first. Run ./backup.sh beforehand to preserve
# home dirs / scripts (see README).
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
load_config
az_preflight

group_exists || { ok "Resource group $VM_RESOURCE_GROUP does not exist — nothing to do."; exit 0; }

if [[ "${1:-}" != "--yes" ]]; then
  warn "This deletes resource group '$VM_RESOURCE_GROUP' and EVERYTHING in it"
  warn "(VM, disk, Key Vault, identity, public IP, NSG)."
  warn "Run ./backup.sh first if you want to keep any data."
  read -r -p "Type the resource group name to confirm: " reply
  [[ "$reply" == "$VM_RESOURCE_GROUP" ]] || die "Confirmation did not match. Aborted."
fi

# Key Vaults are soft-deleted by default; purge so the name frees up immediately.
PURGE_KV="${PURGE_KV:-true}"

log "Deleting resource group $VM_RESOURCE_GROUP..."
az group delete --name "$VM_RESOURCE_GROUP" --yes

if [[ "$PURGE_KV" == "true" ]]; then
  if az keyvault list-deleted --query "[?name=='$KEY_VAULT_NAME']" -o tsv 2>/dev/null | grep -q .; then
    log "Purging soft-deleted Key Vault $KEY_VAULT_NAME..."
    az keyvault purge --name "$KEY_VAULT_NAME" 2>/dev/null || warn "KV purge failed (may need 'Key Vault Purge' permission)."
  fi
fi

ok "Teardown complete."
