#!/bin/bash
git commit -a -m "Added Updates"
git push
az account show
az account set --subscription JacobAzure
az group create --name RG-JacobAzureVMs --location "West US"
az group deployment create \
    --name LinuxVM \
    --resource-group RG-JacobAzureVMs \
    --template-file azuredeployjc.json \
    --parameters @azuredeploy.parameters.json
