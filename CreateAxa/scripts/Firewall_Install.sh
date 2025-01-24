#!/bin/bash

# Function to set up firewall
function setup_firewall() {

    # Register application with UFW
    echo "Setting up firewall..."
    sudo ufw allow OpenSSH
    sudo ufw allow "Apache Full"
    # Allow the following ports
    sudo ufw allow 3306/tcp  # MySQL
    sudo ufw allow 25/tcp    # Postfix
    sudo ufw allow 587/tcp   # Postfix
    sudo ufw allow 465/tcp   # Postfix
    sudo ufw allow 143/tcp   # IMAP
    sudo ufw allow 993/tcp   # IMAPS
    sudo ufw allow 80/tcp    # HTTP
    sudo ufw allow 443/tcp   # HTTPS
    sudo ufw allow 8080/tcp  # Tomcat
    sudo ufw allow 8118/tcp  # Privoxy
    sudo ufw allow 8080/tcp  # Tomcat
    sudo ufw allow 8118/tcp  # Privoxy

    # Enable UFW
    echo "Enabling firewall..."
    sudo ufw enable
}

# Call the function
echo "## Setting up firewall"
setup_firewall
# Check for errors
if [ $? -ne 0 ]; then
    echo "Error: Failed to set up firewall"
    exit 1
else
    echo "## Setting up firewall - Done"
fi

# Exit the script
echo "## Firewall setup complete"
exit 0
