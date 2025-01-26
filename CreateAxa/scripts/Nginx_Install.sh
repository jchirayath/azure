#!/bin/bash

set -e

# Set e-mail address for Certbot non-interactive mode
EMAIL="jacobc@aspl.net"

# Get machine FQDN
FQDN=$(hostname -f)
# Ensure FQDN is valid
if [ -z "$FQDN" ] || [ "$FQDN" = *"localhost"* ]; then
    echo "Invalid FQDN: $FQDN"
    exit 1
fi
echo "Machine FQDN: $FQDN"

# Stop Apache2 Web Server
echo "Stopping Apache2..."
if ! sudo systemctl stop apache2; then
    echo "Failed to stop Apache2"
    exit 1
fi

echo "Disabling Apache2..."
if ! sudo systemctl disable apache2; then
    echo "Failed to disable Apache2"
    exit 1
fi

echo "Installing Nginx..."
if ! sudo apt-get install nginx -y; then
        echo "Failed to install Nginx"
        exit 1
fi

# Install Certbot
echo "Installing Certbot..."
if ! sudo apt-get install certbot python3-certbot-nginx -y; then
        echo "Failed to install Certbot"
        exit 1
fi

# configure certbot for nginx
echo "Configuring Certbot for Nginx..."
if ! sudo certbot --nginx -d $FQDN --non-interactive --agree-tos --email $EMAIL; then
    echo "Failed to configure Certbot for Nginx"
    exit 1
fi

# Backup the original index.html if it exists
if [ -f /var/www/html/index.html ]; then
    echo "Backing up the original index.html..."
    if ! sudo mv /var/www/html/index.html /var/www/html/index.html.bak; then
        echo "Failed to backup the original index.html"
        exit 1
    fi
fi

# Download the new index.html from the provided URL
echo "Downloading the new index.html..."
if ! sudo curl -o /var/www/html/index.html https://raw.githubusercontent.com/jchirayath/azure/master/CreateAxa/files/index.html; then
    echo "Failed to download the new index.html"
    exit 1
fi

# Link the Apache2 icons directory to the Nginx web root
echo "Linking the Apache2 icons directory to the Nginx web root..."
if ! sudo ln -s /usr/share/apache2/icons /var/www/html/icons; then
    echo "Failed to link the Apache2 icons directory probably exists"
fi

# Enable nginx
echo "Enabling nginx..."
if ! sudo systemctl enable nginx; then
        echo "Failed to enable nginx"
        exit 1
fi

# Restart nginx
echo "Restarting nginx..."
if ! sudo systemctl restart nginx; then
        echo "Failed to restart nginx"
        exit 1
fi

# Test nginx
echo "Testing nginx..."
if ! sudo nginx -t; then
        echo "Failed to test nginx"
        exit 1
fi

echo "## Installing Nginx - Done"

# Exit the script
echo "## Nginx setup complete"
exit 0