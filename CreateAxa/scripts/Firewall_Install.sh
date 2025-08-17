#!/bin/bash

# Register SSH application with UFW
echo "Setting up firewall..."
sudo ufw allow OpenSSH
if [ $? -ne 0 ]; then
    echo "Error: Failed to allow OpenSSH"
    exit 1
fi

# Allow Apache Full
echo "Allowing Apache Full..."
sudo ufw allow "Apache Full"
if [ $? -ne 0 ]; then
    echo "Error: Failed to allow Apache Full"
    exit 1
fi

# # Allow the following ports
# # 3306 - MySQL
# echo "Allowing port 3306/tcp..."
# if ! sudo ufw allow 3306/tcp; then
#     echo "Error: Failed to allow port 3306/tcp"
#     exit 1
# fi

# 25 - SMTP
echo "Allowing port 25/tcp..."
if ! sudo ufw allow 25/tcp; then
    echo "Error: Failed to allow port 25/tcp"
    exit 1
fi

# 587 - SMTP
echo "Allowing port 587/tcp..."
if ! sudo ufw allow 587/tcp; then
    echo "Error: Failed to allow port 587/tcp"
    exit 1
fi

# 465 - SMTP
echo "Allowing port 465/tcp..."
if ! sudo ufw allow 465/tcp; then
    echo "Error: Failed to allow port 465/tcp"
    exit 1
fi

# 143 - IMAP
echo "Allowing port 143/tcp..."
if ! sudo ufw allow 143/tcp; then
    echo "Error: Failed to allow port 143/tcp"
    exit 1
fi

# 993 - IMAPS
echo "Allowing port 993/tcp..."
if ! sudo ufw allow 993/tcp; then
    echo "Error: Failed to allow port 993/tcp"
    exit 1
fi

# 80 - HTTP
echo "Allowing port 80/tcp..."
if ! sudo ufw allow 80/tcp; then
    echo "Error: Failed to allow port 80/tcp"
    exit 1
fi

# 443 - HTTPS
echo "Allowing port 443/tcp..."
if ! sudo ufw allow 443/tcp; then
    echo "Error: Failed to allow port 443/tcp"
    exit 1
fi

# # 8080 - HTTP
# echo "Allowing port 8080/tcp..."
# if ! sudo ufw allow 8080/tcp; then
#     echo "Error: Failed to allow port 8080/tcp"
#     exit 1
# fi

# 8443 - CloudPanel
# echo "Allowing port 8443/tcp..."
# if ! sudo ufw allow 8443/tcp; then
#     echo "Error: Failed to allow port 8443/tcp"
#     exit 1
# fi

# 8118 - Privoxy
echo "Allowing port 8118/tcp..."
if ! sudo ufw allow 8118/tcp; then
    echo "Error: Failed to allow port 8118/tcp"
    exit 1
fi

# Enable UFW
echo "Enabling firewall..."
echo "y" | sudo ufw enable
if [ $? -ne 0 ]; then
    echo "Error: Failed to enable firewall"
    exit 1
fi

# show the firewall status
echo "Firewall status:"
sudo ufw status verbose

# show the firewall status of added ports
echo "Firewall status of added ports:"
sudo ufw show added

# Exiting
echo "## Setting up firewall - Done"
echo "## Firewall setup complete"
exit 0
