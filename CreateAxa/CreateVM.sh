#!/bin/bash
# Exit if any command fails
set -e

# Commit Code to GitHub
# echo "Committing code to GitHub"
# git commit -a -m "Creating AXA"
# git push
# Import Variables from the variables file
echo "## Importing variables from the variables file"
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
echo "## Resource group $VM_RESOURCE_GROUP created"

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
    az network nsg rule create --resource-group $VM_RESOURCE_GROUP --nsg-name ${VM_HOSTNAME}-nsg --name Guacamole --protocol tcp --priority 1030 --destination-port-range 8080 --access allow
    az network nsg rule create --resource-group $VM_RESOURCE_GROUP --nsg-name ${VM_HOSTNAME}-nsg --name Allow8443 --protocol tcp --priority 1040 --destination-port-range 8443  --access allow
    az network nsg rule create --resource-group $VM_RESOURCE_GROUP --nsg-name ${VM_HOSTNAME}-nsg --name Privoxy --protocol tcp --priority 1050 --destination-port-range 8118 --access allow
    az network nsg rule create --resource-group $VM_RESOURCE_GROUP --nsg-name ${VM_HOSTNAME}-nsg --name Webmin --protocol tcp --priority 1060 --destination-port-range 1000 --access allow
    az network nsg rule create --resource-group $VM_RESOURCE_GROUP --nsg-name ${VM_HOSTNAME}-nsg --name ELKStack --protocol tcp --priority 1070 --destination-port-ranges 5601 9090 3000 --access allow
    az network nsg rule create --resource-group $VM_RESOURCE_GROUP --nsg-name ${VM_HOSTNAME}-nsg --name Portainer --protocol tcp --priority 1080 --destination-port-range 8081 --access allow
    az network nsg rule create --resource-group $VM_RESOURCE_GROUP --nsg-name ${VM_HOSTNAME}-nsg --name phpAdmin --protocol tcp --priority 1090 --destination-port-range 8084 --access allow
    az network nsg rule create --resource-group $VM_RESOURCE_GROUP --nsg-name ${VM_HOSTNAME}-nsg --name Mail --protocol tcp --priority 1100 --destination-port-ranges 25 587 465 143 993 --access allow
    az network nsg rule create --resource-group $VM_RESOURCE_GROUP --nsg-name ${VM_HOSTNAME}-nsg --name Knockd --protocol tcp --priority 1110 --destination-port-ranges 7000 8000 9000 --access allow
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

    echo "## Adding CustomScript extension to the VM -  Update_Host.sh"
    az vm extension set \
        --resource-group $VM_RESOURCE_GROUP \
        --vm-name $VM_HOSTNAME \
        --name CustomScript \
        --publisher Microsoft.Azure.Extensions \
        --settings '{"fileUris":["https://raw.githubusercontent.com/jchirayath/azure/master/CreateAxa/scripts/Update_Host.sh"],"commandToExecute":"./Update_Host.sh"}'
else
    echo "## VM $VM_HOSTNAME already exists."
fi

# Proceed only if the VM and CustomScript extension are completed
echo "## Waiting for the VM and CustomScript extension to complete"
az vm wait --resource-group $VM_RESOURCE_GROUP --name $VM_HOSTNAME --created
az vm wait --resource-group $VM_RESOURCE_GROUP --name $VM_HOSTNAME --updated

# Get the public IP address of the VM
echo "## Getting the public IP address of the VM"
VM_IP=$(az vm show --resource-group $VM_RESOURCE_GROUP --name $VM_HOSTNAME --show-details --query publicIps -o tsv)
echo "## Public IP address of the VM is $VM_IP"

# Get the DNS name of the VM
echo "## Getting the DNS name of the VM"
VM_DNS=$(az network public-ip show --resource-group $VM_RESOURCE_GROUP --name ${VM_HOSTNAME}-ip --query dnsSettings.fqdn -o tsv)
echo "## DNS name of the VM is $VM_DNS"

