# =============================================================================
# CreateAzaAzure — non-secret configuration  (safe to commit)
# =============================================================================
# Every value supports environment override, e.g.:
#   VM_REGION=eastus VM_SIZE=Standard_D4s_v3 ./deploy.sh
# Secrets do NOT live here — see .env / .env.example.
# -----------------------------------------------------------------------------

# ---- Azure / subscription --------------------------------------------------
AZURE_SUBSCRIPTION="${AZURE_SUBSCRIPTION:-JacobAzure}"
VM_RESOURCE_GROUP="${VM_RESOURCE_GROUP:-rg-axa}"
VM_REGION="${VM_REGION:-westus3}"

# ---- VM ---------------------------------------------------------------------
VM_HOSTNAME="${VM_HOSTNAME:-axa}"          # also the public DNS label: <name>.<region>.cloudapp.azure.com
VM_OS="${VM_OS:-Ubuntu2204}"
VM_SIZE="${VM_SIZE:-Standard_D4s_v3}"      # 16GB — needed because ELK + Splunk are enabled by default
VM_DISK_SIZE="${VM_DISK_SIZE:-100}"
VM_ADMIN_USER="${VM_ADMIN_USER:-azureuser}"

# SSH key for the admin user (private key path; the .pub beside it is uploaded).
# Must be PASSWORDLESS so the automation (cloud-init wait, backup, restore) can
# use it non-interactively. deploy.sh generates this keypair if it is missing.
VM_SSH_KEY="${VM_SSH_KEY:-$HOME/.ssh/aza_ed25519}"

# ---- Custom domain (Azure DNS) ----------------------------------------------
# Delegate a subdomain to Azure DNS ONCE (add the NS records deploy.sh prints at
# your registrar). After that, deploy.sh manages records under the zone and the
# VM gets a stable custom FQDN with its own Let's Encrypt cert.
#   DNS_ZONE   = the delegated zone hosted in Azure DNS  (e.g. az.aspl.net)
#   DNS_RECORD = host label for THIS VM within that zone (e.g. axa)
#   -> CUSTOM_FQDN = axa.az.aspl.net
# Leave DNS_ZONE empty to disable custom-domain handling (uses cloudapp FQDN only).
DNS_ZONE="${DNS_ZONE:-az.aspl.net}"
DNS_RECORD="${DNS_RECORD:-axa}"
# Keep the DNS zone in a SEPARATE persistent RG so destroy.sh never deletes it
# (the NS delegation you set up once stays valid across VM rebuilds).
DNS_ZONE_RG="${DNS_ZONE_RG:-rg-dns}"
if [[ -n "$DNS_ZONE" ]]; then
  CUSTOM_FQDN="${DNS_RECORD}.${DNS_ZONE}"
else
  CUSTOM_FQDN=""
fi

# ---- Identity / Key Vault ---------------------------------------------------
# Key Vault names are GLOBALLY unique, 3-24 chars, alphanumeric + hyphens.
KEY_VAULT_NAME="${KEY_VAULT_NAME:-kv-${VM_HOSTNAME}-${VM_REGION}}"
KEY_VAULT_ADMINS="${KEY_VAULT_ADMINS:-AAD DC Administrators}"  # AAD group granted KV admin (best-effort)
PASSWORD_LENGTH="${PASSWORD_LENGTH:-20}"

# ---- Provisioning behaviour -------------------------------------------------
# Wait for cloud-init to finish on the VM before deploy.sh returns (one-touch).
WAIT_FOR_CLOUD_INIT="${WAIT_FOR_CLOUD_INIT:-true}"
# Install the Azure AD SSH login extension (lets you `az ssh vm`). SSH key still works regardless.
ENABLE_AAD_SSH_LOGIN="${ENABLE_AAD_SSH_LOGIN:-false}"

