#!/bin/bash
# Function to update packages
function update_packages() {
    echo "Updating packages..."
    sudo apt-get update && sudo apt-get upgrade -y
}
update_packages
