#!/bin/bash

set -e

# Set e-mail address for Certbot non-interactive mode
EMAIL="jacobc@aspl.net"

# Check if the script is running as root, if not re-run it with sudo
if [ "$EUID" -ne 0 ]; then
    echo "This script must be run as root. Re-running with sudo..."
    exec sudo "$0" "$@"
fi

# Stop Apache2 Web Server
echo "Stopping Apache2..."
if ! systemctl stop apache2; then
    echo "Failed to stop Apache2"
    exit 1
fi

echo "Disabling Apache2..."
if ! systemctl disable apache2; then
    echo "Failed to disable Apache2"
    exit 1
fi

echo "Installing Nginx..."
if ! apt-get install nginx -y; then
        echo "Failed to install Nginx"
        exit 1
fi

# Install Certbot
echo "Installing Certbot..."
if ! apt-get install certbot python3-certbot-nginx -y; then
        echo "Failed to install Certbot"
        exit 1
fi

# configure certbot for nginx
echo "Configuring Certbot for Nginx..."
if ! certbot --nginx -d $HOSTNAME --non-interactive --agree-tos --email $EMAIL; then
    echo "Failed to configure Certbot for Nginx"
    exit 1
fi

# Enable nginx
echo "Enabling nginx..."
if ! systemctl enable nginx; then
        echo "Failed to enable nginx"
        exit 1
fi

# Restart nginx
echo "Restarting nginx..."
if ! systemctl restart nginx; then
        echo "Failed to restart nginx"
        exit 1
fi

echo "## Installing Nginx - Done"

# Exit the script
echo "## Nginx setup complete"
exit 0