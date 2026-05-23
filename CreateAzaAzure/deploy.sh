#!/usr/bin/env bash
# =============================================================================
# deploy.sh — one-touch build of the resource group + VM, fully provisioned.
#
#   ./deploy.sh
#
# Idempotent: every resource is created only if missing, so re-running is safe.
# Secrets are generated locally, stored ONLY in Key Vault, and pulled by the VM
# at boot via its managed identity — nothing secret is written to disk or git.
# =============================================================================
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
load_config

require_cmd ssh-keygen
require_cmd tar
az_preflight

# Map module toggles -> ordered manifest. Add new services here + in config.sh.
MODULE_MAP=(
  "ENABLE_BASE:00-base.sh"
  "ENABLE_FIREWALL:10-firewall.sh"
  "ENABLE_FAIL2BAN:15-fail2ban.sh"
  "ENABLE_MYSQL:20-mysql.sh"
  "ENABLE_GUACAMOLE:25-guacamole.sh"
  "ENABLE_DBEDITOR:27-dbeditor.sh"
  "ENABLE_VMTOOLS_AUTH:28-vmtools-auth.sh"
  "ENABLE_NGINX:30-nginx.sh"
  "ENABLE_PRIVOXY:35-privoxy.sh"
  "ENABLE_MAIL:40-mail.sh"
  "ENABLE_LYNIS:50-lynis.sh"
  "ENABLE_WEBMIN:55-webmin.sh"
  "ENABLE_ELK:60-elk.sh"
  "ENABLE_MONITORING:62-monitoring.sh"
  "ENABLE_SPLUNK:65-splunk.sh"
  "ENABLE_PENTEST:70-pentest.sh"
  "ENABLE_NETTOOLS:72-nettools.sh"
  "ENABLE_WEBSSH:75-webssh.sh"
  "ENABLE_IDLE_STOP:80-idle-shutdown.sh"
  "ENABLE_HEALTH:85-health.sh"
  "ENABLE_SNAPSHOT:90-snapshot.sh"
)

# ---- 0. SSH key -------------------------------------------------------------
if [[ ! -f "${VM_SSH_KEY}.pub" ]]; then
  log "Generating passwordless SSH keypair at $VM_SSH_KEY"
  mkdir -p "$(dirname "$VM_SSH_KEY")"
  ssh-keygen -t ed25519 -f "$VM_SSH_KEY" -N "" -C "aza-$VM_HOSTNAME"
elif [[ -f "$VM_SSH_KEY" ]] && ! ssh-keygen -y -P "" -f "$VM_SSH_KEY" >/dev/null 2>&1; then
  # Key exists but is passphrase-protected -> automation (SSH wait/backup) would hang.
  die "SSH key $VM_SSH_KEY is passphrase-protected. Set VM_SSH_KEY to a passwordless key, or:
       ssh-keygen -t ed25519 -f ~/.ssh/aza_ed25519 -N ''  and set VM_SSH_KEY accordingly."
fi

# ---- 1. Resource group ------------------------------------------------------
if group_exists; then ok "Resource group $VM_RESOURCE_GROUP exists."; else
  log "Creating resource group $VM_RESOURCE_GROUP ($VM_REGION)..."
  az group create --name "$VM_RESOURCE_GROUP" --location "$VM_REGION" -o none
fi
RG_SCOPE="/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$VM_RESOURCE_GROUP"

# ---- 2. User-assigned managed identity --------------------------------------
IDENTITY_NAME="${VM_HOSTNAME}-identity"
if ! az identity show -g "$VM_RESOURCE_GROUP" -n "$IDENTITY_NAME" >/dev/null 2>&1; then
  log "Creating managed identity $IDENTITY_NAME..."
  az identity create -g "$VM_RESOURCE_GROUP" -n "$IDENTITY_NAME" -o none
