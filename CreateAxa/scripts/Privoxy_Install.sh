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
sudo sed -i 's/^listen-address  localhost:8118/listen-address  0.0.0.0:8118/' /etc/privoxy/config

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
