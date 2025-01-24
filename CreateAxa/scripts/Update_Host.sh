#!/bin/bash
# Function to update packages
function update_packages() {
    echo "Updating packages..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get update && sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
}

# Function to install necessary software
function install_necessary_software() {
    echo "## Installing necessary software"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        git \
        curl \
        unzip \
        expect \
        docker.io \
        php \
        php-mysql \
        mysql-client \
        nmap \
        rsync \
        screen \
        diffutils \
        lsof \
        tcpdump \
        telnet \
        netcat \
        traceroute \
        wget \
        perl \
        python3 \
        net-tools
}

# Function to install Azure CLI
function install_azure_cli() {
    echo "## Installing Azure CLI"
    curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
}

# Call the functions
echo "## Updating package list and upgrading installed packages"
update_packages
echo "## Updating package list and upgrading installed packages - Done"

echo "## Installing necessary software"
install_necessary_software
echo "## Installing necessary software - Done"

echo "## Installing Azure CLI"
install_azure_cli
echo "## Installing Azure CLI - Done"

# # Log in to Azure with identity
# echo "## Logging in to Azure with identity"
# az login --identity
# # check for errors
# if [ $? -ne 0 ]; then
#     echo "Error: Failed to log in to Azure with identity"
#     exit 1
# else
#     echo "## Logged in to Azure with identity"
# fi