fi
IDENTITY_ID="$(az identity show -g "$VM_RESOURCE_GROUP" -n "$IDENTITY_NAME" --query id -o tsv)"
IDENTITY_PRINCIPAL="$(az identity show -g "$VM_RESOURCE_GROUP" -n "$IDENTITY_NAME" --query principalId -o tsv)"

# ---- 3. Key Vault (RBAC) ----------------------------------------------------
KV_SCOPE="$RG_SCOPE/providers/Microsoft.KeyVault/vaults/$KEY_VAULT_NAME"
if ! az keyvault show -n "$KEY_VAULT_NAME" >/dev/null 2>&1; then
  # A same-named vault may linger in soft-deleted state (90-day retention) from a
  # prior teardown — purge it first, otherwise create fails with ConflictError.
  if az keyvault list-deleted --query "[?name=='$KEY_VAULT_NAME']" -o tsv 2>/dev/null | grep -q .; then
    log "Purging soft-deleted Key Vault $KEY_VAULT_NAME before recreating..."
    az keyvault purge --name "$KEY_VAULT_NAME" 2>/dev/null || warn "KV purge failed (need 'Key Vault Purge' rights?)."
  fi
  log "Creating Key Vault $KEY_VAULT_NAME (RBAC)..."
  az keyvault create -n "$KEY_VAULT_NAME" -g "$VM_RESOURCE_GROUP" -l "$VM_REGION" \
    --enable-rbac-authorization true -o none
fi

assign_role() {  # role, assignee-objectId
  az role assignment create --role "$1" --assignee-object-id "$2" \
    --assignee-principal-type "$3" --scope "$KV_SCOPE" -o none 2>/dev/null || true
}

# Let the person running deploy write secrets, and the optional admin group manage.
ME_OBJECT_ID="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
if [[ -n "$ME_OBJECT_ID" ]]; then
  log "Granting yourself Key Vault Administrator (to seed secrets)..."
  assign_role "Key Vault Administrator" "$ME_OBJECT_ID" "User"
fi
ADMIN_GROUP_ID="$(az ad group show --group "$KEY_VAULT_ADMINS" --query id -o tsv 2>/dev/null || true)"
[[ -n "$ADMIN_GROUP_ID" ]] && assign_role "Key Vault Administrator" "$ADMIN_GROUP_ID" "Group"

# The VM identity reads secrets...
log "Granting VM identity 'Key Vault Secrets User'..."
assign_role "Key Vault Secrets User" "$IDENTITY_PRINCIPAL" "ServicePrincipal"
# ...and must be able to deallocate itself for the idle auto-stop agent (module 80).
log "Granting VM identity 'Virtual Machine Contributor' on $VM_RESOURCE_GROUP (idle self-stop)..."
az role assignment create --role "Virtual Machine Contributor" \
  --assignee-object-id "$IDENTITY_PRINCIPAL" --assignee-principal-type ServicePrincipal \
  --scope "$RG_SCOPE" -o none 2>/dev/null || true

log "Waiting 30s for role assignments to propagate..."
sleep 30

