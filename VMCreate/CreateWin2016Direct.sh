#!/bin/bash
git add *
git commit -a -m "Added Updates"
git push
az account show
az account set --subscription JacobAzure
az group create --name RG-JacobAzureWindows --location "West US2"
az vm create \
--name yumaWin2016 \
--resource-group RG-JacobAzureWindows \
--image win2016datacenter \
--admin-username myAdmin \
--admin-password Password1234 \
--public-ip-address-dns-name yumawin2016 \
--vnet-name WestUSVNET \
--os-disk-name yumaWin2016_OSDisk 
