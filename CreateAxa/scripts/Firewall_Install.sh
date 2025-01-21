#!/bin/bash
# Function to set up firewall
function setup_firewall() {
    echo "Setting up firewall..."
    sudo ufw allow OpenSSH
    sudo ufw enable
}
setup_firewall
