#!/bin/bash
git commit -a -m "Added Updates"
git push
az account show
az account set --subscription JacobAzure
az group create --name RG-JacobAzure2VMs --location "West US"
az group deployment create \
    --name LinuxVM \
    --resource-group RG-JacobAzure2VMs \
    --template-file azuredeploy2.json \
    --parameters @azuredeploy2.parameters.json
