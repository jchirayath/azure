#!/bin/bash
# Exit if any command fails
set -e

# Commit Code to GitHub
# git commit -a -m "Creating AXA"
# git push

# Check Account and Set Subscription
az account show
az account set --subscription JacobAzure

# Set VM variables
VM_RESOURCE_GROUP="rg-VMs"
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
if [ -z "$MY_GUACAMOLE_PASSWORD" ]; then
    echo "Error: MY_GUACAMOLE_PASSWORD environment variable is not set."
    exit 1
fi

# Get password from environment variable for MYSQL_ADMIN_PASSWORD
if [ -z "$MYSQL_ADMIN_PASSWORD" ]; then
    echo "Error: MYSQL_ADMIN_PASSWORD environment variable is not set."
    exit 1
fi

# Create azure resource group called rg-VMs-westus3 if it does not exist
az group create --name $VM_RESOURCE_GROUP-$VM_REGION --location $VM_REGION

# Create azure DNS Nam
az network public-ip create --resource-group $VM_RESOURCE_GROUP-$VM_REGION --name ${VM_HOSTNAME}-ip --dns-name ${VM_HOSTNAME}

# Create a network security group
az network nsg create --resource-group $VM_RESOURCE_GROUP-$VM_REGION --name ${VM_HOSTNAME}-nsg

# Create network security group rules
az network nsg rule create --resource-group $VM_RESOURCE_GROUP-$VM_REGION --nsg-name ${VM_HOSTNAME}-nsg --name AllowSSH --protocol tcp --priority 1000 --destination-port-range 22 --access allow
az network nsg rule create --resource-group $VM_RESOURCE_GROUP-$VM_REGION --nsg-name ${VM_HOSTNAME}-nsg --name AllowHTTP --protocol tcp --priority 1010 --destination-port-range 80 --access allow
az network nsg rule create --resource-group $VM_RESOURCE_GROUP-$VM_REGION --nsg-name ${VM_HOSTNAME}-nsg --name AllowHTTPS --protocol tcp --priority 1020 --destination-port-range 443 --access allow
az network nsg rule create --resource-group $VM_RESOURCE_GROUP-$VM_REGION --nsg-name ${VM_HOSTNAME}-nsg --name Allow8080 --protocol tcp --priority 1030 --destination-port-range 8080 --access allow

# Create the VM
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
    --ssh-key-value ~/.ssh/$VM_AZURE_KEY.pub

# Install VM extension AADLoginForLinux
az vm extension set \
    --resource-group $VM_RESOURCE_GROUP-$VM_REGION \
    --vm-name $VM_HOSTNAME \
    --name AADSSHLoginForLinux \
    --publisher Microsoft.Azure.ActiveDirectory \
    --settings '{}'

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

# Allow Azure admins to add secrets
ADMIN_GROUP_ID=$(az ad group show --group "$KEY_VAULT_ADMINS" --query id -o tsv)
az role assignment create --role "Key Vault Administrator" --assignee $ADMIN_GROUP_ID --scope /subscriptions/$(az account show --query id -o tsv)/resourceGroups/$VM_RESOURCE_GROUP-$VM_REGION/providers/Microsoft.KeyVault/vaults/$VAULT_NAME

# Key Vault Allow public access from specific virtual networks of VM
# Get the VM's subnet ID
VM_NIC_ID=$(az vm show --resource-group $VM_RESOURCE_GROUP-$VM_REGION --name $VM_HOSTNAME --query "networkProfile.networkInterfaces[0].id" -o tsv)
VM_SUBNET_ID=$(az network nic show --ids $VM_NIC_ID --query "ipConfigurations[0].subnet.id" -o tsv)
# Get the VM's virtual network ID
VM_VNET_ID=$(az network vnet show --ids $VM_SUBNET_ID --query "id" -o tsv)
# Allow the VM's virtual network to access the Key Vault
az keyvault network-rule add --name $VAULT_NAME --resource-group $VM_RESOURCE_GROUP-$VM_REGION --subnet $VM_SUBNET_ID

# wait for the role assignment to propagate
sleep 15

# # Create Secret in Azure Key Vault for Guacamole
myMyuSQLHOST="den1.mysql6.gear.host"
myUser="guacamoledb"
myPassword=$MY_GUACAMOLE_PASSWORD
az keyvault secret set --vault-name $VAULT_NAME --name "guacamoledbhost" --value $myMyuSQLHOST
az keyvault secret set --vault-name $VAULT_NAME --name "guacamoledbuser" --value $myUser
az keyvault secret set --vault-name $VAULT_NAME --name "guacamoledbpass" --value $myPassword

# Add MySQL admin password to Key Vault
az keyvault secret set --vault-name $VAULT_NAME --name "mysql-admin-password" --value $MYSQL_ADMIN_PASSWORD

# Enable the VM to query Key Vault secrets
az vm identity assign --resource-group $VM_RESOURCE_GROUP-$VM_REGION --name $VM_HOSTNAME
VM_IDENTITY=$(az vm show --resource-group $VM_RESOURCE_GROUP-$VM_REGION --name $VM_HOSTNAME --query identity.principalId -o tsv)
az role assignment create --role "Key Vault Reader" --assignee $VM_IDENTITY --scope /subscriptions/$(az account show --query id -o tsv)/resourceGroups/$VM_RESOURCE_GROUP-$VM_REGION/providers/Microsoft.KeyVault/vaults/$VAULT_NAME

# download the install script to the local directory
# Create a new file from wget and make it executable
wget -O $VM_INSTALL_SCRIPT $VM_INSTALL_SCRIPT_URL
chmod +x $VM_INSTALL_SCRIPT

Update the install_script.sh with Variables from CreateVM.sh
# Update the install_script.sh with variables from CreateVM.sh
sed -i "s|<VM_HOSTNAME>|$VM_HOSTNAME|g" $VM_INSTALL_SCRIPT
sed -i "s|<VM_REGION>|$VM_REGION|g" $VM_INSTALL_SCRIPT
sed -i "s|<VM_SIZE>|$VM_SIZE|g" $VM_INSTALL_SCRIPT
sed -i "s|<VM_OS>|$VM_OS|g" $VM_INSTALL_SCRIPT
sed -i "s|<VM_DISK_SIZE>|$VM_DISK_SIZE|g" $VM_INSTALL_SCRIPT
sed -i "s|<MY_GUACAMOLE_PASSWORD>|$MY_GUACAMOLE_PASSWORD|g" $VM_INSTALL_SCRIPT
sed -i "s|<MYSQL_ADMIN_PASSWORD>|$MYSQL_ADMIN_PASSWORD|g" $VM_INSTALL_SCRIPT

# # Add a custom script extension to the VM to run an install script
# az vm extension set \
#     --resource-group $VM_RESOURCE_GROUP-$VM_REGION \
#     --vm-name $VM_HOSTNAME \
#     --name customScript \
#     --publisher Microsoft.Azure.Extensions \
#     --settings "{\"fileUris\": [\"$VM_INSTALL_SCRIPT_URL\"], \"commandToExecute\": \"./$VM_INSTALL_SCRIPT\"}"
