#!/usr/bin/env bash
# =============================================================================
# Runs on the VM at first boot (invoked by cloud-init). Logs in to Azure with
# the VM's managed identity, then executes every enabled module in order.
# All output is captured to /var/log/aza-provision.log by cloud-init.
# =============================================================================
set -uo pipefail

export AZA_HOME="/opt/aza"
export DEBIAN_FRONTEND=noninteractive

# runtime.env (non-secret config) is written into the bundle by deploy.sh.
# shellcheck disable=SC1091
source "$AZA_HOME/runtime.env"
# shellcheck disable=SC1091
source "$AZA_HOME/lib/remote.sh"

log "=== aza provisioning started $(date -u +%FT%TZ) ==="

# --- ensure Azure CLI is present, then log in with the managed identity ------
if ! command -v az >/dev/null 2>&1; then
  log "Installing Azure CLI (needed for Key Vault access)..."
  curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
fi

log "Logging in to Azure with the VM managed identity..."
for i in 1 2 3 4 5; do
  if az login --identity >/dev/null 2>&1; then ok "az login --identity succeeded"; break; fi
  warn "az login attempt $i failed; retrying in 10s (identity/role propagation)..."
  sleep 10
  [[ $i -eq 5 ]] && warn "Could not log in with managed identity; KV-dependent modules may fail."
done

# --- run modules listed in the manifest, in order ----------------------------
failed=()
while IFS= read -r module; do
  [[ -z "$module" || "$module" == \#* ]] && continue
  path="$AZA_HOME/modules/$module"
  [[ -f "$path" ]] || { warn "module $module not found in bundle; skipping"; continue; }
  log "----- running $module -----"
  if bash "$path"; then
    ok "$module completed"
  else
    warn "$module FAILED (continuing with remaining modules)"
    failed+=("$module")
  fi
done < "$AZA_HOME/manifest.txt"

echo
log "=== aza provisioning finished $(date -u +%FT%TZ) ==="
if (( ${#failed[@]} )); then
  warn "Modules with errors: ${failed[*]}"
  exit 1
fi
ok "All enabled modules completed successfully."