# ---- 4. Seed secrets (only if absent) ---------------------------------------
seed_secret() {  # name, value-from-env-or-empty
  local name="$1" val="$2"
  if az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name "$name" >/dev/null 2>&1; then
    ok "secret $name already set"; return
  fi
  [[ -z "$val" ]] && val="$(openssl rand -base64 "$PASSWORD_LENGTH" | tr -d '/+=' | cut -c1-"$PASSWORD_LENGTH")"
  # RBAC data-plane access can take a few minutes to propagate; retry.
  local attempt
  for attempt in $(seq 1 12); do
    if az keyvault secret set --vault-name "$KEY_VAULT_NAME" --name "$name" --value "$val" -o none 2>/dev/null; then
      ok "secret $name created"; return
    fi
    [[ $attempt -eq 1 ]] && log "  waiting for Key Vault RBAC to propagate (retrying secret $name)..."
    sleep 15
  done
  die "Could not set secret $name after retries (Key Vault RBAC may not have propagated)."
}
log "Seeding Key Vault secrets..."
seed_secret mysqlRootPassword    "${MYSQL_ROOT_PASSWORD:-}"
seed_secret guacDbPassword       "${GUAC_DB_PASSWORD:-}"
seed_secret guacAdminPassword    "${GUAC_ADMIN_PASSWORD:-}"   # guacadmin web login (reset off default)
seed_secret grafanaAdminPassword "${GRAFANA_ADMIN_PASSWORD:-}" # grafana admin (off admin/admin)
seed_secret webminPassword       "${WEBMIN_PASSWORD:-}"        # webmin root login
seed_secret splunkAdminPassword  "${SPLUNK_ADMIN_PASSWORD:-}"
seed_secret mailRelayPassword    "${MAIL_RELAY_PASSWORD:-}"    # SASL user for the submission relay (587)
# External Guacamole DB (only used when GUAC_USE_LOCAL_MYSQL=false).
[[ -n "${GUAC_SQL_HOST:-}" ]] && seed_secret guacamoleHost     "$GUAC_SQL_HOST"
[[ -n "${GUAC_SQL_USER:-}" ]] && seed_secret guacamoleUser     "$GUAC_SQL_USER"
[[ -n "${GUAC_SQL_PASS:-}" ]] && seed_secret guacamolePassword "$GUAC_SQL_PASS"

# ---- 4b. AAD app for the VM tools sign-on (oauth2-proxy gates /shell/ + /db/) ----
if [[ "${ENABLE_VMTOOLS_AUTH:-true}" == "true" ]]; then
  TOOLS_FQDN="${VM_HOSTNAME}.${VM_REGION}.cloudapp.azure.com"
  log "Ensuring AAD app 'axa-vm-tools' for the shell/db sign-on..."
  TOOLS_APP_ID="$(az ad app list --display-name axa-vm-tools --query '[0].appId' -o tsv 2>/dev/null)"
  if [[ -z "$TOOLS_APP_ID" ]]; then
    TOOLS_APP_ID="$(az ad app create --display-name axa-vm-tools \
      --web-redirect-uris "https://${TOOLS_FQDN}/oauth2/callback" \
      --enable-id-token-issuance true --sign-in-audience AzureADMyOrg --query appId -o tsv)"
  fi
  az ad app permission add --id "$TOOLS_APP_ID" --api 00000003-0000-0000-c000-000000000000 \
    --api-permissions e1fe6dd8-ba31-4d61-89e7-88639da4683d=Scope -o none 2>/dev/null || true
  az keyvault secret set --vault-name "$KEY_VAULT_NAME" --name vmToolsClientId --value "$TOOLS_APP_ID" -o none
  # Set the client secret + cookie secret only once (don't rotate on every deploy).
  if ! az keyvault secret show --vault-name "$KEY_VAULT_NAME" --name vmToolsClientSecret >/dev/null 2>&1; then
    TOOLS_SEC="$(az ad app credential reset --id "$TOOLS_APP_ID" --display-name oauth2proxy --query password -o tsv)"
    az keyvault secret set --vault-name "$KEY_VAULT_NAME" --name vmToolsClientSecret --value "$TOOLS_SEC" -o none
  fi
  seed_secret vmToolsCookieSecret "$(python3 -c 'import os,base64;print(base64.urlsafe_b64encode(os.urandom(32)).decode())' 2>/dev/null || openssl rand -base64 32)"
  ok "AAD app for VM tools ready (consent on first sign-in)."
fi

# ---- 5. Public IP + DNS -----------------------------------------------------
if ! az network public-ip show -g "$VM_RESOURCE_GROUP" -n "${VM_HOSTNAME}-ip" >/dev/null 2>&1; then
  log "Creating public IP with DNS label $VM_HOSTNAME..."
  az network public-ip create -g "$VM_RESOURCE_GROUP" -n "${VM_HOSTNAME}-ip" \
    --dns-name "$VM_HOSTNAME" --sku Standard -o none
