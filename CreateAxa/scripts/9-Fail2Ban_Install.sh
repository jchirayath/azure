#!/bin/bash
# Function to install Fail2Ban
function install_fail2ban() {
    echo "Installing Fail2Ban..."
    sudo apt-get install fail2ban -y
}
install_fail2ban
