#!/bin/bash
# Function to install Certbot
function install_certbot() {
    echo "Installing Certbot..."
    sudo apt-get install certbot python3-certbot-nginx -y
}
install_certbot
