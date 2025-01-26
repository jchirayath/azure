#!/bin/bash

# Install Fail2Ban
echo "Installing Fail2Ban..."
sudo DEBIAN_FRONTEND=noninteractive apt-get install fail2ban -y
# Check for errors
if [ $? -ne 0 ]; then
    echo "Error: Failed to install Fail2Ban"
    exit 1
fi

# Configure Fail2Ban
echo "Configuring Fail2Ban..."
sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
sudo sed -i 's/backend = auto/backend = systemd/g' /etc/fail2ban/jail.local
sudo sed -i 's/maxretry = 5/maxretry = 3/g' /etc/fail2ban/jail.local
sudo sed -i 's/bantime = 600/bantime = 3600/g' /etc/fail2ban/jail.local
sudo sed -i 's/findtime = 600/findtime = 600/g' /etc/fail2ban/jail.local

# Create a separate configuration file for SSH monitoring
echo "[sshd]" | sudo tee /etc/fail2ban/jail.d/sshd.local
echo "enabled = true" | sudo tee -a /etc/fail2ban/jail.d/sshd.local
echo "port = ssh" | sudo tee -a /etc/fail2ban/jail.d/sshd.local
echo "filter = sshd" | sudo tee -a /etc/fail2ban/jail.d/sshd.local
echo "logpath = /var/log/auth.log" | sudo tee -a /etc/fail2ban/jail.d/sshd.local
echo "maxretry = 3" | sudo tee -a /etc/fail2ban/jail.d/sshd.local
echo "bantime = 3600" | sudo tee -a /etc/fail2ban/jail.d/sshd.local
echo "findtime = 600" | sudo tee -a /etc/fail2ban/jail.d/sshd.local

# Enable Fail2Ban
echo "Enabling Fail2Ban..."
sudo systemctl enable fail2ban
sudo systemctl start fail2ban
# Check for errors
if [ $? -ne 0 ]; then
    echo "Error: Failed to enable Fail2Ban"
    exit 1
fi

# wait for fail2ban to start
echo "Waiting for Fail2Ban to start..."
sleep 5

# Test Fail2Ban
echo "Testing Fail2Ban..."
sudo fail2ban-client status sshd
# Check for errors
if [ $? -ne 0 ]; then
    echo "Error: Fail2Ban test failed"
    exit 1
fi

echo "## Fail2Ban setup complete"
exit 0