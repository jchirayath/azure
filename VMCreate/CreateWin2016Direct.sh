#!/bin/bash
git add *
git commit -a -m "Added Updates"
git push
az account show
az account set --subscription JacobAzure
az group create --name RG-JacobAzureWindows --location "West US2"

az vm create --resource-group myResourceGroup --name myVM --image win2016datacenter --admin-username azureuser --admin-password myPassword12

azure vm create myVM \
-o MicrosoftWindowsServer:WindowsServer:2016-Datacenter:latest \
-g Admin \
-p Admin123 \
-e 22 \
-t "~/.ssh/id_rsa.pub" \
-z "Small" \
-l "West US"
US6808651-M001:azure jchirayath$ azure vm create
-bash: azure: command not found
US6808651-M001:azure jchirayath$ az vm create
az vm create: error: the following arguments are required: --name/-n, --resource-group/-g
usage: az vm create [-h] [--output {json,tsv,table,jsonc}] [--verbose]
                    [--debug] [--query JMESPATH] --name NAME --resource-group
                    RESOURCE_GROUP_NAME [--image IMAGE] [--size SIZE]
                    [--location LOCATION] [--tags [TAGS [TAGS ...]]]
                    [--no-wait] [--authentication-type {ssh,password}]
                    [--admin-password ADMIN_PASSWORD]
                    [--admin-username ADMIN_USERNAME]
                    [--ssh-dest-key-path SSH_DEST_KEY_PATH]
                    [--ssh-key-value SSH_KEY_VALUE] [--generate-ssh-keys]
                    [--availability-set AVAILABILITY_SET]
                    [--nics NICS [NICS ...]] [--nsg NSG]
                    [--nsg-rule {RDP,SSH}]
                    [--private-ip-address PRIVATE_IP_ADDRESS]
                    [--public-ip-address PUBLIC_IP_ADDRESS]
                    [--public-ip-address-allocation {dynamic,static}]
                    [--public-ip-address-dns-name PUBLIC_IP_ADDRESS_DNS_NAME]
                    [--os-disk-name OS_DISK_NAME] [--os-type {windows,linux}]
                    [--storage-account STORAGE_ACCOUNT]
                    [--storage-caching {ReadOnly,ReadWrite}]
                    [--data-disk-caching {None,ReadOnly,ReadWrite}]
                    [--storage-container-name STORAGE_CONTAINER_NAME]
                    [--storage-sku {Standard_LRS,Standard_GRS,Standard_RAGRS,Standard_ZRS,Premium_LRS}]
                    [--use-unmanaged-disk] [--attach-os-disk ATTACH_OS_DISK]
                    [--os-disk-size-gb OS_DISK_SIZE_GB]
                    [--attach-data-disks ATTACH_DATA_DISKS [ATTACH_DATA_DISKS ...]]
                    [--data-disk-sizes-gb DATA_DISK_SIZES_GB [DATA_DISK_SIZES_GB ...]]
                    [--vnet-name VNET_NAME]
                    [--vnet-address-prefix VNET_ADDRESS_PREFIX]
                    [--subnet SUBNET]
                    [--subnet-address-prefix SUBNET_ADDRESS_PREFIX]
                    [--validate] [--custom-data CUSTOM_DATA]
                    [--secrets SECRETS [SECRETS ...]] [--plan-name PLAN_NAME]
                    [--plan-product PLAN_PRODUCT]
                    [--plan-publisher PLAN_PUBLISHER]
                    [--plan-promotion-code PLAN_PROMOTION_CODE]
                    [--license-type {Windows_Server,Windows_Client}]
                    [--assign-identity] [--scope IDENTITY_SCOPE]
                    [--role IDENTITY_ROLE]
                    [--asgs APPLICATION_SECURITY_GROUPS [APPLICATION_SECURITY_GROUPS ...]]
                    [--zone {1,2,3}]

