# Exit if any command fails
set -e

# Import Variables from the variables file
source ./variables.sh

# Check Account and Set Subscription
echo "## Checking Azure account and setting subscription"
az account show
az account set --subscription $AZURE_SUBSCRIPTION

# get user confirmation to delete the resource group
echo "## Deleting the resource group will delete all resources in the resource group."
read -p "## Do you want to delete the resource group $VM_RESOURCE_GROUP? (y/n) " -n 1 -r 
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]
then
    echo "## Exiting without deleting the resource group."
    exit 1
fi

# Delete the resource group
echo "## Deleting Azure resource group"
az group delete --name $VM_RESOURCE_GROUP --yes --no-wait

# echo "## Deleting Azure resource group completed"
# echo "## Exiting the script"
# echo "## Done"