# Check if the Key Vault exists
KEYVAULT_NAME="kv-$VM_HOSTNAME-$VM_REGION"
echo "## Checking if Key Vault exists"
if ! az keyvault show --name $KEYVAULT_NAME --resource-group $VM_RESOURCE_GROUP &>/dev/null; then
    # Create a Key Vault
    echo "## Creating a Key Vault"
    az keyvault create --name $KEYVAULT_NAME --resource-group $VM_RESOURCE_GROUP --location $VM_REGION

    # Allow Azure admins to add secrets
    echo "## Allowing Azure admins to add secrets"
    ADMIN_GROUP_ID=$(az ad group show --group "$KEY_VAULT_ADMINS" --query id -o tsv)
    az role assignment create --role "Key Vault Administrator" --assignee $ADMIN_GROUP_ID --scope /subscriptions/$(az account show --query id -o tsv)/resourceGroups/$VM_RESOURCE_GROUP/providers/Microsoft.KeyVault/vaults/$KEYVAULT_NAME

    # wait for the role assignment to propagate
    echo "## Waiting for role assignment to propagate"
    sleep 15

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
if ! az identity show --name $VM_HOSTNAME-Identity --resource-group $VM_RESOURCE_GROUP &>/dev/null; then
    echo "## Creating a managed identity for the VM"
    az identity create --name $VM_HOSTNAME-Identity --resource-group $VM_RESOURCE_GROUP

    echo "## Assigning the managed identity to the VM"
    IDENTITY_ID=$(az identity show --name $VM_HOSTNAME-Identity --resource-group $VM_RESOURCE_GROUP --query 'id' -o tsv)
    az vm identity assign --resource-group $VM_RESOURCE_GROUP --name $VM_HOSTNAME --identities $IDENTITY_ID

    echo "## Setting Key Vault policy to allow the VM to access secrets"
    VM_PRINCIPAL_ID=$(az vm show --resource-group $VM_RESOURCE_GROUP --name $VM_HOSTNAME --query 'identity.principalId' -o tsv)
    az role assignment create --role "Key Vault Secrets User" --assignee $VM_PRINCIPAL_ID --scope /subscriptions/$(az account show --query id -o tsv)/resourceGroups/$VM_RESOURCE_GROUP/providers/Microsoft.KeyVault/vaults/$KEYVAULT_NAME
    
    ## Access rules for th VM Managed Identity
    echo "## Getting the object ID of the managed identity"
    IDENTITY_OBJECT_ID=$(az identity show --name $VM_HOSTNAME-Identity --resource-group $VM_RESOURCE_GROUP --query 'principalId' -o tsv)

    echo "## Setting Machine Identity Role access to allow the VM to access KeyVault (Key Vault Reader) via the machine identity"
    az role assignment create --role "Key Vault Reader" --assignee $VM_PRINCIPAL_ID --scope /subscriptions/$(az account show --query id -o tsv)/resourceGroups/$VM_RESOURCE_GROUP/providers/Microsoft.KeyVault/vaults/$KEYVAULT_NAME
  
    echo "## Setting Machine Identity Role access to allow the VM to access secrets (Key Vault Secrets Use) via the machine identity"
    az role assignment create --role "Key Vault Secrets User" --assignee-object-id $IDENTITY_OBJECT_ID --assignee-principal-type ServicePrincipal --scope /subscriptions/$(az account show --query id -o tsv)/resourceGroups/$VM_RESOURCE_GROUP/providers/Microsoft.KeyVault/vaults/$KEYVAULT_NAME
      
    echo "## Allow the VM to acccess azure configure commands via the machine identity"
    az role assignment create --role "Virtual Machine Contributor" --assignee $VM_PRINCIPAL_ID --scope /subscriptions/$(az account show --query id -o tsv)/resourceGroups/$VM_RESOURCE_GROUP/providers/Microsoft.Compute/virtualMachines/$VM_HOSTNAME
else
    echo "## Managed identity for the VM already exists."
fi

# Output logs for CustomScript extension
#  stored in /var/lib/waagent/custom-script/download/0/

