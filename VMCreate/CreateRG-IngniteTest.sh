#!/bin/bash
git commit -a -m "Added Updates"
git push
az account show
az account set --subscription "Master Lighthouse MS Alliance Subscription(Converted to EA)"
az group create --name RG-IgniteTest --location "West US"
az group deployment create \
    --name LinuxVM \
    --resource-group RG-IgniteTest \
    --template-file azuredeployjc.json \
    --parameters @RG-IgniteTest.parameters.json
