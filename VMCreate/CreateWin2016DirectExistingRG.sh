#!/bin/bash
git add *
git commit -a -m "Added Updates"
git push
az account show
az group create --name RG-JacobAzure2VMs --location "West US"
az vm create \
--name yumaWin2016 \
--resource-group RG-JacobAzure2VMs \
--image win2016datacenter \
--admin-username myAdmin \
--admin-password Password1234 \
--public-ip-address-dns-name yumawin2016 \
--os-disk-name yumaWin2016_OSDisk
