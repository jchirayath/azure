#!/usr/bin/env bash
# Azure AD single sign-on for the web shell (/shell/) and DB editor (/db/) via
# oauth2-proxy. nginx (module 30) gates those locations with auth_request to the
# oauth2-proxy started here. One Microsoft login (tenant-locked), no basic-auth.
# Secrets come from Key Vault (created by deploy.sh): vmToolsClientId/Secret/CookieSecret.
set -uo pipefail
source "$AZA_HOME/lib/remote.sh"

CID="$(kv_get vmToolsClientId)"
SEC="$(kv_get vmToolsClientSecret)"
COO="$(kv_get vmToolsCookieSecret)"
if [[ -z "$CID" || -z "$SEC" || -z "$COO" ]]; then
  warn "vmTools* secrets not in Key Vault; skipping AAD gate (shell/db will rely on nginx defaults)."
  exit 0
fi
TENANT="$(az account show --query tenantId -o tsv 2>/dev/null)"
FQDN="$(vm_fqdn)"

log "Configuring oauth2-proxy (AAD sign-on for /shell/ and /db/)..."
sudo mkdir -p /etc/aza
sudo tee /etc/aza/oauth2-proxy.env >/dev/null <<EOF
OAUTH2_PROXY_PROVIDER=oidc
OAUTH2_PROXY_OIDC_ISSUER_URL=https://login.microsoftonline.com/${TENANT}/v2.0
OAUTH2_PROXY_CLIENT_ID=${CID}
OAUTH2_PROXY_CLIENT_SECRET=${SEC}
OAUTH2_PROXY_REDIRECT_URL=https://${FQDN}/oauth2/callback
OAUTH2_PROXY_COOKIE_SECRET=${COO}
OAUTH2_PROXY_EMAIL_DOMAINS=*
OAUTH2_PROXY_OIDC_EMAIL_CLAIM=preferred_username
OAUTH2_PROXY_INSECURE_OIDC_ALLOW_UNVERIFIED_EMAIL=true
OAUTH2_PROXY_HTTP_ADDRESS=0.0.0.0:4180
OAUTH2_PROXY_REVERSE_PROXY=true
OAUTH2_PROXY_UPSTREAMS=static://202
OAUTH2_PROXY_SKIP_PROVIDER_BUTTON=true
OAUTH2_PROXY_SET_XAUTHREQUEST=true
OAUTH2_PROXY_COOKIE_SECURE=true
OAUTH2_PROXY_WHITELIST_DOMAINS=${FQDN}
EOF
sudo chmod 600 /etc/aza/oauth2-proxy.env

sudo docker rm -f oauth2-proxy >/dev/null 2>&1 || true
sudo docker run -d --name oauth2-proxy --restart unless-stopped \
  --env-file /etc/aza/oauth2-proxy.env -p 127.0.0.1:4180:4180 \
  quay.io/oauth2-proxy/oauth2-proxy:latest >/dev/null

sleep 5
sudo docker ps --format '{{.Names}}' | grep -q '^oauth2-proxy$' \
  && ok "oauth2-proxy running — /shell/ and /db/ are AAD-gated." \
  || warn "oauth2-proxy did not start."
