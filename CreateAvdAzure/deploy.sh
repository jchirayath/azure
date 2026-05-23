#!/usr/bin/env bash
# =============================================================================
# CreateAvdAzure/deploy.sh — stand up the on-demand AVD stack in its own RG.
# Foundation (host pool / app group / workspace / network / roles) is idempotent;
# the session host VM is the deploy/destroy target. AAD-joined, reverse-connect
# (no inbound ports). Run start/stop/destroy from the portal afterwards.
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

log() { printf '\033[0;34m==>\033[0m %s\n' "$*"; }
ok()  { printf '\033[0;32m  \xe2\x9c\x93\033[0m %s\n' "$*"; }
warn(){ printf '\033[0;33m  ! %s\033[0m\n' "$*"; }
die() { printf '\033[0;31m\xe2\x9c\x97 %s\033[0m\n' "$*" >&2; exit 1; }

command -v az >/dev/null || die "az CLI not found"
az account show >/dev/null 2>&1 || die "run: az login"
az account set --subscription "$AZURE_SUBSCRIPTION"
SUB="$(az account show --query id -o tsv)"
az extension show -n desktopvirtualization >/dev/null 2>&1 || az extension add -n desktopvirtualization --only-show-errors -y

# ---- 1. Resource group ------------------------------------------------------
az group show -n "$AVD_RG" >/dev/null 2>&1 || { log "Creating $AVD_RG..."; az group create -n "$AVD_RG" -l "$AVD_REGION" -o none; }

# ---- 2. Network (no public IP / no inbound — AVD uses reverse connect) -------
if ! az network vnet show -g "$AVD_RG" -n avd-vnet >/dev/null 2>&1; then
  log "Creating vnet/subnet + NSG (deny inbound from internet)..."
  az network nsg create -g "$AVD_RG" -n avd-nsg -l "$AVD_REGION" -o none
  az network vnet create -g "$AVD_RG" -n avd-vnet -l "$AVD_REGION" \
    --address-prefixes 10.42.0.0/16 --subnet-name hosts --subnet-prefixes 10.42.1.0/24 \
    --network-security-group avd-nsg -o none
fi
SUBNET_ID="$(az network vnet subnet show -g "$AVD_RG" --vnet-name avd-vnet -n hosts --query id -o tsv)"

# ---- 3. Host pool (Pooled) --------------------------------------------------
if ! az desktopvirtualization hostpool show -g "$AVD_RG" -n "$HOSTPOOL" >/dev/null 2>&1; then
  log "Creating host pool $HOSTPOOL ($POOL_TYPE/$LOAD_BALANCER)..."
  az desktopvirtualization hostpool create -g "$AVD_RG" -n "$HOSTPOOL" --location "$AVD_METADATA_REGION" \
    --host-pool-type "$POOL_TYPE" --load-balancer-type "$LOAD_BALANCER" --max-session-limit "$MAX_SESSIONS" \
    --preferred-app-group-type Desktop --custom-rdp-property "$RDP_PROPERTIES" -o none \
    || die "host pool create failed (is $AVD_METADATA_REGION an AVD metadata region?)"
else
  az desktopvirtualization hostpool update -g "$AVD_RG" -n "$HOSTPOOL" --custom-rdp-property "$RDP_PROPERTIES" -o none 2>/dev/null || true
fi
HP_ID="$(az desktopvirtualization hostpool show -g "$AVD_RG" -n "$HOSTPOOL" --query id -o tsv)"

# ---- 4. App group (Desktop) + workspace -------------------------------------
if ! az desktopvirtualization applicationgroup show -g "$AVD_RG" -n "$APPGROUP" >/dev/null 2>&1; then
  log "Creating application group $APPGROUP..."
  az desktopvirtualization applicationgroup create -g "$AVD_RG" -n "$APPGROUP" --location "$AVD_METADATA_REGION" \
    --host-pool-arm-path "$HP_ID" --application-group-type Desktop -o none
fi
AG_ID="$(az desktopvirtualization applicationgroup show -g "$AVD_RG" -n "$APPGROUP" --query id -o tsv)"
if ! az desktopvirtualization workspace show -g "$AVD_RG" -n "$WORKSPACE" >/dev/null 2>&1; then
  log "Creating workspace $WORKSPACE..."
  az desktopvirtualization workspace create -g "$AVD_RG" -n "$WORKSPACE" --location "$AVD_METADATA_REGION" \
    --application-group-references "$AG_ID" -o none
else
  az desktopvirtualization workspace update -g "$AVD_RG" -n "$WORKSPACE" --application-group-references "$AG_ID" -o none 2>/dev/null || true
fi

# ---- 5. Access role on the app group ----------------------------------------
log "Granting '$ASSIGN_PRINCIPAL' Desktop Virtualization User on the app group..."
az role assignment create --assignee "$ASSIGN_PRINCIPAL" --role "Desktop Virtualization User" --scope "$AG_ID" -o none 2>/dev/null || true

