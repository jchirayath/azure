#!/bin/bash

# SET email user
EMAIL_USER="jacobc@aspl.net"

echo "Installing Lynis..."
sudo apt-get install lynis -y

# ## Run Lynis Security Scanner
echo "Running Lynis Security Scanner..."
sudo lynis audit system -Q --no-colors > /root/lynis_report.txt
# cat lynis_report.txt | mail -s "PEN test for Host $$HOSTNAME" "$EMAIL_USER"

# End of Script