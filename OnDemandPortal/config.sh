# =============================================================================
# OnDemandPortal — shared configuration (non-secret, committed).
# Sourced by the local foundation scripts (1-capture-image.sh, etc.).
# The Function App reads the same values from its App Settings (set by
# 3-provision-portal.sh), so there is ONE source of truth.
# =============================================================================

# ---- Subscription / target VM (must match CreateAzaAzure) -------------------
AZURE_SUBSCRIPTION="${AZURE_SUBSCRIPTION:-JacobAzure}"
VM_REGION="${VM_REGION:-westus3}"

# The ephemeral VM the portal builds/destroys on demand.
VM_RESOURCE_GROUP="${VM_RESOURCE_GROUP:-rg-axa}"   # kept; emptied when "down"
VM_HOSTNAME="${VM_HOSTNAME:-axa}"
VM_SIZE="${VM_SIZE:-Standard_D4s_v3}"
VM_ADMIN_USER="${VM_ADMIN_USER:-azureuser}"

# ---- Custom DNS (managed by CreateAzaAzure; portal just updates the A record) -
DNS_ZONE="${DNS_ZONE:-az.aspl.net}"
DNS_RECORD="${DNS_RECORD:-axa}"
DNS_ZONE_RG="${DNS_ZONE_RG:-rg-dns}"

# ---- Persistent platform (created once, never torn down) --------------------
PLATFORM_RG="${PLATFORM_RG:-rg-platform}"
GALLERY_NAME="${GALLERY_NAME:-galAxa}"               # Azure Compute Gallery (alphanumeric only)
IMAGE_DEF="${IMAGE_DEF:-axa-img}"                    # image definition name
IMAGE_VERSION="${IMAGE_VERSION:-1.0.8}"              # latest golden image; bump when you recapture
IMAGE_PUBLISHER="${IMAGE_PUBLISHER:-aspl}"
IMAGE_OFFER="${IMAGE_OFFER:-axa}"
IMAGE_SKU="${IMAGE_SKU:-ubuntu2204}"

# Managed identity the Function API runs as (Contributor on rg-axa + DNS on rg-dns).
PORTAL_IDENTITY="${PORTAL_IDENTITY:-axa-portal-identity}"
# User-assigned identity attached to each VM so it can deallocate itself when idle.
VM_IDENTITY="${VM_IDENTITY:-axa-vm-identity}"

# ---- Portal hosting ---------------------------------------------------------
STATIC_WEBAPP="${STATIC_WEBAPP:-axa-portal-swa}"      # (unused — superseded by the Function App)
FUNCTION_APP="${FUNCTION_APP:-aspl}"                  # Function App serving the portal UI + API (aspl.azurewebsites.net)
# Storage account for Functions — global-unique, 3-24 lowercase alnum. Derived
# deterministically from the subscription in 3-provision-portal.sh (stable across runs).
FUNCTION_STORAGE="${FUNCTION_STORAGE:-}"
PORTAL_REGION="${PORTAL_REGION:-westus2}"             # SWA free tier regions are limited

# ---- Cost dashboard ---------------------------------------------------------
# Display-only monthly spend target shown on the Operations page (no Azure budget
# / alerts are created — just MTD vs this number + remaining headroom).
MONTHLY_BUDGET_USD="${MONTHLY_BUDGET_USD:-150}"

# ---- Azure Virtual Desktop (on-demand stack — see ../CreateAvdAzure) ----------
# Portal MI gets Virtual Machine Contributor + Desktop Virtualization Reader on AVD_RG
# (granted in provision). The session host is discovered by AVD_VM_PREFIX (unique name
# per deploy), so there is no fixed AVD_VM.
AVD_RG="${AVD_RG:-rg-avd}"
AVD_HOSTPOOL="${AVD_HOSTPOOL:-hp-avd}"
AVD_WORKSPACE="${AVD_WORKSPACE:-ws-avd}"
AVD_VM_PREFIX="${AVD_VM_PREFIX:-avdh}"
AVD_VM_SIZE="${AVD_VM_SIZE:-Standard_D4ds_v4}"
AVD_ADMIN_USER="${AVD_ADMIN_USER:-avdadmin}"
AVD_ADMIN_SECRET="${AVD_ADMIN_SECRET:-avdAdminPassword}"
AVD_IDLE_MINUTES="${AVD_IDLE_MINUTES:-30}"   # auto-deallocate host after N min with no Active sessions
