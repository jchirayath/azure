#!/bin/bash
# Commit Code to GitHub
git commit -a -m "Creating AXA"
git push

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

# Create azure resource group called rg-VMs-westus3 if it does not exist
if ! az group show --name $VM_RESOURCE_GROUP-$VM_REGION &>/dev/null; then
    az group create --name $VM_RESOURCE_GROUP-$VM_REGION --location $VM_REGION
fi
# Exit if any command fails
set -e


# Check if the DNS name is available
if ! az network public-ip show --resource-group DefaultResourceGroup-WUS --name ${VM_HOSTNAME}-ip &>/dev/null; then
    az network public-ip create --resource-group DefaultResourceGroup-WUS --name ${VM_HOSTNAME}-ip --dns-name ${DNS_HOSTNAME}
fi
# Exit if any command fails
set -e

# Create a network security group
az network nsg create --resource-group $VM_RESOURCE_GROUP-$VM_REGION --name ${VM_HOSTNAME}-nsg

# Create network security group rules
az network nsg rule create --resource-group $VM_RESOURCE_GROUP-$VM_REGION --nsg-name ${VM_HOSTNAME}-nsg --name AllowSSH --protocol tcp --priority 1000 --destination-port-range 22 --access allow
az network nsg rule create --resource-group $VM_RESOURCE_GROUP-$VM_REGION --nsg-name ${VM_HOSTNAME}-nsg --name AllowHTTP --protocol tcp --priority 1010 --destination-port-range 80 --access allow
az network nsg rule create --resource-group $VM_RESOURCE_GROUP-$VM_REGION --nsg-name ${VM_HOSTNAME}-nsg --name AllowHTTPS --protocol tcp --priority 1020 --destination-port-range 443 --access allow
az network nsg rule create --resource-group $VM_RESOURCE_GROUP-$VM_REGION --nsg-name ${VM_HOSTNAME}-nsg --name Allow8080 --protocol tcp --priority 1030 --destination-port-range 8080 --access allow

# Associate the network security group with the VM's network interface
NIC_ID=$(az vm show --resource-group $VM_RESOURCE_GROUP-$VM_REGION --name $DNS_HOSTNAME --query 'networkProfile.networkInterfaces[0].id' -o tsv)
az network nic update --ids $NIC_ID --network-security-group ${VM_HOSTNAME}-nsg

# Create the VM
az vm create \
    --resource-group rg-VMs-westus3 \
    --name $DNS_HOSTNAME \
    --image $VM_OS   \
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
    --os-disk-name  ${VM_HOSTNAME}-osdisk \
    --os-disk-size-gb $VM_DISK_SIZE \
    --vnet-name ${VM_HOSTNAME}-vnet \
    --ssh-key-value /path/to/your/azure_id.pub
# Exit if any command fails
set -e

# # Add a custom script extension to the VM to run an install script
# az vm extension set \
#     --resource-group DefaultResourceGroup-WUS \
#     --vm-name axa \
#     --name customScript \
#     --publisher Microsoft.Azure.Extensions \
#     --settings '{"fileUris": ["https://raw.githubusercontent.com/jchirayath/azure/master/azure/AxaCreate/install_script.sh"], "commandToExecute": "./install_script.sh"}'

# # Add Azure CLI extension to the VM
# az vm extension set \
#     --resource-group DefaultResourceGroup-WUS \
#     --vm-name axa \
#     --name AzureCli \
#     --publisher Microsoft.Azure.Extensions \
#     --settings '{}'

# # Add Azure SSH extension to the VM
# az vm extension set \
#     --resource-group DefaultResourceGroup-WUS \
#     --vm-name axa \
#     --name VMAccessForLinux \
#     --publisher Microsoft.OSTCExtensions \
#     --settings '{}'