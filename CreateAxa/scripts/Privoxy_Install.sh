#!/bin/bash

echo "Installing Privoxy..."
if sudo apt-get install privoxy -y; then
    echo "Privoxy installed successfully."
else
    echo "Failed to install Privoxy." >&2
    exit 1
fi

echo "Configuring Privoxy..."
sudo cp /etc/privoxy/config /etc/privoxy/config.backup
sudo sed -i 's/^listen-address  127.0.0.1:8118/listen-address  0.0.0.0:8118/' /etc/privoxy/config

# Allow external access by updating the 'listen-address' and 'permit-access' settings
sudo sed -i '/^#* *permit-access /d' /etc/privoxy/config
echo "permit-access 0.0.0.0" | sudo tee -a /etc/privoxy/config > /dev/null

# Restrict access to Zscaler IP ranges only for security
# List of Zscaler IP ranges (example, update as needed)
ZSCALER_IP_RANGES=(
    "185.46.212.0/22"
    "185.46.216.0/22"
    "185.46.220.0/22"
    "185.46.224.0/22"
    "185.46.228.0/22"
    "185.46.232.0/22"
    "185.46.236.0/22"
    "185.46.240.0/22"
    # Add more Zscaler IP ranges as needed
)

for ip_range in "${ZSCALER_IP_RANGES[@]}"; do
    echo "permit-access $ip_range" | sudo tee -a /etc/privoxy/config > /dev/null
done

# Enable debug logging for troubleshooting
if ! grep -q '^debug 1' /etc/privoxy/config; then
    echo "debug 1" | sudo tee -a /etc/privoxy/config > /dev/null
fi

# Restart Privoxy
echo "Restarting Privoxy..."
sudo systemctl restart privoxy
echo "Privoxy configured successfully."

## Test Privoxy
echo "## Testing Privoxy"
curl -x http://localhost:8118 http://example.com
# error handling
if [ $? -ne 0 ]; then
    echo "Failed to test Privoxy." >&2
    exit 1
fi

# End of Script