# Install VM extension AADLoginForLinux
echo "## Installing VM extension AADLoginForLinux"
az vm extension set \
    --resource-group ${VM_RESOURCE_GROUP} \
    --vm-name $VM_HOSTNAME \
    --name AADSSHLoginForLinux \
    --publisher Microsoft.Azure.ActiveDirectory \
    --settings '{}'
echo "## VM extension AADLoginForLinux installed"

# Proceed only if the VM and AADLoginForLinux extension are completed
echo "## Waiting for the VM and AADLoginForLinux extension to complete"
az vm wait --resource-group $VM_RESOURCE_GROUP --name $VM_HOSTNAME --created
az vm extension wait --resource-group $VM_RESOURCE_GROUP --vm-name $VM_HOSTNAME --name AADSSHLoginForLinux --created

# Install and run SetupHost.sh on the VM
if [ $SCRIPT_SETUP_HOST = "TRUE" ]; then
    echo "## Installing and Running SetUpHost.sh"
    az vm extension set \
        --resource-group ${VM_RESOURCE_GROUP} \
        --vm-name $VM_HOSTNAME \
        --name CustomScript \
        --publisher Microsoft.Azure.Extensions \
        --settings '{"fileUris":["https://raw.githubusercontent.com/jchirayath/azure/master/CreateAxa/scripts/SetUpHost.sh"],"commandToExecute":"./SetUpHost.sh"}'

    echo "## Waiting for SetUpHost.sh to complete"
    az vm wait --resource-group $VM_RESOURCE_GROUP --name $VM_HOSTNAME --created
    az vm extension wait --resource-group $VM_RESOURCE_GROUP --vm-name $VM_HOSTNAME --name CustomScript --created
    echo "## SetUpHost.sh completed"
else
    echo "## Skipping SetUpHost.sh"
fi

# reboot the VM via Azure CLI
echo "## Rebooting the VM"
az vm restart --resource-group $VM_RESOURCE_GROUP --name $VM_HOSTNAME

# Wait for the VM to reboot
echo "## Waiting for the VM to reboot"
az vm wait --resource-group $VM_RESOURCE_GROUP --name $VM_HOSTNAME --updated

# Install and run FirewallInstall.sh on the VM
if [ $SCRIPT_FIREWALL_INSTALL = "TRUE" ]; then
    echo "## Installing FirewallInstall.sh"
    az vm extension set \
        --resource-group ${VM_RESOURCE_GROUP} \
        --vm-name $VM_HOSTNAME \
        --name CustomScript \
        --publisher Microsoft.Azure.Extensions \
        --settings '{"fileUris":["https://raw.githubusercontent.com/jchirayath/azure/master/CreateAxa/scripts/Firewall_Install.sh"],"commandToExecute":"./Firewall_Install.sh"}'

    echo "## Waiting for FirewallInstall.sh to complete"
    az vm wait --resource-group $VM_RESOURCE_GROUP --name $VM_HOSTNAME --created
    az vm extension wait --resource-group $VM_RESOURCE_GROUP --vm-name $VM_HOSTNAME --name CustomScript --created
    echo "## FirewallInstall.sh completed"
else
    echo "## Skipping FirewallInstall.sh"
fi

# Install and run Fail2Ban_Install.sh on the VM
if [ $SCRIPT_FAIL2BAN_INSTALL = "TRUE" ]; then
    echo "## Installing Fail2Ban_Install.sh"
    az vm extension set \
        --resource-group ${VM_RESOURCE_GROUP} \
        --vm-name $VM_HOSTNAME \
        --name CustomScript \
        --publisher Microsoft.Azure.Extensions \
        --settings '{"fileUris":["https://raw.githubusercontent.com/jchirayath/azure/master/CreateAxa/scripts/Fail2Ban_Install.sh"],"commandToExecute":"./Fail2Ban_Install.sh"}'

    echo "## Waiting for Fail2Ban_Install.sh to complete"
    az vm wait --resource-group $VM_RESOURCE_GROUP --name $VM_HOSTNAME --created
    az vm extension wait --resource-group $VM_RESOURCE_GROUP --vm-name $VM_HOSTNAME --name CustomScript --created
    echo "## Fail2Ban_Install.sh completed"
