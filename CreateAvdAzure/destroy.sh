#!/usr/bin/env bash
# Remove the AVD session host VM (+ NIC + OS disk) and unregister it from the pool.
# Keeps the control plane (host pool / app group / workspace / network / roles) so a
# redeploy is fast. Pass --all to delete the entire AVD resource group.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh
log() { printf '\033[0;34m==>\033[0m %s\n' "$*"; }
ok()  { printf '\033[0;32m  \xe2\x9c\x93\033[0m %s\n' "$*"; }
az account set --subscription "$AZURE_SUBSCRIPTION"
SUB="$(az account show --query id -o tsv)"

if [[ "${1:-}" == "--all" ]]; then
  log "Deleting the entire AVD resource group $AVD_RG..."
  az group delete -n "$AVD_RG" --yes --no-wait && ok "RG deletion started."
  exit 0
fi

HP_ID="/subscriptions/$SUB/resourceGroups/$AVD_RG/providers/Microsoft.DesktopVirtualization/hostPools/$HOSTPOOL"
# Discover the actual session host (names are unique per deploy — don't trust config's random SH_NAME).
HOST="$(az vm list -g "$AVD_RG" --query "[?starts_with(name,'${SH_PREFIX}')].name | [0]" -o tsv 2>/dev/null)"
[[ -z "$HOST" ]] && { ok "No session host found in $AVD_RG (nothing to remove)."; exit 0; }

log "Unregistering session host $HOST from the pool..."
az rest --method delete --url "https://management.azure.com${HP_ID}/sessionHosts/${HOST}?api-version=2022-09-09&force=true" -o none 2>/dev/null || true

log "Deleting session host VM + NIC + OS disk ($HOST)..."
az vm delete -g "$AVD_RG" -n "$HOST" --yes -o none 2>/dev/null || true
az network nic delete -g "$AVD_RG" -n "${HOST}-nic" -o none 2>/dev/null || true
az disk delete -g "$AVD_RG" -n "${HOST}-osdisk" --yes -o none 2>/dev/null || true
ok "Session host $HOST removed (control plane kept). Redeploy with ./deploy.sh."
