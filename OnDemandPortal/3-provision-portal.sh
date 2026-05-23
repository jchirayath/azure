#!/usr/bin/env bash
# =============================================================================
# 3-provision-portal.sh — stand up the public portal as a SINGLE Function App
# (Python) that serves the web UI + API, gated by App Service Easy Auth (AAD).
# The Function App's system managed identity does the Azure work — no secrets.
#
# Run AFTER 1-capture-image.sh. Idempotent. Needs: az (no npm/SWA CLI).
#
#   ./3-provision-portal.sh
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
SUB_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"

IMAGE_ID="$(az sig image-version show -g "$PLATFORM_RG" -r "$GALLERY_NAME" -i "$IMAGE_DEF" -e "$IMAGE_VERSION" --query id -o tsv 2>/dev/null)" \
  || die "Golden image not found — run ./1-capture-image.sh first."

az group show -n "$PLATFORM_RG" >/dev/null 2>&1 || az group create -n "$PLATFORM_RG" -l "$VM_REGION" -o none
az group show -n "$VM_RESOURCE_GROUP" >/dev/null 2>&1 || az group create -n "$VM_RESOURCE_GROUP" -l "$VM_REGION" -o none

log "Compiling VM template + bundling web UI into the function..."
az bicep build --file infra/vm-from-image.bicep --outfile api/vm-from-image.json
mkdir -p api/www && cp web/index.html web/vm.html web/credentials.html web/ops.html web/app.js api/www/

# ---- 1. Storage account (required by Functions) -----------------------------
SA="${FUNCTION_STORAGE:-axaportal$(echo "$SUB_ID" | tr -d '-' | cut -c1-12)}"
az storage account show -g "$PLATFORM_RG" -n "$SA" >/dev/null 2>&1 || {
  log "Creating storage account $SA..."
  az storage account create -g "$PLATFORM_RG" -n "$SA" -l "$PORTAL_REGION" --sku Standard_LRS -o none
}

# ---- 2. Function App (Linux, Python, system identity) -----------------------
az functionapp show -g "$PLATFORM_RG" -n "$FUNCTION_APP" >/dev/null 2>&1 || {
  log "Creating Function App $FUNCTION_APP..."
  az functionapp create -g "$PLATFORM_RG" -n "$FUNCTION_APP" \
    --storage-account "$SA" --consumption-plan-location "$PORTAL_REGION" \
    --runtime python --runtime-version 3.11 --functions-version 4 \
    --os-type Linux --assign-identity '[system]' -o none
}
FUNC_MI="$(az functionapp identity show -g "$PLATFORM_RG" -n "$FUNCTION_APP" --query principalId -o tsv)"

# ---- 3. Role assignments for the Function identity --------------------------
log "Granting Function identity Contributor on $VM_RESOURCE_GROUP + DNS rights on $DNS_ZONE_RG..."
az role assignment create --assignee-object-id "$FUNC_MI" --assignee-principal-type ServicePrincipal \
  --role "Contributor" --scope "/subscriptions/$SUB_ID/resourceGroups/$VM_RESOURCE_GROUP" -o none 2>/dev/null || true
az role assignment create --assignee-object-id "$FUNC_MI" --assignee-principal-type ServicePrincipal \
  --role "DNS Zone Contributor" --scope "/subscriptions/$SUB_ID/resourceGroups/$DNS_ZONE_RG" -o none 2>/dev/null || true
# Credentials page reads service passwords from the VM's Key Vault.
KV_NAME="${KEY_VAULT_NAME:-kv-${VM_HOSTNAME}-${VM_REGION}}"
az role assignment create --assignee-object-id "$FUNC_MI" --assignee-principal-type ServicePrincipal \
  --role "Key Vault Secrets User" \
  --scope "/subscriptions/$SUB_ID/resourceGroups/$VM_RESOURCE_GROUP/providers/Microsoft.KeyVault/vaults/$KV_NAME" \
  -o none 2>/dev/null || true

# Operations features (cost dashboard, activity log, image manager, self-repoint):
log "Granting Function identity Cost/Monitoring read + gallery write + self-config..."
# Cost dashboard (Cost Management query) — subscription scope.
az role assignment create --assignee-object-id "$FUNC_MI" --assignee-principal-type ServicePrincipal \
  --role "Cost Management Reader" --scope "/subscriptions/$SUB_ID" -o none 2>/dev/null || true
