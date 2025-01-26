# Description: Variables for the CreateAxa Script
AZURE_SUBSCRIPTION="JacobAzure"
VM_RESOURCE_GROUP="rg-axa"
SUBNET_ADDRESS_PREFIX="10.0.0.0/24"
EMAIL_USER="jacobc@aspl.net"
VM_REGION="westus3"
VM_HOSTNAME="axa"
VM_OS="Ubuntu2204"
VM_SIZE="Standard_D2s_v3"
VM_AZURE_KEY="azure_id"
VM_DISK_SIZE="50"
KEYVAULT_NAME="kv-axa-$VM_REGION"
KEY_VAULT_ADMINS="AAD DC Administrators"
# Description: Variables for the Guacamole DB
PASSWORD_LENGTH="16"
GUAC_SQL_HOST="den1.mysql6.gear.host"
GUAC_SQL_USER="guacamoledb"
# Description: Variables for the CreateAxa Script
SCRIPT_UPDATE_PKGS="TRUE"
SCRIPT_SETUP_HOST="TRUE"
SCRIPT_FIREWALL_INSTALL="TRUE"
SCRIPT_FAIL2BAN_INSTALL="TRUE"
SCRIPT_MAIL_SETUP="FALSE"
SCRIPT_GUAC_INSTALL="TRUE"
SCRIPT_NGINX_INSTALL="TRUE"
SCRIPT_PRIVOXY_INSTALL="TRUE"
SCRIPT_MYSQL_INSTALL="TRUE"
SCRIPT_LYNIS_INSTALL="TRUE"
SCRIPT_TAKE_BACKUP="FALSE"