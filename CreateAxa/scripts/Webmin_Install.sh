#!/bin/bash

# Update package lists
sudo apt-get update

# Install dependencies
sudo apt-get install -y wget apt-transport-https software-properties-common

# Add Webmin repository
wget -q http://www.webmin.com/jcameron-key.asc -O- | sudo apt-key add -
sudo sh -c 'echo "deb http://download.webmin.com/download/repository sarge contrib" > /etc/apt/sources.list.d/webmin.list'

# Update package lists again
sudo apt-get update

# Install Webmin
sudo apt-get install -y webmin

# Output Webmin URL
echo "Webmin installation is complete. You can access it at https://$(hostname -I | awk '{print $1}'):10000/"