else
    echo "## Skipping Fail2Ban_Install.sh"
fi

# Install and run MailSetup.sh on the VM
if [ $SCRIPT_MAIL_SETUP = "TRUE" ]; then
    echo "## Installing MailSetup.sh"
    az vm extension set \
        --resource-group ${VM_RESOURCE_GROUP} \
        --vm-name $VM_HOSTNAME \
        --name CustomScript \
        --publisher Microsoft.Azure.Extensions \
        --settings '{"fileUris":["https://raw.githubusercontent.com/jchirayath/azure/master/CreateAxa/scripts/Mail_Setup.sh"],"commandToExecute":"./Mail_Setup.sh"}'

    echo "## Waiting for MailSetup.sh to complete"
    az vm wait --resource-group $VM_RESOURCE_GROUP --name $VM_HOSTNAME --created
    az vm extension wait --resource-group $VM_RESOURCE_GROUP --vm-name $VM_HOSTNAME --name CustomScript --created
    echo "## MailSetup.sh completed"
else
    echo "## Skipping MailSetup.sh"
fi

# Install and run GuacInstall.sh on the VM
if [ $SCRIPT_GUAC_INSTALL = "TRUE" ]; then
    echo "## Installing GuacInstall.sh"
    az vm extension set \
        --resource-group ${VM_RESOURCE_GROUP} \
        --vm-name $VM_HOSTNAME \
        --name CustomScript \
        --publisher Microsoft.Azure.Extensions \
        --settings '{"fileUris":["https://raw.githubusercontent.com/jchirayath/azure/master/CreateAxa/scripts/Guac_Install.sh"],"commandToExecute":"./Guac_Install.sh"}'

    echo "## Waiting for GuacInstall.sh to complete"
    az vm wait --resource-group $VM_RESOURCE_GROUP --name $VM_HOSTNAME --created
    az vm extension wait --resource-group $VM_RESOURCE_GROUP --vm-name $VM_HOSTNAME --name CustomScript --created
    echo "## GuacInstall.sh completed"
else
    echo "## Skipping GuacInstall.sh"
fi

# Install and run NginxInstall.sh on the VM
if [ $SCRIPT_NGINX_INSTALL = "TRUE" ]; then
    echo "## Installing NginxInstall.sh"
    az vm extension set \
        --resource-group ${VM_RESOURCE_GROUP} \
        --vm-name $VM_HOSTNAME \
        --name CustomScript \
        --publisher Microsoft.Azure.Extensions \
        --settings '{"fileUris":["https://raw.githubusercontent.com/jchirayath/azure/master/CreateAxa/scripts/Nginx_Install.sh"],"commandToExecute":"./Nginx_Install.sh"}'

    echo "## Waiting for NginxInstall.sh to complete"
    az vm wait --resource-group $VM_RESOURCE_GROUP --name $VM_HOSTNAME --created
    az vm extension wait --resource-group $VM_RESOURCE_GROUP --vm-name $VM_HOSTNAME --name CustomScript --created
    echo "## NginxInstall.sh completed"
else
    echo "## Skipping NginxInstall.sh"
fi

# Install and run PrivoxyInstall.sh on the VM
if [ $SCRIPT_PRIVOXY_INSTALL = "TRUE" ]; then
    echo "## Installing PrivoxyInstall.sh"
    az vm extension set \
        --resource-group ${VM_RESOURCE_GROUP} \
        --vm-name $VM_HOSTNAME \
        --name CustomScript \
        --publisher Microsoft.Azure.Extensions \
        --settings '{"fileUris":["https://raw.githubusercontent.com/jchirayath/azure/master/CreateAxa/scripts/Privoxy_Install.sh"],"commandToExecute":"./Privoxy_Install.sh"}'

    echo "## Waiting for PrivoxyInstall.sh to complete"
    az vm wait --resource-group $VM_RESOURCE_GROUP --name $VM_HOSTNAME --created
    az vm extension wait --resource-group $VM_RESOURCE_GROUP --vm-name $VM_HOSTNAME --name CustomScript --created
    echo "## PrivoxyInstall.sh completed"
