#!/bin/bash

# Update package lists
sudo apt-get update

# Install dependencies
sudo apt-get install -y wget apt-transport-https software-properties-common

# # Add Webmin repository and GPG key (modern method)
# wget -qO- https://download.webmin.com/jcameron-key.asc | gpg --dearmor | sudo tee /usr/share/keyrings/webmin.gpg > /dev/null
# echo "deb [signed-by=/usr/share/keyrings/webmin.gpg] https://download.webmin.com/download/repository sarge contrib" | sudo tee /etc/apt/sources.list.d/webmin.list
# Install Web from instructions at https://www.webmin.com/download.html
curl -o webmin-setup-repo.sh https://raw.githubusercontent.com/webmin/webmin/master/webmin-setup-repo.sh
sudo sh webmin-setup-repo.sh

# Update package lists again
sudo apt-get update

# Install Webmin
sudo apt-get install -y webmin --install-recommends

# Output Webmin URL
echo "Webmin installation is complete. You can access it at https://$(hostname -I | awk '{print $1}'):10000/"