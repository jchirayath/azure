#!/bin/bash
# Function to install Nginx
function install_nginx() {
    echo "Installing Nginx..."
    sudo apt-get install nginx -y
}
install_nginx
