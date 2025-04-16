#!/bin/bash

# Take a local OS ubuntu snapshot
echo "## Installing timeshift and taking initial setup snapshot"

# Update package list to ensure we have the latest package information
echo "Updating package list..."
sudo apt-get update

# Install the timeshift package, which is used for creating system snapshots
echo "Installing timeshift package..."
sudo apt-get install -y timeshift

# Create an initial setup snapshot with timeshift and tag it as a daily snapshot
echo "Creating an initial setup snapshot with timeshift..."
sudo timeshift --create --comments "Initial setup snapshot" --tags D

# Check the exit status of the previous command to determine if the snapshot was created successfully
if [ $? -eq 0 ]; then
    # Print a success message if the snapshot was created without errors
    echo "Snapshot created successfully"
else
    # Print an error message and exit the script with a non-zero status if the snapshot creation failed
    echo "Failed to create snapshot"
    exit 1
fi

# Exit the script with a success status
echo "Exiting script successfully."
exit 0
