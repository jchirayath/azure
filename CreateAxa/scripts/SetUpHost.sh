#!/bin/bash

# Log in to Azure with identity
echo "## Logging in to Azure with identity"
retry=0
max_retries=3
until az login --identity || [ $retry -eq $max_retries ]; do
    echo "Login attempt $((retry+1)) failed. Retrying..."
    retry=$((retry+1))
    sleep 5
done
if [ $retry -eq $max_retries ]; then
    echo "Failed to log in to Azure after $max_retries attempts."
    exit 1
fi

# Get the VM region from azure
echo "## Getting the VM region from Azure"
VM_REGION=$(az vm list --query "[].location" -o tsv | head -n 1)
if [ -z "$VM_REGION" ]; then
    echo "Failed to get VM region from Azure."
    exit 1
fi

# get vm name from azure
echo "## Getting the VM name from Azure"    
VM_HOST=$(az vm list --query "[].name" -o tsv)
if [ -z "$VM_HOST" ]; then
    echo "Failed to get VM name from Azure."
    exit 1
fi

# get vm resource group from azure
echo "## Getting the VM resource group from Azure"
VM_RESOURCE_GROUP=$(az vm list --query "[].resourceGroup" -o tsv)
if [ -z "$VM_RESOURCE_GROUP" ]; then
    echo "Failed to get VM resource group from Azure."
    exit 1
fi

# Get FQDN
FQDN=$(hostname -f)
# Ensure FQDN is valid and has a domain suffix
if [[ -z "$FQDN" || "$FQDN" == *"localhost"* || "$FQDN" != *.* ]]; then
    echo "Invalid FQDN: $FQDN"
    exit 1
fi

# Set FQDN for the HOST
echo "## Setting Fully Qualified Domain Name (FQDN) to $VM_HOST.$VM_REGION.cloudapp.azure.com"
# if ! echo "$VM_HOST.$VM_REGION.cloudapp.azure.com" | sudo tee /etc/hostname > /dev/null; then
#     echo "Failed to set hostname."
#     exit 1
# fi
# if ! sudo sed -i "s/^127\.0\.1\.1.*/127.0.1.1 $VM_HOST.$VM_REGION.cloudapp.azure.com $VM_HOST/" /etc/hosts; then
#     echo "Failed to update /etc/hosts."
#     exit 1
# fi

# # Update resolv.conf to include FQDN
# echo "## Updating resolv.conf to include FQDN"
# if ! sudo sed -i "s/search.*/search $VM_HOST.$VM_REGION.cloudapp.azure.com/g" /etc/resolv.conf; then
#     echo "Failed to update /etc/resolv.conf."
#     exit 1
# fi

## Set the timezone based on VM Region
echo "## Getting the timezone based on the VM region"
case "$VM_REGION" in
    "eastus" | "eastus2")
        TIMEZONE="America/New_York"
        ;;
    "centralus")
        TIMEZONE="America/Chicago"
        ;;
    "westus" | "westus2")
        TIMEZONE="America/Los_Angeles"
        ;;
    *)
        TIMEZONE="UTC"
        ;;
esac
# Set the TimeZone
echo "## Setting the timezone based on the VM region"
if ! sudo timedatectl set-timezone $TIMEZONE; then
    echo "Failed to set timezone."
    exit 1
fi

## Set the locale to en_US.UTF-8
echo "## Setting the locale to en_US.UTF-8"
if ! sudo locale-gen en_US.UTF-8; then
    echo "Failed to generate locale."
    exit 1
fi
if ! sudo update-locale LANG=en_US.UTF-8; then
    echo "Failed to update locale."
    exit 1
fi

# Store all the variables into a file called hostinfo.txt
echo "FQDN=$FQDN" >> hostinfo.txt
echo "VM_REGION=$VM_REGION" > hostinfo.txt
echo "VM_HOST=$VM_HOST" >> hostinfo.txt
echo "VM_RESOURCE_GROUP=$VM_RESOURCE_GROUP" >> hostinfo.txt
echo "HOSTNAME=$(hostname)" >> hostinfo.txt
echo "DNS_SERVERS=$(grep -E '^nameserver' /etc/resolv.conf | awk '{print $2}' | paste -sd ',' -)" >> hostinfo.txt
echo "RESOLVERS=$(grep -E '^search' /etc/resolv.conf | awk '{$1=""; print $0}' | xargs)" >> hostinfo.txt
echo "MACHINE_ID=$(cat /etc/machine-id)" >> hostinfo.txt
echo "TIMEZONE=$TIMEZONE" >> hostinfo.txt
echo "LOCALE=$(locale | grep LANG | cut -d= -f2)" >> hostinfo.txt

# End of Script
