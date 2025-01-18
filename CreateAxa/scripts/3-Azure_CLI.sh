#!/bin/bash
# Function to install Azure CLI
function install_azure_cli() {
    echo "Installing Azure CLI..."
    curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
}
install_azure_cli
