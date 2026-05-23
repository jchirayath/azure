# =============================================================================
# CreateAzaAzure — shared helpers for the LOCAL scripts (deploy/destroy/backup).
# Sourced, not executed. Expects SCRIPT_DIR to be set by the caller.
# =============================================================================

# ---- logging ----------------------------------------------------------------
_c_blue='\033[0;34m'; _c_yellow='\033[0;33m'; _c_red='\033[0;31m'; _c_green='\033[0;32m'; _c_off='\033[0m'
log()  { printf "${_c_blue}==>${_c_off} %s\n" "$*"; }
ok()   { printf "${_c_green}  ✓${_c_off} %s\n" "$*"; }
warn() { printf "${_c_yellow}  ! %s${_c_off}\n" "$*" >&2; }
die()  { printf "${_c_red}✗ %s${_c_off}\n" "$*" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found in PATH."; }

# ---- config loading ---------------------------------------------------------
# Loads .env (secrets) then config.sh (non-secret). .env first so config.sh can
# reference secret-derived values if ever needed; both honour pre-set env vars.
load_config() {
  if [[ -f "$SCRIPT_DIR/.env" ]]; then
    set -a; # shellcheck disable=SC1091
    source "$SCRIPT_DIR/.env"; set +a
  else
    warn ".env not found — copy .env.example to .env and fill it in."
  fi
  # shellcheck disable=SC1091
  source "$SCRIPT_DIR/config.sh"
}

# ---- azure preflight --------------------------------------------------------
az_preflight() {
  require_cmd az
  az account show >/dev/null 2>&1 || die "Not logged in to Azure. Run: az login"
  log "Setting subscription: $AZURE_SUBSCRIPTION"
  az account set --subscription "$AZURE_SUBSCRIPTION" || die "Could not set subscription '$AZURE_SUBSCRIPTION'."
  SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
}

# ---- small azure helpers ----------------------------------------------------
group_exists()    { az group show --name "$VM_RESOURCE_GROUP" >/dev/null 2>&1; }
vm_exists()       { az vm show -g "$VM_RESOURCE_GROUP" -n "$VM_HOSTNAME" >/dev/null 2>&1; }

vm_public_ip() {
  az vm show -g "$VM_RESOURCE_GROUP" -n "$VM_HOSTNAME" --show-details --query publicIps -o tsv 2>/dev/null
}
vm_fqdn() {
  az network public-ip show -g "$VM_RESOURCE_GROUP" -n "${VM_HOSTNAME}-ip" \
    --query dnsSettings.fqdn -o tsv 2>/dev/null
}
