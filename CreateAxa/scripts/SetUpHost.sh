#!/bin/bash

# Log in to Azure with identity
echo "## Logging in to Azure with identity"
sudo az login --identity

# Get the VM region from azure
echo "## Getting the VM region from Azure"
VM_REGION=$(sudo az vm list --query "[].location" -o tsv | head -n 1)

# get vm name from azure
echo "## Getting the VM name from Azure"    
VM_HOST=$(sudo az vm list --query "[].name" -o tsv)

# get vm resource group from azure
echo "## Getting the VM resource group from Azure"
VM_RESOURCE_GROUP=$(sudo az vm list --query "[].resourceGroup" -o tsv)

# Update resolv.conf to include FQDN
echo "## Setting Fully Qualified Domain Name (FQDN) to $VM_HOST.$VM_REGION.cloudapp.azure.com"
echo "$VM_HOST.$VM_REGION.cloudapp.azure.com" | sudo tee /etc/hostname
echo "127.0.1.1 $VM_HOST.$VM_REGION.cloudapp.azure.com $VM_HOST" | sudo tee -a /etc/hosts

# Update resolv.conf to include FQDN
echo "## Updating resolv.conf to include FQDN"
sudo sed -i "s/search.*/search $VM_HOST.$VM_REGION.cloudapp.azure.com/g" /etc/resolv.conf

## Set the timezone to California
echo "## Setting the timezone to California"
sudo timedatectl set-timezone America/Los_Angeles

## Set the locale to en_US.UTF-8
echo "## Setting the locale to en_US.UTF-8"
sudo locale-gen en_US.UTF-8
sudo update-locale LANG=en_US.UTF-8

# # Intitiating a reboot of the VM post package upgrade
# echo "Initiating Reboot of Server"
# sudo reboot
