#!/bin/bash
# Exit if any command fails
set -e

# Commit Code to GitHub
# echo "Committing code to GitHub"
# git commit -a -m "Creating AXA"
# git push
# Import Variables from the variables file
source ./variables.sh

# Check Account and Set Subscription
echo "## Checking Azure account and setting subscription"
az account show
az account set --subscription $AZURE_SUBSCRIPTION

# Get password from environment variable for Guacamole DB
# We need to get this password and store it in the Key Vault since it is hosted on GearHost
echo "## Checking Guacamole DB password environment variable"
if [ -z "$GUAC_SQL_PASS" ]; then
    echo "## Error: GUAC_SQL_PASS for Guacamole environment variable is not set."
    exit 1
fi

# Create azure resource group called if it does not exist
echo "## Creating Azure resource group"
az group create --name $VM_RESOURCE_GROUP --location $VM_REGION

# Create azure DNS Name if it does not exist
# Check if the DNS name exists
echo "## Checking if Azure DNS name exists"
if ! az network public-ip show --resource-group $VM_RESOURCE_GROUP --name ${VM_HOSTNAME}-ip &>/dev/null; then
    echo "## Creating Azure DNS name"
    az network public-ip create --resource-group $VM_RESOURCE_GROUP --name ${VM_HOSTNAME}-ip --dns-name ${VM_HOSTNAME}

    # Create a network security group
    echo "## Creating network security group"
    az network nsg create --resource-group $VM_RESOURCE_GROUP --name ${VM_HOSTNAME}-nsg

    # Create network security group rules
    echo "## Creating network security group rules"
    az network nsg rule create --resource-group $VM_RESOURCE_GROUP --nsg-name ${VM_HOSTNAME}-nsg --name AllowSSH --protocol tcp --priority 1000 --destination-port-range 22 --access allow
    az network nsg rule create --resource-group $VM_RESOURCE_GROUP --nsg-name ${VM_HOSTNAME}-nsg --name AllowHTTP --protocol tcp --priority 1010 --destination-port-range 80 --access allow
    az network nsg rule create --resource-group $VM_RESOURCE_GROUP --nsg-name ${VM_HOSTNAME}-nsg --name AllowHTTPS --protocol tcp --priority 1020 --destination-port-range 443 --access allow
    az network nsg rule create --resource-group $VM_RESOURCE_GROUP --nsg-name ${VM_HOSTNAME}-nsg --name Allow8080 --protocol tcp --priority 1030 --destination-port-range 8080 --access allow
    az network nsg rule create --resource-group $VM_RESOURCE_GROUP --nsg-name ${VM_HOSTNAME}-nsg --name Allow8118 --protocol tcp --priority 1040 --destination-port-range 8118 --access allow
else
    echo "## DNS name ${VM_HOSTNAME} already exists."
fi

# # Create a virtual network and subnet
# echo "## Creating virtual network and subnet"
# az network vnet create --resource-group $VM_RESOURCE_GROUP --name ${VM_HOSTNAME}-vnet --address-prefix $VNET_ADDRESS_PREFIX --subnet-name ${VM_HOSTNAME}-subnet --subnet-prefix $SUBNET_ADDRESS_PREFIX

# Create the VM if it does not exist already
echo "## Creating the VM if it does not exist already"
if ! az vm show --resource-group $VM_RESOURCE_GROUP --name $VM_HOSTNAME &>/dev/null; then
    az vm create \
        --resource-group $VM_RESOURCE_GROUP \
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
        --ssh-key-value ~/.ssh/$VM_AZURE_KEY.pub
else
    echo "## VM $VM_HOSTNAME already exists."
fi

# Get the public IP address of the VM
echo "## Getting the public IP address of the VM"
VM_IP=$(az vm show --resource-group $VM_RESOURCE_GROUP --name $VM_HOSTNAME --show-details --query publicIps -o tsv)
echo "## Public IP address of the VM is $VM_IP"

# Get the DNS name of the VM
echo "## Getting the DNS name of the VM"
VM_DNS=$(az network public-ip show --resource-group $VM_RESOURCE_GROUP --name ${VM_HOSTNAME}-ip --query dnsSettings.fqdn -o tsv)
echo "## DNS name of the VM is $VM_DNS"

