#!/usr/bin/env bash
# =============================================================================
# 1-capture-image.sh — capture the running, fully-provisioned VM into an Azure
# Compute Gallery image that the portal deploys from on demand.
#
# Non-destructive: snapshots the OS disk (the live VM keeps running) and builds
# a SPECIALIZED image from the snapshot — so VMs created from it boot fully
# configured (services, certs, SSH key) with no cloud-init re-run.
#
#   ./1-capture-image.sh            # capture current state as IMAGE_VERSION
#   IMAGE_VERSION=1.0.1 ./1-capture-image.sh   # recapture / bump
# =============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

log() { printf '\033[0;34m==>\033[0m %s\n' "$*"; }
ok()  { printf '\033[0;32m  ✓\033[0m %s\n' "$*"; }
die() { printf '\033[0;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

command -v az >/dev/null || die "az CLI not found"
az account show >/dev/null 2>&1 || die "run: az login"
az account set --subscription "$AZURE_SUBSCRIPTION"

az vm show -g "$VM_RESOURCE_GROUP" -n "$VM_HOSTNAME" >/dev/null 2>&1 \
  || die "Source VM $VM_HOSTNAME not found in $VM_RESOURCE_GROUP. Build it first (CreateAzaAzure/deploy.sh)."

# 1. Persistent platform RG + gallery -----------------------------------------
az group show -n "$PLATFORM_RG" >/dev/null 2>&1 || {
  log "Creating persistent platform RG $PLATFORM_RG..."
  az group create -n "$PLATFORM_RG" -l "$VM_REGION" -o none
}
az sig show -g "$PLATFORM_RG" -r "$GALLERY_NAME" >/dev/null 2>&1 || {
  log "Creating Compute Gallery $GALLERY_NAME..."
  az sig create -g "$PLATFORM_RG" -r "$GALLERY_NAME" -o none
}

# 2. Image definition (specialized, Gen2, TrustedLaunch to match the VM) -------
az sig image-definition show -g "$PLATFORM_RG" -r "$GALLERY_NAME" -i "$IMAGE_DEF" >/dev/null 2>&1 || {
  log "Creating image definition $IMAGE_DEF (specialized, TrustedLaunch)..."
  az sig image-definition create \
    -g "$PLATFORM_RG" -r "$GALLERY_NAME" -i "$IMAGE_DEF" \
    --publisher "$IMAGE_PUBLISHER" --offer "$IMAGE_OFFER" --sku "$IMAGE_SKU" \
    --os-type Linux --os-state Specialized \
    --hyper-v-generation V2 --features SecurityType=TrustedLaunch -o none
}

# 3. Snapshot the live OS disk (non-destructive) ------------------------------
OS_DISK_ID="$(az vm show -g "$VM_RESOURCE_GROUP" -n "$VM_HOSTNAME" \
  --query storageProfile.osDisk.managedDisk.id -o tsv)"
SNAP_NAME="${VM_HOSTNAME}-snap-$(date +%Y%m%d-%H%M%S)"
log "Snapshotting OS disk -> $SNAP_NAME (VM keeps running)..."
az snapshot create -g "$PLATFORM_RG" -n "$SNAP_NAME" --source "$OS_DISK_ID" -o none
SNAP_ID="$(az snapshot show -g "$PLATFORM_RG" -n "$SNAP_NAME" --query id -o tsv)"
ok "Snapshot created."

# 4. Image version from the snapshot ------------------------------------------
log "Creating image version $IMAGE_VERSION from snapshot (this takes a few min)..."
az sig image-version create \
  -g "$PLATFORM_RG" -r "$GALLERY_NAME" -i "$IMAGE_DEF" -e "$IMAGE_VERSION" \
  --os-snapshot "$SNAP_ID" \
  --target-regions "$VM_REGION" -o none
ok "Image version $IMAGE_VERSION created."

IMG_ID="$(az sig image-version show -g "$PLATFORM_RG" -r "$GALLERY_NAME" -i "$IMAGE_DEF" -e "$IMAGE_VERSION" --query id -o tsv)"
echo
ok "Golden image ready:"
echo "    $IMG_ID"
echo "    The portal deploys VMs from this image. Recapture with a bumped IMAGE_VERSION"
echo "    after changing the box. Old snapshots can be deleted from $PLATFORM_RG to save cost."
