#!/bin/bash
# Function to update packages
function update_packages() {
    echo "Updating packages..."
    sudo apt-get update && sudo apt-get upgrade -y
}

# Function to install necessary software
function install_necessary_software() {
    echo "## Installing necessary software"
    sudo apt-get install -y \
        git \
        curl \
        unzip \
        expect \
        docker.io \
        apache2 \
        php \
        php-mysql \
        mysql-client \
        realmd \
        samba-common \
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