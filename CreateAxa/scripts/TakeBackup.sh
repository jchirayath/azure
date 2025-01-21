#!/bin/bash

# Take a snapshot of the VM called "Initial setup snapshot"
echo "## Taking a snapshot of the VM called 'Initial setup snapshot'"
az vm run-command invoke --resource-group $VM_RESOURCE_GROUP --name $VM_HOSTNAME --command-id RunShellScript --scripts "sudo apt-get install -y timeshift; sudo timeshift --create --comments 'Initial setup snapshot' --tags D"

# Take a snapshot of the VM using the Azure CLI
# echo "## Taking a snapshot of the VM using the Azure CLI using the lastest version of azure cli"
az snapshot create --resource-group $VM_RESOURCE_GROUP --source $(az vm show --resource-group $VM_RESOURCE_GROUP --name $VM_HOSTNAME --query "storageProfile.osDisk.managedDisk.id" -o tsv) --name "InitialSetupSnapshot"

# Use the Azure CLI to restore the snapshot
# echo "## Restoring the snapshot of the VM using the Azure CLI"
SNAPSHOT_ID=$(az snapshot show --resource-group $VM_RESOURCE_GROUP --name "InitialSetupSnapshot" --query "id" -o tsv)
DISK_ID=$(az disk create --resource-group $VM_RESOURCE_GROUP --name ${VM_HOSTNAME}-osdisk-restored --source $SNAPSHOT_ID --query "id" -o tsv)
az vm create --resource-group $VM_RESOURCE_GROUP --name ${VM_HOSTNAME}-restored --attach-os-disk $DISK_ID --os-type Linux --name ${VM_HOSTNAME}-restored

# Create a azure restore collection point
echo "## Creating an Azure restore collection point"
az restore-point collection create --resource-group $VM_RESOURCE_GROUP --collection-name ${VM_HOSTNAME}-rpc
# Create a azure restore point
echo "## Creating an Azure restore point"
az restore-point create --resource-group $VM_RESOURCE_GROUP --restore-point-collection-name ${VM_HOSTNAME}-rpc --restore-point-name InitialRestorePoint --source-id $(az vm show --resource-group $VM_RESOURCE_GROUP --name $VM_HOSTNAME --query "id" -o tsv) --collection-name ${VM_HOSTNAME}-rpc

