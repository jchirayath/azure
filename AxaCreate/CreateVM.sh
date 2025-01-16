#!/bin/bash
# Exit if any command fails
set -e

# Commit Code to GitHub
# echo "Committing code to GitHub"
# git commit -a -m "Creating AXA"
# git push

# Check Account and Set Subscription
echo "## Checking Azure account and setting subscription"
az account show
az account set --subscription JacobAzure

# Set VM variables
echo "## Setting VM variables"
VM_RESOURCE_GROUP="rg-VMs"
EMAIL_USER='jacobc@aspl.net'
VM_REGION="westus3"
VM_HOSTNAME="axa"
VM_OS="Ubuntu2204"
VM_SIZE="Standard_D2s_v3"
VM_AZURE_KEY="azure_id"
VM_DISK_SIZE="50"
VM_INSTALL_SCRIPT="install_script.sh"
VM_INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/jchirayath/azure/refs/heads/master/AxaCreate/install_script_template.sh"
# KEY Vault Admins
KEY_VAULT_ADMINS='AAD DC Administrators'

# Get password from environment variable for Guacamole DB
echo "## Checking Guacamole DB password environment variable"
if [ -z "$myMySQLPASS" ]; then
    echo "## Error: myMySQLPASS for Guacamole environment variable is not set."
    exit 1
fi

# Get password from environment variable for MYSQL_ADMIN_PASSWORD
echo "## Checking MySQL admin password environment variable"
if [ -z "$MYSQL_ADMIN_PASSWORD" ]; then
    echo "## Error: MYSQL_ADMIN_PASSWORD environment variable is not set."
    exit 1
fi

# Create azure resource group called rg-VMs-westus3 if it does not exist
echo "## Creating Azure resource group"
az group create --name $VM_RESOURCE_GROUP-$VM_REGION --location $VM_REGION

# Create azure DNS Name
echo "## Creating Azure DNS name"
az network public-ip create --resource-group $VM_RESOURCE_GROUP-$VM_REGION --name ${VM_HOSTNAME}-ip --dns-name ${VM_HOSTNAME}

# Create a network security group
echo "## Creating network security group"
az network nsg create --resource-group $VM_RESOURCE_GROUP-$VM_REGION --name ${VM_HOSTNAME}-nsg

# Create network security group rules
echo "## Creating network security group rules"
az network nsg rule create --resource-group $VM_RESOURCE_GROUP-$VM_REGION --nsg-name ${VM_HOSTNAME}-nsg --name AllowSSH --protocol tcp --priority 1000 --destination-port-range 22 --access allow
az network nsg rule create --resource-group $VM_RESOURCE_GROUP-$VM_REGION --nsg-name ${VM_HOSTNAME}-nsg --name AllowHTTP --protocol tcp --priority 1010 --destination-port-range 80 --access allow
az network nsg rule create --resource-group $VM_RESOURCE_GROUP-$VM_REGION --nsg-name ${VM_HOSTNAME}-nsg --name AllowHTTPS --protocol tcp --priority 1020 --destination-port-range 443 --access allow
az network nsg rule create --resource-group $VM_RESOURCE_GROUP-$VM_REGION --nsg-name ${VM_HOSTNAME}-nsg --name Allow8080 --protocol tcp --priority 1030 --destination-port-range 8080 --access allow

# Create a virtual network and subnet
# echo "## Creating virtual network and subnet"
# az network vnet create --resource-group $VM_RESOURCE_GROUP-$VM_REGION --name ${VM_HOSTNAME}-vnet --address-prefix 10.0.0.0/16 --subnet-name default --subnet-prefix 10.0.0.0/24

# Create the VM
echo "## Creating the VM"
if ! az vm show --resource-group $VM_RESOURCE_GROUP-$VM_REGION --name $VM_HOSTNAME &>/dev/null; then
    az vm create \
        --resource-group $VM_RESOURCE_GROUP-$VM_REGION \
        --name $VM_HOSTNAME \
        --image $VM_OS \
        --size $VM_SIZE \
        --assign-identity \
        --admin-username azureuser \
        --enable-agent true \
        --enable-auto-update true \
        --enable-secure-boot true \
        --enable-vtpm true \
        --public-ip-address ${VM_HOSTNAME}-ip \
        --nsg ${VM_HOSTNAME}-nsg \
        --os-disk-delete-option Delete \
        --os-disk-name ${VM_HOSTNAME}-osdisk \
        --os-disk-size-gb $VM_DISK_SIZE \
        --vnet-name ${VM_HOSTNAME}-vnet \
        --ssh-key-value ~/.ssh/$VM_AZURE_KEY.pub \
        --role contributor --scope /subscriptions/$(az account show --query id -o tsv)/resourceGroups/$VM_RESOURCE_GROUP-$VM_REGION
else
    echo "## VM $VM_HOSTNAME already exists."
fi