fi
# Reverse DNS (PTR) for mail: PTR -> cloudapp FQDN (forward A already resolves to
# the IP => valid FCrDNS, required so receivers don't reject/spam-folder our mail).
CLOUDAPP_FQDN="${VM_HOSTNAME}.${VM_REGION}.cloudapp.azure.com"
az network public-ip update -g "$VM_RESOURCE_GROUP" -n "${VM_HOSTNAME}-ip" \
  --reverse-fqdn "$CLOUDAPP_FQDN" -o none 2>/dev/null || warn "could not set reverse DNS (PTR)"
STATIC_IP="$(az network public-ip show -g "$VM_RESOURCE_GROUP" -n "${VM_HOSTNAME}-ip" --query ipAddress -o tsv)"

# ---- 5b. Custom domain via Azure DNS ----------------------------------------
# Creates/maintains the delegated zone and an A record for this VM. The zone's
# NS records must be delegated ONCE at the parent registrar (printed below).
DELEGATION_HINT=""
if [[ -n "${DNS_ZONE:-}" ]]; then
  # The DNS zone lives in its own persistent RG so teardown never removes it.
  if ! az group show --name "$DNS_ZONE_RG" >/dev/null 2>&1; then
    log "Creating persistent DNS resource group $DNS_ZONE_RG..."
    az group create --name "$DNS_ZONE_RG" --location "$VM_REGION" -o none
  fi
  if ! az network dns zone show -g "$DNS_ZONE_RG" -n "$DNS_ZONE" >/dev/null 2>&1; then
    log "Creating Azure DNS zone $DNS_ZONE..."
    az network dns zone create -g "$DNS_ZONE_RG" -n "$DNS_ZONE" -o none
  fi
  log "Setting A record ${DNS_RECORD}.${DNS_ZONE} -> $STATIC_IP"
  # Idempotent: clear any existing A records, recreate the set with TTL, add the IP.
  # (TTL belongs to the record-set, not to `add-record`.)
  az network dns record-set a delete -g "$DNS_ZONE_RG" -z "$DNS_ZONE" -n "$DNS_RECORD" --yes -o none 2>/dev/null || true
  az network dns record-set a create -g "$DNS_ZONE_RG" -z "$DNS_ZONE" -n "$DNS_RECORD" --ttl 300 -o none
  az network dns record-set a add-record -g "$DNS_ZONE_RG" -z "$DNS_ZONE" \
    --record-set-name "$DNS_RECORD" --ipv4-address "$STATIC_IP" -o none
  # CNAME for the Uptime Kuma vhost (module 72) -> follows the VM's A record.
  az network dns record-set cname set-record -g "$DNS_ZONE_RG" -z "$DNS_ZONE" \
    -n uptime --cname "$CUSTOM_FQDN" --ttl 300 -o none 2>/dev/null || true
  NS_RECORDS="$(az network dns zone show -g "$DNS_ZONE_RG" -n "$DNS_ZONE" --query nameServers -o tsv)"
  DELEGATION_HINT="$NS_RECORDS"
fi

# ---- 6. NSG + rules ---------------------------------------------------------
if ! az network nsg show -g "$VM_RESOURCE_GROUP" -n "${VM_HOSTNAME}-nsg" >/dev/null 2>&1; then
  log "Creating NSG ${VM_HOSTNAME}-nsg..."
  az network nsg create -g "$VM_RESOURCE_GROUP" -n "${VM_HOSTNAME}-nsg" -o none