# Activity log read — subscription scope.
az role assignment create --assignee-object-id "$FUNC_MI" --assignee-principal-type ServicePrincipal \
  --role "Monitoring Reader" --scope "/subscriptions/$SUB_ID" -o none 2>/dev/null || true
# Recapture / list image versions — write on the Compute Gallery.
az role assignment create --assignee-object-id "$FUNC_MI" --assignee-principal-type ServicePrincipal \
  --role "Contributor" \
  --scope "/subscriptions/$SUB_ID/resourceGroups/$PLATFORM_RG/providers/Microsoft.Compute/galleries/$GALLERY_NAME" \
  -o none 2>/dev/null || true
# "Set current image" rewrites this Function App's own IMAGE_ID app setting.
az role assignment create --assignee-object-id "$FUNC_MI" --assignee-principal-type ServicePrincipal \
  --role "Website Contributor" \
  --scope "/subscriptions/$SUB_ID/resourceGroups/$PLATFORM_RG/providers/Microsoft.Web/sites/$FUNCTION_APP" \
  -o none 2>/dev/null || true

# ---- 3b. VM self-deallocate identity (for idle auto-stop) -------------------
# A user-assigned identity attached to each deployed VM, allowed to deallocate
# itself when the in-VM idle agent fires.
az identity show -g "$PLATFORM_RG" -n "$VM_IDENTITY" >/dev/null 2>&1 || {
  log "Creating VM identity $VM_IDENTITY..."
  az identity create -g "$PLATFORM_RG" -n "$VM_IDENTITY" -o none
}
VM_IDENTITY_RID="$(az identity show -g "$PLATFORM_RG" -n "$VM_IDENTITY" --query id -o tsv)"
VM_IDENTITY_PRINCIPAL="$(az identity show -g "$PLATFORM_RG" -n "$VM_IDENTITY" --query principalId -o tsv)"
log "Granting VM identity 'Virtual Machine Contributor' on $VM_RESOURCE_GROUP..."
az role assignment create --assignee-object-id "$VM_IDENTITY_PRINCIPAL" --assignee-principal-type ServicePrincipal \
  --role "Virtual Machine Contributor" --scope "/subscriptions/$SUB_ID/resourceGroups/$VM_RESOURCE_GROUP" -o none 2>/dev/null || true

# ---- 4. App settings --------------------------------------------------------
log "Setting Function App settings..."
az functionapp config appsettings set -g "$PLATFORM_RG" -n "$FUNCTION_APP" --settings \
  SUBSCRIPTION_ID="$SUB_ID" VM_RESOURCE_GROUP="$VM_RESOURCE_GROUP" VM_HOSTNAME="$VM_HOSTNAME" \
  VM_SIZE="$VM_SIZE" VM_REGION="$VM_REGION" IMAGE_ID="$IMAGE_ID" VM_IDENTITY_ID="$VM_IDENTITY_RID" \
  DNS_ZONE="$DNS_ZONE" DNS_RECORD="$DNS_RECORD" DNS_ZONE_RG="$DNS_ZONE_RG" \
  GALLERY_RG="$PLATFORM_RG" GALLERY_NAME="$GALLERY_NAME" IMAGE_DEF="$IMAGE_DEF" \
  FUNCTION_APP="$FUNCTION_APP" KV_NAME="$KV_NAME" \
  MONTHLY_BUDGET_USD="${MONTHLY_BUDGET_USD:-150}" \
  AVD_RG="${AVD_RG:-}" AVD_HOSTPOOL="${AVD_HOSTPOOL:-}" AVD_WORKSPACE="${AVD_WORKSPACE:-}" \
  AVD_VM_PREFIX="${AVD_VM_PREFIX:-avdh}" AVD_VM_SIZE="${AVD_VM_SIZE:-Standard_D4ds_v4}" \
  AVD_ADMIN_USER="${AVD_ADMIN_USER:-avdadmin}" AVD_ADMIN_SECRET="${AVD_ADMIN_SECRET:-avdAdminPassword}" \
  AVD_IDLE_MINUTES="${AVD_IDLE_MINUTES:-30}" -o none

