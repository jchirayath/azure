#!/bin/bash
git commit -a -m "Added Updates"
git push
az account show
az account set --subscription JacobAzure
az group create --name RG-JacobAzureWindows --location "West US2"
az group deployment create \
    --name WindowsVM \
    --resource-group RG-JacobAzureWindows \
    --template-file azuredeployWin2016.json \
    --parameters @azuredeployWin2016.parameters.json
