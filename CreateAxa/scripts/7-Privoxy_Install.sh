#!/bin/bash
# Function to install Privoxy
function install_privoxy() {
    echo "Installing Privoxy..."
    sudo apt-get install privoxy -y
}
install_privoxy