# Let the portal start/stop the AVD session host + read sessions for idle auto-stop.
if [[ -n "${AVD_RG:-}" ]]; then
  az role assignment create --assignee-object-id "$FUNC_MI" --assignee-principal-type ServicePrincipal \
    --role "Virtual Machine Contributor" --scope "/subscriptions/$SUB_ID/resourceGroups/$AVD_RG" \
    -o none 2>/dev/null || true
  az role assignment create --assignee-object-id "$FUNC_MI" --assignee-principal-type ServicePrincipal \
    --role "Desktop Virtualization Reader" --scope "/subscriptions/$SUB_ID/resourceGroups/$AVD_RG" \
    -o none 2>/dev/null || true
fi

# ---- 5. Deploy the code (zip deploy; remote build installs requirements) -----
log "Packaging and deploying function code..."
rm -f /tmp/aza-api.zip
( cd api && zip -qr /tmp/aza-api.zip . -x '*.pyc' '__pycache__/*' )
az functionapp deployment source config-zip -g "$PLATFORM_RG" -n "$FUNCTION_APP" \
  --src /tmp/aza-api.zip --build-remote true -o none
ok "Function deployed."

# ---- 6. Easy Auth (AAD), single-tenant -> locks sign-in to your org ----------
FQDN="${FUNCTION_APP}.azurewebsites.net"
log "Registering AAD app for sign-in..."
APP_ID="$(az ad app list --display-name "$FUNCTION_APP" --query '[0].appId' -o tsv 2>/dev/null)"
if [[ -z "$APP_ID" ]]; then
  APP_ID="$(az ad app create --display-name "$FUNCTION_APP" \
    --web-redirect-uris "https://${FQDN}/.auth/login/aad/callback" \
    --enable-id-token-issuance true --sign-in-audience AzureADMyOrg --query appId -o tsv)"
else
  az ad app update --id "$APP_ID" --web-redirect-uris "https://${FQDN}/.auth/login/aad/callback" \
    --enable-id-token-issuance true -o none
fi
SECRET="$(az ad app credential reset --id "$APP_ID" --display-name easyauth --query password -o tsv)"
# Microsoft Graph User.Read (delegated) — user-consentable, avoids AADSTS650056.
az ad app permission add --id "$APP_ID" \
  --api 00000003-0000-0000-c000-000000000000 \
  --api-permissions e1fe6dd8-ba31-4d61-89e7-88639da4683d=Scope -o none 2>/dev/null || true

log "Configuring Easy Auth (redirect unauthenticated users to AAD login)..."
az extension add --name authV2 --only-show-errors -y >/dev/null 2>&1 || true
# Store the provider secret as an app setting referenced by the auth config.
az functionapp config appsettings set -g "$PLATFORM_RG" -n "$FUNCTION_APP" \
  --settings MICROSOFT_PROVIDER_AUTHENTICATION_SECRET="$SECRET" -o none
# Apply authsettingsV2 via the management REST API (bypasses the CLI's v1/v2 guard).
SITE="/subscriptions/${SUB_ID}/resourceGroups/${PLATFORM_RG}/providers/Microsoft.Web/sites/${FUNCTION_APP}"
cat > /tmp/authv2.json <<JSON
{
  "properties": {
    "platform": { "enabled": true },
    "globalValidation": {
      "requireAuthentication": true,
      "unauthenticatedClientAction": "RedirectToLoginPage",
      "redirectToProvider": "azureactivedirectory"
    },
    "identityProviders": {
      "azureActiveDirectory": {
        "enabled": true,
        "registration": {
          "openIdIssuer": "https://login.microsoftonline.com/${TENANT_ID}/v2.0",
          "clientId": "${APP_ID}",
          "clientSecretSettingName": "MICROSOFT_PROVIDER_AUTHENTICATION_SECRET"
        },
        "login": { "loginParameters": ["scope=openid profile email"] },
        "validation": { "allowedAudiences": ["api://${APP_ID}"] }
      }
    },
    "login": { "tokenStore": { "enabled": true } }
  }
}
JSON
az rest --method put \
  --url "https://management.azure.com${SITE}/config/authsettingsV2?api-version=2022-03-01" \
  --body @/tmp/authv2.json -o none

echo
ok "Portal is live (sign-in restricted to tenant $TENANT_ID):"
echo "    https://${FQDN}"
echo "    Open it, sign in with your Azure AD account, and use Deploy / Destroy."
