az account show
az account set --subscription JacobAzure
az group create --name RG-JacobAzure2VMs --location "West US"
az group deployment create \
    --name LinuxVM \
    --resource-group RG-JacobAzureVMs \
    --template-file azuredeploy2.json \
    --parameters @azuredeploy2.parameters.json
