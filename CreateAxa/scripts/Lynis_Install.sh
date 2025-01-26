#!/bin/bash

# SET email user
EMAIL_USER="jacobc@aspl.net"

# Function to install Lynis
function install_lynis() {
    echo "Installing Lynis..."
    sudo apt-get install lynis -y
}
# Install  Lynis
install_lynis

# ## Run Lynis Security Scanner
echo "Running Lynis Security Scanner..."
sudo lynis audit system -Q --no-colors > /tmp/lynis_report.txt
cat /tmp/lynis_report.txt | mail -s "PEN test for Host $$HOSTNAME" "$EMAIL_USER"

# End of Script