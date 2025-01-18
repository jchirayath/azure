#!/bin/bash
# Function to install Lynis
function install_lynis() {
    echo "Installing Lynis..."
    sudo apt-get install lynis -y
}
install_lynis
