#!/bin/bash

# Variables
RESOURCE_GROUP="rg-VMs-westus3"
LOCATION="westus3"
VM_NAME="axa"
VM_IMAGE="UbuntuLTS"
ADMIN_USERNAME="azureuser"
KEYVAULT_NAME="kv-aspl-westus3"
PASSWORD_LENGTH=16

# # Create a resource group
# az group create --name $RESOURCE_GROUP --location $LOCATION

# # Create a virtual machine
# az vm create \
#     --resource-group $RESOURCE_GROUP \
#     --name $VM_NAME \
#     --image $VM_IMAGE \
#     --admin-username $ADMIN_USERNAME \
#     --generate-ssh-keys

# # Install and update networking tools, nginx, privoxy, mysql
# az vm extension set \
#     --resource-group $RESOURCE_GROUP \
#     --vm-name $VM_NAME \
#     --name customScript \
#     --publisher Microsoft.Azure.Extensions \
#     --settings '{"fileUris":["https://raw.githubusercontent.com/Azure/azure-quickstart-templates/master/101-vm-simple-linux/scripts/install.sh"],"commandToExecute":"./install.sh"}'

# # Create a Key Vault
# az keyvault create --name $KEYVAULT_NAME --resource-group $RESOURCE_GROUP --location $LOCATION

# # Generate and store passwords in Key Vault
# NGINX_PASSWORD=$(openssl rand -base64 $PASSWORD_LENGTH)
# PRIVOXY_PASSWORD=$(openssl rand -base64 $PASSWORD_LENGTH)
# MYSQL_PASSWORD=$(openssl rand -base64 $PASSWORD_LENGTH)
# GUACAMOLE_PASSWORD=$(openssl rand -base64 $PASSWORD_LENGTH)

# az keyvault secret set --vault-name $KEYVAULT_NAME --name "nginxPassword" --value $NGINX_PASSWORD
# az keyvault secret set --vault-name $KEYVAULT_NAME --name "privoxyPassword" --value $PRIVOXY_PASSWORD
# az keyvault secret set --vault-name $KEYVAULT_NAME --name "mysqlPassword" --value $MYSQL_PASSWORD
# az keyvault secret set --vault-name $KEYVAULT_NAME --name "guacamolePassword" --value $GUACAMOLE_PASSWORD

# # Secure the machine with firewall and fail2ban
# az vm extension set \
#     --resource-group $RESOURCE_GROUP \
#     --vm-name $VM_NAME \
#     --name customScript \
#     --publisher Microsoft.Azure.Extensions \
#     --settings '{"fileUris":["https://example.com/scripts/security.sh"],"commandToExecute":"./security.sh"}'

# # Install Apache Guacamole
# az vm extension set \
#     --resource-group $RESOURCE_GROUP \
#     --vm-name $VM_NAME \
#     --name customScript \
#     --publisher Microsoft.Azure.Extensions \
#     --settings '{"fileUris":["https://example.com/scripts/install_guacamole.sh"],"commandToExecute":"./install_guacamole.sh"}'

# # Scan and remove vulnerabilities
# az vm extension set \
#     --resource-group $RESOURCE_GROUP \
#     --vm-name $VM_NAME \
#     --name customScript \
#     --publisher Microsoft.Azure.Extensions \
#     --settings '{"fileUris":["https://example.com/scripts/scan_vulnerabilities.sh"],"commandToExecute":"./scan_vulnerabilities.sh"}'


   # Create a VM and keyvault with RBAC control in azure AD and set permissions to allow to VM to access secrets from the KeyVault with a managaged identiy requiring no addtional login.
# Create a managed identity
az identity create --name myIdentity --resource-group $RESOURCE_GROUP

# Assign the managed identity to the VM
IDENTITY_ID=$(az identity show --name myIdentity --resource-group $RESOURCE_GROUP --query 'id' -o tsv)
az vm identity assign --resource-group $RESOURCE_GROUP --name $VM_NAME --identities $IDENTITY_ID

# Set Key Vault policy to allow the VM to access secrets
VM_PRINCIPAL_ID=$(az vm show --resource-group $RESOURCE_GROUP --name $VM_NAME --query 'identity.principalId' -o tsv)
az role assignment create --role "Key Vault Secrets User" --assignee $VM_PRINCIPAL_ID --scope /subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.KeyVault/vaults/$KEYVAULT_NAME
IDENTITY_OBJECT_ID=$(az identity show --name myIdentity --resource-group $RESOURCE_GROUP --query 'principalId' -o tsv)
az role assignment create --role "Key Vault Secrets User" --assignee-object-id $IDENTITY_OBJECT_ID --assignee-principal-type ServicePrincipal --scope /subscriptions/$(az account show --query id -o tsv)/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.KeyVault/vaults/$KEYVAULT_NAME