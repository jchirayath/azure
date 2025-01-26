#!/bin/bash

# Take a local OS ubuntu snapshot
echo "## Installing timeshift and taking initial setup snapshot"

# Update package list and install timeshift
sudo apt-get update
sudo apt-get install -y timeshift

# Create an initial setup snapshot with timeshift
sudo timeshift --create --comments "Initial setup snapshot" --tags D

# Check if the snapshot was created successfully
if [ $? -eq 0 ]; then
    echo "Snapshot created successfully"
else
    echo "Failed to create snapshot"
    exit 1
fi

# Exit the script
exit 0
