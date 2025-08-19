#!/bin/bash

# Update package lists
sudo apt-get update

# Install dependencies
sudo apt-get install -y wget apt-transport-https software-properties-common

# Add Webmin repository and GPG key (modern method)
wget -qO- https://download.webmin.com/jcameron-key.asc | sudo tee /usr/share/keyrings/webmin.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/webmin.gpg] https://download.webmin.com/download/repository sarge contrib" | sudo tee /etc/apt/sources.list.d/webmin.list

# Update package lists again
sudo apt-get update

# Install Webmin
sudo apt-get install -y webmin

# Output Webmin URL
echo "Webmin installation is complete. You can access it at https://$(hostname -I | awk '{print $1}'):10000/"