# =============================================================================
# Service modules — toggle on/off. Order of execution is the numeric filename
# prefix in modules/. Add a new service by dropping modules/NN-name.sh and a
# matching ENABLE_ flag here (see README "Adding a service").
# =============================================================================
ENABLE_BASE="${ENABLE_BASE:-true}"            # 00 base host: packages, az cli, hostname/timezone/locale
ENABLE_FIREWALL="${ENABLE_FIREWALL:-true}"    # 10 UFW
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-true}"    # 15 fail2ban
ENABLE_MYSQL="${ENABLE_MYSQL:-true}"          # 20 local MySQL
ENABLE_GUACAMOLE="${ENABLE_GUACAMOLE:-true}"  # 25 Guacamole (Docker)
ENABLE_DBEDITOR="${ENABLE_DBEDITOR:-true}"    # 27 Adminer web DB editor (/db/)
ENABLE_VMTOOLS_AUTH="${ENABLE_VMTOOLS_AUTH:-true}"  # 28 Azure AD sign-on (oauth2-proxy) for /shell/ + /db/
ENABLE_NGINX="${ENABLE_NGINX:-true}"          # 30 Nginx + Certbot reverse proxy
ENABLE_PRIVOXY="${ENABLE_PRIVOXY:-true}"      # 35 Privoxy
ENABLE_MAIL="${ENABLE_MAIL:-true}"            # 40 Postfix mail
ENABLE_LYNIS="${ENABLE_LYNIS:-true}"          # 50 Lynis audit
ENABLE_WEBMIN="${ENABLE_WEBMIN:-true}"        # 55 Webmin
ENABLE_ELK="${ENABLE_ELK:-true}"              # 60 Elasticsearch/Kibana/Logstash + Grafana + Prometheus
ENABLE_MONITORING="${ENABLE_MONITORING:-true}" # 62 base metrics+logs config (node_exporter, grafana ds/dash, filebeat)
ENABLE_SPLUNK="${ENABLE_SPLUNK:-true}"        # 65 Splunk Free
ENABLE_PENTEST="${ENABLE_PENTEST:-true}"      # 70 pentesting toolkit
ENABLE_NETTOOLS="${ENABLE_NETTOOLS:-true}"    # 72 real-time net tools (Netdata, ntopng, blackbox, Uptime Kuma, CLI)
ENABLE_WEBSSH="${ENABLE_WEBSSH:-true}"        # 75 ttyd browser terminal at /shell/
ENABLE_IDLE_STOP="${ENABLE_IDLE_STOP:-true}"  # 80 idle auto-deallocate agent
ENABLE_HEALTH="${ENABLE_HEALTH:-true}"        # 85 service-health publisher (/health.json)
ENABLE_SNAPSHOT="${ENABLE_SNAPSHOT:-true}"    # 90 timeshift initial snapshot

# ---- Guacamole --------------------------------------------------------------
# true  -> use the local MySQL installed by the mysql module
# false -> use an external DB (creds from Key Vault: guacamoleHost/User/Password).
#          Preferred for the on-demand model so Guacamole connections/users persist
#          across VM rebuilds. The guacadmin web password is reset to the vaulted
#          guacAdminPassword on each provision (off the insecure default).
GUAC_USE_LOCAL_MYSQL="${GUAC_USE_LOCAL_MYSQL:-false}"

# ---- Mail relay (Postfix submission + OpenDKIM) -----------------------------
# Space- or comma-separated list of domains the authenticated relay signs/sends
# for. The first is primary (myorigin). Each gets its own DKIM key; publish the
# DKIM/SPF/DMARC records the module writes to /etc/aza/mail-dns.txt in each
# domain's DNS zone. Defaults to the Azure DNS_ZONE.
MAIL_DOMAINS="${MAIL_DOMAINS:-az.aspl.net poker-mates.com}"

# ---- Splunk Free ------------------------------------------------------------
# Update to the current release from https://www.splunk.com/en_us/download/splunk-enterprise.html
# (Splunk Free is the same package; the free license activates with no login.)
SPLUNK_DEB_URL="${SPLUNK_DEB_URL:-https://download.splunk.com/products/splunk/releases/9.3.1/linux/splunk-9.3.1-0b8d769cb912-linux-2.6-amd64.deb}"
SPLUNK_WEB_PORT="${SPLUNK_WEB_PORT:-8000}"

# =============================================================================
# Networking — NSG inbound ports. Trim this list to shrink the attack surface.
# Format: "Name:proto:priority:ports"  (ports space- or comma-separated)
# =============================================================================
# HARDENED: only SSH, HTTP/HTTPS, and Privoxy are public. Every other web/admin
# service (Guacamole, Webmin, Kibana, Grafana, Prometheus, Splunk) is reached ONLY
# through nginx (TLS + AAD gate) and binds to localhost — so it is not exposed on
# the public IP. Mail ports are closed (no inbound mail). Add a rule back here AND
# in modules/10-firewall.sh if you intentionally re-expose a service.
NSG_RULES=(
  "AllowSSH:tcp:1000:22"
  "AllowHTTP:tcp:1010:80"
  "AllowHTTPS:tcp:1020:443"
  "Privoxy:tcp:1050:8118"
  "Submission:tcp:1055:587"
)

# =============================================================================
# Backup / restore — what to pull off the VM (logs intentionally excluded).
# =============================================================================
BACKUP_SOURCES=(
  "/home"        # all user home directories + dotfiles + ~/bin scripts
  "/root"        # root home + scripts
  "/usr/local/bin"
  "/etc/aza"     # any aza-specific config the modules drop here
)
BACKUP_EXCLUDES=(
  "*.log" "*.log.*" "log/" "logs/" "*.gz" "*.tmp"
  ".cache/" "cache/" ".npm/" ".cargo/" "snap/"
)
BACKUP_DIR="${BACKUP_DIR:-$SCRIPT_DIR/backups}"