# Check if the Key Vault exists
echo "## Checking if Key Vault exists"
if ! az keyvault show --name $KEYVAULT_NAME --resource-group $VM_RESOURCE_GROUP &>/dev/null; then
    # Create a Key Vault
    echo "## Creating a Key Vault"
    az keyvault create --name $KEYVAULT_NAME --resource-group $VM_RESOURCE_GROUP --location $VM_REGION

    # Generate and store passwords in Key Vault
    echo "## Generating and storing passwords in Key Vault"
    NGINX_PASSWORD=$(openssl rand -base64 $PASSWORD_LENGTH)
    PRIVOXY_PASSWORD=$(openssl rand -base64 $PASSWORD_LENGTH)
    MYSQL_ADMIN_PASSWORD=$(openssl rand -base64 $PASSWORD_LENGTH) # MySQL root password

    az keyvault secret set --vault-name $KEYVAULT_NAME --name "nginxPassword" --value $NGINX_PASSWORD
    az keyvault secret set --vault-name $KEYVAULT_NAME --name "privoxyPassword" --value $PRIVOXY_PASSWORD
    az keyvault secret set --vault-name $KEYVAULT_NAME --name "mysqlAdminPassword" --value $MYSQL_ADMIN_PASSWORD
    az keyvault secret set --vault-name $KEYVAULT_NAME --name "guacamoleHost" --value $GUAC_SQL_HOST
    az keyvault secret set --vault-name $KEYVAULT_NAME --name "guacamoleUser" --value $GUAC_SQL_USER
    az keyvault secret set --vault-name $KEYVAULT_NAME --name "guacamolePassword" --value $GUAC_SQL_PASS
else
    echo "## Key Vault $KEYVAULT_NAME already exists."
fi

# Check if the managed identity for the VM exists
echo "## Checking if managed identity for the VM exists"
if ! az identity show --name myIdentity --resource-group $VM_RESOURCE_GROUP &>/dev/null; then
    echo "## Creating a managed identity for the VM"
    az identity create --name myIdentity --resource-group $VM_RESOURCE_GROUP

    echo "## Assigning the managed identity to the VM"
    IDENTITY_ID=$(az identity show --name myIdentity --resource-group $VM_RESOURCE_GROUP --query 'id' -o tsv)
    az vm identity assign --resource-group $VM_RESOURCE_GROUP --name $VM_HOSTNAME --identities $IDENTITY_ID

    echo "## Setting Key Vault policy to allow the VM to access secrets"
    VM_PRINCIPAL_ID=$(az vm show --resource-group $VM_RESOURCE_GROUP --name $VM_HOSTNAME --query 'identity.principalId' -o tsv)
    az role assignment create --role "Key Vault Secrets User" --assignee $VM_PRINCIPAL_ID --scope /subscriptions/$(az account show --query id -o tsv)/resourceGroups/$VM_RESOURCE_GROUP/providers/Microsoft.KeyVault/vaults/$KEYVAULT_NAME
    IDENTITY_OBJECT_ID=$(az identity show --name myIdentity --resource-group $VM_RESOURCE_GROUP --query 'principalId' -o tsv)
    az role assignment create --role "Key Vault Secrets User" --assignee-object-id $IDENTITY_OBJECT_ID --assignee-principal-type ServicePrincipal --scope /subscriptions/$(az account show --query id -o tsv)/resourceGroups/$VM_RESOURCE_GROUP/providers/Microsoft.KeyVault/vaults/$KEYVAULT_NAME
else
    echo "## Managed identity for the VM already exists."
fi

# Display all the resources created
echo "## Resources created:"
echo "## Resource Group: $VM_RESOURCE_GROUP"
echo "## VM Name: $VM_HOSTNAME"
echo "## VM Region: $VM_REGION"
echo "## VM Size: $VM_SIZE"
echo "## VM Public IP: $VM_IP"
echo "## VM DNS Name: $VM_DNS"
echo "## Key Vault: $KEYVAULT_NAME"
echo "## Key Vault Secrets:"
echo "## - nginxPassword"
echo "## - privoxyPassword"
echo "## - mysqlAdminPassword"
echo "## - guacamoleHost"
echo "## - guacamoleUser"
echo "## - guacamolePassword"
echo "## Managed Identity: myIdentity"
echo "## Identity ID: $IDENTITY_ID"
echo "## Identity Object ID: $IDENTITY_OBJECT_ID"

# end of script
echo "## End of script"
echo "## The script has completed successfully."
echo "## Please check the output for any errors."
echo "## Exiting..."