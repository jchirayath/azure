#!/usr/bin/env bash
# =============================================================================
# Helpers available to every module while provisioning runs ON THE VM.
# Sourced by each module via:  source "$AZA_HOME/lib/remote.sh"
# Runtime config (KV_NAME, CERTBOT_EMAIL, ...) is exported by orchestrate.sh.
# =============================================================================

log()  { printf '==> %s\n' "$*"; }
ok()   { printf '  [ok] %s\n' "$*"; }
warn() { printf '  [!!] %s\n' "$*" >&2; }
die()  { printf '  [XX] %s\n' "$*" >&2; exit 1; }

# Non-interactive apt every time.
export DEBIAN_FRONTEND=noninteractive
apt_install() { sudo -E apt-get install -y --no-install-recommends "$@"; }

# Fetch a secret from the VM's Key Vault (managed identity already logged in).
# Usage: pw="$(kv_get mysqlRootPassword)"
kv_get() {
  az keyvault secret show --vault-name "$KV_NAME" --name "$1" --query value -o tsv 2>/dev/null
}

# The VM's public FQDN, e.g. aza.westus3.cloudapp.azure.com
vm_fqdn() { hostname -f; }