# ---- 6. Local-admin password (vaulted) --------------------------------------
ADMIN_PW="$(az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name "$ADMIN_SECRET_NAME" --query value -o tsv 2>/dev/null)"
if [[ -z "$ADMIN_PW" ]]; then
  ADMIN_PW="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-20)Aa1!"
  az keyvault secret set --vault-name "$KEY_VAULT_NAME" --name "$ADMIN_SECRET_NAME" --value "$ADMIN_PW" -o none || die "could not vault admin password"
fi

# ---- 7. Registration token --------------------------------------------------
EXPIRY="$(date -u -v+23H +%Y-%m-%dT%H:%M:%S.0000000Z 2>/dev/null || date -u -d '+23 hours' +%Y-%m-%dT%H:%M:%S.0000000Z)"
az desktopvirtualization hostpool update -g "$AVD_RG" -n "$HOSTPOOL" \
  --registration-info expiration-time="$EXPIRY" registration-token-operation="Update" -o none
TOKEN="$(az desktopvirtualization hostpool retrieve-registration-token -g "$AVD_RG" -n "$HOSTPOOL" --query token -o tsv 2>/dev/null)"
[[ -z "$TOKEN" ]] && die "could not get registration token"

# ---- 8. Deploy the session host VM ------------------------------------------
log "Compiling bicep + deploying session host $SH_NAME ($VM_SIZE)..."
az bicep build --file infra/sessionhost.bicep --outfile infra/sessionhost.json >/dev/null 2>&1 || true
IMG_PUB="${VM_IMAGE%%:*}"; rest="${VM_IMAGE#*:}"; IMG_OFFER="${rest%%:*}"; rest="${rest#*:}"; IMG_SKU="${rest%%:*}"
az deployment group create -g "$AVD_RG" -n "avd-host-$SH_NAME" --template-file infra/sessionhost.bicep \
  --parameters location="$AVD_REGION" shName="$SH_NAME" vmSize="$VM_SIZE" adminUser="$VM_ADMIN_USER" \
    adminPassword="$ADMIN_PW" subnetId="$SUBNET_ID" imagePublisher="$IMG_PUB" imageOffer="$IMG_OFFER" imageSku="$IMG_SKU" \
  -o none || die "session host deployment failed"

# ---- 9. VM sign-in role (AAD-joined needs Virtual Machine User Login) --------
# Granted at the RG scope so it covers every (uniquely-named) session host that gets
# redeployed here — the portal can't assign roles, so this is the durable grant.
log "Granting '$ASSIGN_PRINCIPAL' Virtual Machine User Login on $AVD_RG..."
az role assignment create --assignee "$ASSIGN_PRINCIPAL" --role "Virtual Machine User Login" \
  --scope "/subscriptions/$SUB/resourceGroups/$AVD_RG" -o none 2>/dev/null || true

# ---- 10. Install + register the AVD agent (run-command, fresh token) ---------
log "Installing + registering the AVD agent on $SH_NAME (this takes a few min)..."
PS="\$ErrorActionPreference='Stop'; \$d=\"\$env:TEMP\\avd\"; New-Item -ItemType Directory -Force -Path \$d | Out-Null;
Invoke-WebRequest -Uri '$AVD_AGENT_URL' -OutFile \"\$d\\agent.msi\" -UseBasicParsing;
Invoke-WebRequest -Uri '$AVD_BOOTLOADER_URL' -OutFile \"\$d\\boot.msi\" -UseBasicParsing;
Start-Process msiexec.exe -Wait -ArgumentList \"/i \`\"\$d\\agent.msi\`\" /quiet /norestart REGISTRATIONTOKEN=$TOKEN\";
Start-Process msiexec.exe -Wait -ArgumentList \"/i \`\"\$d\\boot.msi\`\" /quiet /norestart\";
Start-Sleep 8; Restart-Service RDAgentBootLoader -ErrorAction SilentlyContinue;
(Get-Service RDAgentBootLoader,RdAgent | Select-Object Name,Status | Format-Table -Auto | Out-String)"
az vm run-command invoke -g "$AVD_RG" -n "$SH_NAME" --command-id RunPowerShellScript \
  --scripts "$PS" --query "value[0].message" -o tsv 2>/dev/null | head -8

# ---- 11. Wait for the session host to report Available -----------------------
log "Waiting for the session host to register (Available)..."
for i in $(seq 1 20); do
  ST="$(az rest --method get --url "https://management.azure.com$HP_ID/sessionHosts/${SH_NAME}?api-version=2022-09-09" --query 'properties.status' -o tsv 2>/dev/null)"
  echo "    [$i] status=$ST"
  [[ "$ST" == "Available" ]] && break
  sleep 15
done

echo
ok "AVD on-demand stack deployed."
echo "    RG          : $AVD_RG   Host pool: $HOSTPOOL ($POOL_TYPE)"
echo "    Session host: $SH_NAME  ($VM_SIZE, Win11 multi-session, AAD-joined)"
echo "    Connect     : https://client.wvd.microsoft.com/arm/webclient/index.html  (sign in as $ASSIGN_PRINCIPAL)"
echo "    Admin pw    : Key Vault $KEY_VAULT_NAME / $ADMIN_SECRET_NAME"