else
    echo "## Skipping PrivoxyInstall.sh"
fi

# Install and run MySQLInstall.sh on the VM
if [ $SCRIPT_MYSQL_INSTALL = "TRUE" ]; then
    echo "## Installing MySQLInstall.sh"
    az vm extension set \
        --resource-group ${VM_RESOURCE_GROUP} \
        --vm-name $VM_HOSTNAME \
        --name CustomScript \
        --publisher Microsoft.Azure.Extensions \
        --settings '{"fileUris":["https://raw.githubusercontent.com/jchirayath/azure/master/CreateAxa/scripts/MySQL_Install.sh"],"commandToExecute":"./MySQL_Install.sh"}'

    echo "## Waiting for MySQLInstall.sh to complete"
    az vm wait --resource-group $VM_RESOURCE_GROUP --name $VM_HOSTNAME --created
    az vm extension wait --resource-group $VM_RESOURCE_GROUP --vm-name $VM_HOSTNAME --name CustomScript --created
    echo "## MySQLInstall.sh completed"
else
    echo "## Skipping MySQLInstall.sh"
fi

# Install and run LynisInstall.sh on the VM
if [ $SCRIPT_LYNIS_INSTALL = "TRUE" ]; then
    echo "## Installing LynisInstall.sh"
    az vm extension set \
        --resource-group ${VM_RESOURCE_GROUP} \
        --vm-name $VM_HOSTNAME \
        --name CustomScript \
        --publisher Microsoft.Azure.Extensions \
        --settings '{"fileUris":["https://raw.githubusercontent.com/jchirayath/azure/master/CreateAxa/scripts/Lynis_Install.sh"],"commandToExecute":"./Lynis_Install.sh"}'

    echo "## Waiting for LynisInstall.sh to complete"
    az vm wait --resource-group $VM_RESOURCE_GROUP --name $VM_HOSTNAME --created
    az vm extension wait --resource-group $VM_RESOURCE_GROUP --vm-name $VM_HOSTNAME --name CustomScript --created
    echo "## LynisInstall.sh completed"
else
    echo "## Skipping LynisInstall.sh"
fi

# Install and run Take_Backup.sh on the VM
if [ $SCRIPT_TAKE_BACKUP = "TRUE" ]; then
    echo "## Installing Take_Backup.sh"
    az vm extension set \
        --resource-group ${VM_RESOURCE_GROUP} \
        --vm-name $VM_HOSTNAME \
        --name CustomScript \
        --publisher Microsoft.Azure.Extensions \
        --settings '{"fileUris":["https://raw.githubusercontent.com/jchirayath/azure/master/CreateAxa/scripts/Take_Backup.sh"],"commandToExecute":"./Take_Backup.sh"}'

    echo "## Waiting for TakeBackup.sh to complete"
    az vm wait --resource-group $VM_RESOURCE_GROUP --name $VM_HOSTNAME --created
    az vm extension wait --resource-group $VM_RESOURCE_GROUP --vm-name $VM_HOSTNAME --name CustomScript --created
    echo "## TakeBackup.sh completed"
else
    echo "## Skipping TakeBackup.sh"
fi

# Display all the resources created
echo "#####################"
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
echo "## Managed Identity: $VM_HOSTNAME-Identity"
echo "## Identity ID: $(az identity show --name $VM_HOSTNAME-Identity --resource-group $VM_RESOURCE_GROUP --query 'id' -o tsv)"
echo "## Identity Object ID: $(az identity show --name $VM_HOSTNAME-Identity --resource-group $VM_RESOURCE_GROUP --query 'principalId' -o tsv)"
echo "#####################"

# end of script
echo "## End of script"
echo "## The script has completed successfully."
echo "## Please check the output for any errors."
echo "## Exiting..."