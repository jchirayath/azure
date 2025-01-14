#!/bin/bash
git commit -a -m "Creating AXA"
git push
az account show
az account set --subscription JacobAzure

# Create azure resource group called rg-VMs-westus3 if it does not exist
if ! az group show --name rg-VMs-westus3 &>/dev/null; then
    az group create --name rg-VMs-westus3 --location "West US 3"
fi

# Create azure VM if it does not exist
# Set DNS hostname
DNS_HOSTNAME="axa"

# Check if the DNS name is available
if ! az network public-ip show --resource-group DefaultResourceGroup-WUS --name ${DNS_HOSTNAME}-ip &>/dev/null; then
    az network public-ip create --resource-group DefaultResourceGroup-WUS --name ${DNS_HOSTNAME}-ip --dns-name ${DNS_HOSTNAME}
fi

# Create the VM
az vm create \
    --resource-group DefaultResourceGroup-WUS \
    --name axa \
    --image Ubuntu2204 \
    --size Standard_D2s_v3 \
    --assign-identity \
    --admin-username azureuser \
    --enable-agent true \
    --enable-auto-update true \
    --public-ip-address ${DNS_HOSTNAME}-ip \
    --ssh-key-value /path/to/your/azure_id.pub

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