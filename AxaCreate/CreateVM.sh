#!/bin/bash
# Commit Code to GitHub
# git commit -a -m "Creating AXA"
# git push

# Check Account and Set Subscription
az account show
az account set --subscription JacobAzure
# Exit if any command fails
set -e

# Set VM variables
VM_RESOURCE_GROUP="rg-VMs"
VM_REGION="westus3"
VM_HOSTNAME="axa"
VM_OS="Ubuntu2204"
VM_SIZE="Standard_D2s_v3"
VM_AZURE_KEY="azure_id"
VM_DISK_SIZE="50"
VM_INSTALL_SCRIPT="install_script.sh"
VM_INSTALL_SCRIPT_URL="https://raw.githubusercontent.com/jchirayath/azure/refs/heads/master/AxaCreate/$VM_INSTALL_SCRIPT"
# KEY Vault Admins
KEY_VAULT_ADMINS='AAD DC Administrators'

# # Create azure resource group called rg-VMs-westus3 if it does not exist
# az group create --name $VM_RESOURCE_GROUP-$VM_REGION --location $VM_REGION
# # Exit if any command fails
# set -e

# # Create azure DNS Nam
# az network public-ip create --resource-group $VM_RESOURCE_GROUP-$VM_REGION --name ${VM_HOSTNAME}-ip --dns-name ${VM_HOSTNAME}
# # Exit if any command fails
# set -e

# # Create a network security group
# az network nsg create --resource-group $VM_RESOURCE_GROUP-$VM_REGION --name ${VM_HOSTNAME}-nsg
# # Exit if any command fails
# set -e

# # Create network security group rules
# az network nsg rule create --resource-group $VM_RESOURCE_GROUP-$VM_REGION --nsg-name ${VM_HOSTNAME}-nsg --name AllowSSH --protocol tcp --priority 1000 --destination-port-range 22 --access allow
# az network nsg rule create --resource-group $VM_RESOURCE_GROUP-$VM_REGION --nsg-name ${VM_HOSTNAME}-nsg --name AllowHTTP --protocol tcp --priority 1010 --destination-port-range 80 --access allow
# az network nsg rule create --resource-group $VM_RESOURCE_GROUP-$VM_REGION --nsg-name ${VM_HOSTNAME}-nsg --name AllowHTTPS --protocol tcp --priority 1020 --destination-port-range 443 --access allow
# az network nsg rule create --resource-group $VM_RESOURCE_GROUP-$VM_REGION --nsg-name ${VM_HOSTNAME}-nsg --name Allow8080 --protocol tcp --priority 1030 --destination-port-range 8080 --access allow
# # Exit if any command fails
# set -e

# # Create the VM
# az vm create \
#     --resource-group $VM_RESOURCE_GROUP-$VM_REGION \
#     --name $VM_HOSTNAME \
#     --image $VM_OS \
#     --size $VM_SIZE \
#     --assign-identity \
#     --admin-username azureuser \
#     --enable-agent true \
#     --enable-auto-update true \
#     --enable-secure-boot true \
#     --enable-vtpm true \
#     --public-ip-address ${VM_HOSTNAME}-ip \
#     --nsg ${VM_HOSTNAME}-nsg \
#     --os-disk-delete-option Delete \
#     --os-disk-name ${VM_HOSTNAME}-osdisk \
#     --os-disk-size-gb $VM_DISK_SIZE \
#     --vnet-name ${VM_HOSTNAME}-vnet \
#     --ssh-key-value ~/.ssh/$VM_AZURE_KEY.pub
# # Exit if any command fails
# set -e

# Install VM extension AADLoginForLinux
# az vm extension set \
#     --resource-group $VM_RESOURCE_GROUP-$VM_REGION \
#     --vm-name $VM_HOSTNAME \
#     --name AADSSHLoginForLinux \
#     --publisher Microsoft.Azure.ActiveDirectory \
#     --settings '{}'

# Create a Key Vault
# Check if Key Vault exists, create if it does not
VAULT_NAME="kv-aspl-$VM_REGION"
if ! az keyvault show --name $VAULT_NAME &>/dev/null; then
    az keyvault create --name $VAULT_NAME --resource-group $VM_RESOURCE_GROUP-$VM_REGION --location $VM_REGION
    # Exit if any command fails
    set -e
else
    echo "Key Vault $VAULT_NAME already exists."
fi

# # Allow Azure admins to add secrets
# ADMIN_GROUP_ID=$(az ad group show --group "$KEY_VAULT_ADMINS" --query id -o tsv)
# az role assignment create --role "Key Vault Administrator" --assignee $ADMIN_GROUP_ID --scope /subscriptions/$(az account show --query id -o tsv)/resourceGroups/$VM_RESOURCE_GROUP-$VM_REGION/providers/Microsoft.KeyVault/vaults/$VAULT_NAME

# # wait for the role assignment to propagate
# sleep 15

# # Create Secret in Azure Key Vault for Guacamole
# myMyuSQLHOST="den1.mysql6.gear.host"
# myUser="guacamoledb"
# # Get password from environment variable
# if [ -z "$MY_PASSWORD" ]; then
#     echo "Error: MY_PASSWORD environment variable is not set."
#     exit 1
# fi
# myPassword=$MY_PASSWORD
# az keyvault secret set --vault-name $VAULT_NAME --name "guacamoledbhost" --value $myMyuSQLHOST
# az keyvault secret set --vault-name $VAULT_NAME --name "guacamoledbuser" --value $myUser
# az keyvault secret set --vault-name $VAULT_NAME --name "guacamoledbpass" --value $myPassword

# Enable the VM to query Key Vault secrets
az vm identity assign --resource-group $VM_RESOURCE_GROUP-$VM_REGION --name $VM_HOSTNAME
VM_IDENTITY=$(az vm show --resource-group $VM_RESOURCE_GROUP-$VM_REGION --name $VM_HOSTNAME --query identity.principalId -o tsv)
az role assignment create --role "Key Vault Reader" --assignee $VM_IDENTITY --scope /subscriptions/$(az account show --query id -o tsv)/resourceGroups/$VM_RESOURCE_GROUP-$VM_REGION/providers/Microsoft.KeyVault/vaults/$VAULT_NAME


# # Add a custom script extension to the VM to run an install script
# az vm extension set \
#     --resource-group $VM_RESOURCE_GROUP-$VM_REGION \
#     --vm-name $VM_HOSTNAME \
#     --name customScript \
#     --publisher Microsoft.Azure.Extensions \
#     --settings "{\"fileUris\": [\"$VM_INSTALL_SCRIPT_URL\"], \"commandToExecute\": \"./$VM_INSTALL_SCRIPT\"}"