fi
for rule in "${NSG_RULES[@]}"; do
  IFS=':' read -r rname rproto rprio rports <<< "$rule"
  if ! az network nsg rule show -g "$VM_RESOURCE_GROUP" --nsg-name "${VM_HOSTNAME}-nsg" -n "$rname" >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    az network nsg rule create -g "$VM_RESOURCE_GROUP" --nsg-name "${VM_HOSTNAME}-nsg" \
      -n "$rname" --protocol "$rproto" --priority "$rprio" --access Allow --direction Inbound \
      --destination-port-ranges $rports -o none
    ok "NSG rule $rname ($rports)"
  fi
done

# ---- 7. Build the cloud-init payload ----------------------------------------
log "Building cloud-init payload..."
BUILD="$SCRIPT_DIR/build"; PAYLOAD="$BUILD/payload"
rm -rf "$BUILD"; mkdir -p "$PAYLOAD"
cp -R "$SCRIPT_DIR/payload/." "$PAYLOAD/"
# Ship the configuration reference onto the VM (baked to /etc/aza by 00-base).
cp "$SCRIPT_DIR/CONFIGURATION.md" "$PAYLOAD/files/CONFIGURATION.md" 2>/dev/null || true

# manifest of enabled modules, in order
: > "$PAYLOAD/manifest.txt"
for entry in "${MODULE_MAP[@]}"; do
  flag="${entry%%:*}"; file="${entry##*:}"
  [[ "${!flag:-false}" == "true" ]] && echo "$file" >> "$PAYLOAD/manifest.txt"
done

# non-secret runtime config for the VM
cat > "$PAYLOAD/runtime.env" <<EOF
export KV_NAME="$KEY_VAULT_NAME"
export CUSTOM_FQDN="${CUSTOM_FQDN:-}"
export CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"
export MAIL_USER="${MAIL_USER:-}"
export MAIL_DOMAINS="${MAIL_DOMAINS:-${DNS_ZONE:-}}"
export GUAC_USE_LOCAL_MYSQL="${GUAC_USE_LOCAL_MYSQL:-true}"
export SPLUNK_DEB_URL="${SPLUNK_DEB_URL:-}"
export SPLUNK_WEB_PORT="${SPLUNK_WEB_PORT:-8000}"
EOF

