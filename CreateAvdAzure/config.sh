# =============================================================================
# CreateAvdAzure — non-secret configuration (safe to commit)
# On-demand Azure Virtual Desktop: its own RG + scripts, deploy/start/stop/destroy
# like the AXA VM. Pooled multi-session, Azure AD-joined session host(s).
# =============================================================================
AZURE_SUBSCRIPTION="${AZURE_SUBSCRIPTION:-JacobAzure}"

# Resource group (kept; the session host VM is the deploy/destroy target).
AVD_RG="${AVD_RG:-rg-avd}"
AVD_REGION="${AVD_REGION:-westus3}"          # session-host VM region
# AVD control-plane (host pool / app group / workspace) metadata region. Must be an
# AVD-supported metadata region; westus3 is supported.
AVD_METADATA_REGION="${AVD_METADATA_REGION:-westus3}"

# ---- AVD control plane (persistent) -----------------------------------------
HOSTPOOL="${HOSTPOOL:-hp-avd}"
APPGROUP="${APPGROUP:-ag-avd-desktop}"
WORKSPACE="${WORKSPACE:-ws-avd}"
POOL_TYPE="${POOL_TYPE:-Pooled}"
LOAD_BALANCER="${LOAD_BALANCER:-BreadthFirst}"
MAX_SESSIONS="${MAX_SESSIONS:-4}"
# Custom RDP properties — enablerdsaadauth=1 lets AAD-joined hosts accept AAD auth.
RDP_PROPERTIES="${RDP_PROPERTIES:-enablerdsaadauth:i:1;audiocapturemode:i:1;audiomode:i:0;redirectclipboard:i:1;drivestoredirect:s:*;}"

# ---- Session host VM --------------------------------------------------------
# Session host VM name — UNIQUE per deploy so a redeploy never collides with the
# leftover Azure AD device object of a destroyed same-named host (error 0x801c0083,
# "hostnames already exists"). Deleting AAD device objects needs a directory role the
# automation doesn't have, so we sidestep it with a fresh name each time. deploy.sh
# (and the portal) discover the current host by SH_PREFIX.
SH_PREFIX="${SH_PREFIX:-avdh}"
SH_NAME="${SH_NAME:-${SH_PREFIX}$(openssl rand -hex 3)}"
VM_SIZE="${VM_SIZE:-Standard_D4ds_v4}"
# Win11 multi-session, AVD-optimized (gallery image URN).
VM_IMAGE="${VM_IMAGE:-microsoftwindowsdesktop:windows-11:win11-23h2-avd:latest}"
VM_ADMIN_USER="${VM_ADMIN_USER:-avdadmin}"   # local admin (required even for AAD-join); password vaulted
VM_DISK_SIZE="${VM_DISK_SIZE:-128}"

# ---- Access -----------------------------------------------------------------
# User (or AAD group) that gets Desktop Virtualization User on the app group and
# Virtual Machine User Login on the session host (so AAD sign-in works).
ASSIGN_PRINCIPAL="${ASSIGN_PRINCIPAL:-jacobc@aspl.net}"
ASSIGN_PRINCIPAL_TYPE="${ASSIGN_PRINCIPAL_TYPE:-User}"   # User or Group

# ---- Key Vault (reuse the AXA vault for the local-admin password) -----------
KEY_VAULT_NAME="${KEY_VAULT_NAME:-kv-axa-westus3}"
ADMIN_SECRET_NAME="${ADMIN_SECRET_NAME:-avdAdminPassword}"

# ---- AVD agent (stable "latest" download links used for registration) -------
AVD_AGENT_URL="${AVD_AGENT_URL:-https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrmXv}"
AVD_BOOTLOADER_URL="${AVD_BOOTLOADER_URL:-https://query.prod.cms.rt.microsoft.com/cms/api/am/binary/RWrxrH}"
