#!/bin/bash
# Function to install Fail2Ban
function install_fail2ban() {
    echo "Installing Fail2Ban..."
    sudo DEBIAN_FRONTEND=noninteractive apt-get install fail2ban -y

    # Check for errors
    if [ $? -ne 0 ]; then
        echo "Error: Failed to install Fail2Ban"
        exit 1
    else
        echo "## Installing Fail2Ban - Done"
    fi
    # Configure Fail2Ban
    echo "Configuring Fail2Ban..."
    sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
    sudo sed -i 's/backend = auto/backend = systemd/g' /etc/fail2ban/jail.local
    sudo sed -i 's/maxretry = 5/maxretry = 3/g' /etc/fail2ban/jail.local
    sudo sed -i 's/bantime = 600/bantime = 3600/g' /etc/fail2ban/jail.local
    sudo sed -i 's/findtime = 600/findtime = 600/g' /etc/fail2ban/jail.local

    # Enable Fail2Ban
    echo "Enabling Fail2Ban..."
    sudo systemctl enable fail2ban
    sudo systemctl start fail2ban
    # Check for errors
    if [ $? -ne 0 ]; then
        echo "Error: Failed to enable Fail2Ban"
        exit 1
    else
        echo "## Enabling Fail2Ban - Done"
    fi
    # Exit the script
    echo "## Fail2Ban setup complete"
    exit 0
}

# Call the function
echo "## Installing Fail2Ban"
install_fail2ban

# Check for errors
if [ $? -ne 0 ]; then
    echo "Error: Failed to install Fail2Ban"
    exit 1
else
    echo "## Installing Fail2Ban - Done"
fi

# Exit the script
echo "## Fail2Ban setup complete"
exit 0