CLOUD_INIT="$BUILD/cloud-init.yaml"
{
  echo "#cloud-config"
  echo "write_files:"
  echo "  - path: /opt/aza/bundle.tar"
  echo "    encoding: gz+b64"
  echo "    permissions: '0600'"
  echo "    content: |"
  tar -C "$PAYLOAD" -cf - . | gzip -9 | base64 | sed 's/^/      /'
  cat <<'EOF'
runcmd:
  - mkdir -p /opt/aza
  - tar -xf /opt/aza/bundle.tar -C /opt/aza
  - chmod +x /opt/aza/orchestrate.sh /opt/aza/modules/*.sh
  - [ bash, -lc, "/opt/aza/orchestrate.sh >> /var/log/aza-provision.log 2>&1" ]
EOF
} > "$CLOUD_INIT"
CI_SIZE=$(wc -c < "$CLOUD_INIT")
ok "cloud-init rendered ($CI_SIZE bytes; Azure limit ~64KB)."
(( CI_SIZE > 64000 )) && warn "Payload near/over the custom-data limit — disable some modules or use a storage-blob bootstrap."

# ---- 8. Create the VM -------------------------------------------------------
if vm_exists; then
  warn "VM $VM_HOSTNAME already exists — skipping create. (custom-data only applies at creation;"
  warn "to re-provision: destroy and redeploy, or run /opt/aza/orchestrate.sh on the VM.)"
else
  log "Creating VM $VM_HOSTNAME ($VM_SIZE, $VM_OS)... this is the slow step."
  az vm create \
    --resource-group "$VM_RESOURCE_GROUP" \
    --name "$VM_HOSTNAME" \
    --image "$VM_OS" \
    --size "$VM_SIZE" \
    --admin-username "$VM_ADMIN_USER" \
    --assign-identity "$IDENTITY_ID" \
    --public-ip-address "${VM_HOSTNAME}-ip" \
    --nsg "${VM_HOSTNAME}-nsg" \
    --os-disk-name "${VM_HOSTNAME}-osdisk" \
    --os-disk-size-gb "$VM_DISK_SIZE" \
    --os-disk-delete-option Delete \
    --security-type TrustedLaunch --enable-secure-boot true --enable-vtpm true \
    --ssh-key-values "${VM_SSH_KEY}.pub" \
    --custom-data "$CLOUD_INIT" \
    -o none
  ok "VM created."
fi

# ---- 9. Optional AAD SSH login ----------------------------------------------
if [[ "${ENABLE_AAD_SSH_LOGIN}" == "true" ]]; then
  log "Installing AAD SSH login extension..."
  az vm extension set -g "$VM_RESOURCE_GROUP" --vm-name "$VM_HOSTNAME" \
    --name AADSSHLoginForLinux --publisher Microsoft.Azure.ActiveDirectory --settings '{}' -o none || warn "AAD SSH ext failed"
fi

VM_IP="$(vm_public_ip)"; VM_DNS="$(vm_fqdn)"

# ---- 10. Wait for cloud-init (one-touch) ------------------------------------
if [[ "${WAIT_FOR_CLOUD_INIT}" == "true" && -n "$VM_IP" ]]; then
  log "Waiting for SSH on $VM_IP..."
  for i in $(seq 1 30); do
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "$VM_SSH_KEY" \
      "${VM_ADMIN_USER}@${VM_IP}" true 2>/dev/null && break
    sleep 10
  done
  log "Waiting for cloud-init to finish provisioning (tail: ssh in and 'tail -f /var/log/aza-provision.log')..."
  ssh -o StrictHostKeyChecking=no -i "$VM_SSH_KEY" "${VM_ADMIN_USER}@${VM_IP}" \
    "sudo cloud-init status --wait" || warn "cloud-init reported an issue; check /var/log/aza-provision.log"
fi

# ---- Summary ----------------------------------------------------------------
echo
log "==================== DEPLOYMENT SUMMARY ===================="
echo "  Resource group : $VM_RESOURCE_GROUP"
echo "  VM             : $VM_HOSTNAME ($VM_SIZE, $VM_OS)"
echo "  Public IP      : $VM_IP"
echo "  DNS / FQDN     : $VM_DNS"
if [[ -n "${CUSTOM_FQDN:-}" ]]; then
echo "  Custom FQDN    : $CUSTOM_FQDN  (A -> $STATIC_IP)"
fi
echo "  Key Vault      : $KEY_VAULT_NAME"
echo "  Identity       : $IDENTITY_NAME"
echo "  SSH            : ssh -i $VM_SSH_KEY ${VM_ADMIN_USER}@${VM_DNS:-$VM_IP}"
echo "  Modules        : $(tr '\n' ' ' < "$PAYLOAD/manifest.txt")"
echo "  Provision log  : /var/log/aza-provision.log (on the VM)"
echo "  Web services   : https://${VM_DNS}/{guacamole,webmin,kibana,grafana,prometheus,splunk}/"
log "============================================================"
if [[ -n "${DELEGATION_HINT:-}" ]]; then
  echo
  warn "ONE-TIME DNS DELEGATION — at your '${DNS_ZONE#*.}' registrar, add NS records for"
  warn "the '${DNS_ZONE%%.*}' subdomain pointing to these Azure name servers:"
  while IFS= read -r ns; do echo "      $ns"; done <<< "$DELEGATION_HINT"
  warn "Once delegation propagates, bind the cert on the VM with:"
  warn "  ssh -i $VM_SSH_KEY ${VM_ADMIN_USER}@${VM_DNS} \\"
  warn "    'sudo certbot --nginx -d ${VM_DNS} -d ${CUSTOM_FQDN} --expand --non-interactive --agree-tos --redirect -m ${CERTBOT_EMAIL:-you@example.com}'"
fi