# Install VM extension AADLoginForLinux
echo "## Installing VM extension AADLoginForLinux"
az vm extension set \
    --resource-group $VM_RESOURCE_GROUP-$VM_REGION \
    --vm-name $VM_HOSTNAME \
    --name AADSSHLoginForLinux \
    --publisher Microsoft.Azure.ActiveDirectory \
    --settings '{}'

# Create a Key Vault
echo "## Creating a Key Vault"
VAULT_NAME="kv-aspl-$VM_REGION"
if ! az keyvault show --name $VAULT_NAME &>/dev/null; then
    az keyvault create --name $VAULT_NAME --resource-group $VM_RESOURCE_GROUP-$VM_REGION --location $VM_REGION
    # Exit if any command fails
    set -e
else
    echo "## Key Vault $VAULT_NAME already exists."
fi

# Allow Azure admins to add secrets
echo "## Allowing Azure admins to add secrets"
ADMIN_GROUP_ID=$(az ad group show --group "$KEY_VAULT_ADMINS" --query id -o tsv)
az role assignment create --role "Key Vault Administrator" --assignee $ADMIN_GROUP_ID --scope /subscriptions/$(az account show --query id -o tsv)/resourceGroups/$VM_RESOURCE_GROUP-$VM_REGION/providers/Microsoft.KeyVault/vaults/$VAULT_NAME

# wait for the role assignment to propagate
echo "## Waiting for role assignment to propagate"
sleep 15

# Create Secret in Azure Key Vault for Guacamole
echo "## Creating secrets in Azure Key Vault for Guacamole"
myMySQLHOST="den1.mysql6.gear.host"
myMySQLUSER="guacamoledb"
myMySQLPASS=$myMySQLPASS
az keyvault secret set --vault-name $VAULT_NAME --name "guacamoledbhost" --value $myMySQLHOST
az keyvault secret set --vault-name $VAULT_NAME --name "guacamoledbuser" --value $myMySQLUSER
az keyvault secret set --vault-name $VAULT_NAME --name "guacamoledbpass" --value $myMySQLPASS

# Add MySQL admin password to Key Vault
echo "## Adding MySQL admin password to Key Vault"
az keyvault secret set --vault-name $VAULT_NAME --name "mysql-admin-password" --value $MYSQL_ADMIN_PASSWORD

# Enable the VM to query Key Vault secrets
echo "## Enabling the VM to query Key Vault secrets"
az vm identity assign --resource-group $VM_RESOURCE_GROUP-$VM_REGION --name $VM_HOSTNAME
VM_IDENTITY=$(az vm show --resource-group $VM_RESOURCE_GROUP-$VM_REGION --name $VM_HOSTNAME --query identity.principalId -o tsv)
az role assignment create --role "Key Vault Reader" --assignee $VM_IDENTITY --scope /subscriptions/$(az account show --query id -o tsv)/resourceGroups/$VM_RESOURCE_GROUP-$VM_REGION/providers/Microsoft.KeyVault/vaults/$VAULT_NAME

# download the install script to the local directory
echo "## Downloading the install script"
wget -O $VM_INSTALL_SCRIPT $VM_INSTALL_SCRIPT_URL
chmod +x $VM_INSTALL_SCRIPT

# Update the install_script.sh with variables from CreateVM.sh
echo "## Updating the install script with variables"
sed -i '' "s|<VM_REGION>|$VM_REGION|g" $VM_INSTALL_SCRIPT
sed -i '' "s|<VM_HOSTNAME>|$VM_HOSTNAME|g" $VM_INSTALL_SCRIPT
sed -i '' "s|<VM_RESOURCE_GROUP>|$VM_RESOURCE_GROUP|g" $VM_INSTALL_SCRIPT
#
sed -i '' "s|<MYSQL_ADMIN_PASSWORD>|$MYSQL_ADMIN_PASSWORD|g" $VM_INSTALL_SCRIPT
sed -i '' "s|<MySQLHOST>|$myMySQLHOST|g" $VM_INSTALL_SCRIPT
sed -i '' "s|<MySQLUSER>|$myMySQLUSER|g" $VM_INSTALL_SCRIPT
sed -i '' "s|<MySQLPASS>|$myMySQLPASS|g" $VM_INSTALL_SCRIPT
sed -i '' "s|<EMAIL_USER>|$EMAIL_USER|g" $VM_INSTALL_SCRIPT
sed -i '' "s|<VAULT_NAME>|$VAULT_NAME|g" $VM_INSTALL_SCRIPT

# Add a custom script extension to the VM to run an install script
# echo "Adding a custom script extension to the VM"
# az vm extension set \
#     --resource-group $VM_RESOURCE_GROUP-$VM_REGION \
#     --vm-name $VM_HOSTNAME \
#     --name customScript \
#     --publisher Microsoft.Azure.Extensions \
#     --settings "{\"fileUris\": [\"$VM_INSTALL_SCRIPT_URL\"], \"commandToExecute\": \"./$VM_INSTALL_SCRIPT\"}"
