#!/bin/bash

# Log in to Azure with identity
echo "## Logging in to Azure with identity"
for i in {1..3}; do
    if az login --identity; then
        echo "Successfully logged in to Azure."
        break
    else
        echo "Failed to log in to Azure. Attempt $i of 3."
        if [ $i -eq 3 ]; then
            echo "Exceeded maximum login attempts. Exiting."
            exit 1
        fi
        sleep 5
    fi
done

# Get the VM region from azure
echo "## Getting the VM region from Azure"
VM_REGION=$(az vm list --query "[].location" -o tsv | head -n 1)

# get vm name from azure
echo "## Getting the VM name from Azure"    
VM_HOST=$(az vm list --query "[].name" -o tsv)

# get vm resource group from azure
echo "## Getting the VM resource group from Azure"
VM_RESOURCE_GROUP=$(az vm list --query "[].resourceGroup" -o tsv)

# Update resolv.conf to include FQDN
# echo "## Setting Fully Qualified Domain Name (FQDN) to $VM_HOST.$VM_REGION.cloudapp.azure.com"
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
