# Create script to install and configure KnockD
#!/bin/bash
set -e

# Function to print error messages
error_exit() {
    echo "Error: $1" >&2
    exit 1
}

# Get machine FQDN
FQDN=$(hostname -f)

# Ensure FQDN is valid
if [ -z "$FQDN" ] || [[ "$FQDN" == *"localhost"* ]]; then
    error_exit "Invalid FQDN: $FQDN"
fi
echo "Machine FQDN: $FQDN"

# Update package list
echo "Updating package list..."
if ! sudo apt-get update; then
    error_exit "Failed to update package list"
fi

# Install KnockD
echo "Installing KnockD..."
if ! sudo apt-get install knockd -y; then
    error_exit "Failed to install KnockD"
fi

# Configure KnockD
echo "Configuring KnockD..."
if ! sudo tee /etc/knockd.conf > /dev/null <<EOF
[options]
    UseSyslog

[openSSH]
    sequence    = 7000,8000,9000
    seq_timeout = 5
    command     = /usr/sbin/iptables -A INPUT -s %IP% -p tcp --dport 22 -j ACCEPT; \
                  /usr/sbin/iptables -A INPUT -s %IP% -p tcp --dport 8118 -j ACCEPT; \
                  /usr/sbin/iptables -A INPUT -s %IP% -p tcp --dport 8080 -j ACCEPT; \
                  /usr/sbin/iptables -A INPUT -s %IP% -p tcp --dport 5601 -j ACCEPT; \
                  /usr/sbin/iptables -A INPUT -s %IP% -p tcp --dport 9090 -j ACCEPT; \
                  /usr/sbin/iptables -A INPUT -s %IP% -p tcp --dport 3000 -j ACCEPT; \
                  /usr/sbin/iptables -A INPUT -s %IP% -p tcp --dport 1000 -j ACCEPT; \
                  /usr/sbin/iptables -A INPUT -s %IP% -p tcp --dport 8081 -j ACCEPT; \
                  /usr/sbin/iptables -A INPUT -s %IP% -p tcp --dport 8084 -j ACCEPT; \
                  (sleep 28800; \
                   /usr/sbin/iptables -D INPUT -s %IP% -p tcp --dport 22 -j ACCEPT; \
                   /usr/sbin/iptables -D INPUT -s %IP% -p tcp --dport 8118 -j ACCEPT; \
                   /usr/sbin/iptables -D INPUT -s %IP% -p tcp --dport 8080 -j ACCEPT; \
                   /usr/sbin/iptables -D INPUT -s %IP% -p tcp --dport 5601 -j ACCEPT; \
                   /usr/sbin/iptables -D INPUT -s %IP% -p tcp --dport 9090 -j ACCEPT; \
                   /usr/sbin/iptables -D INPUT -s %IP% -p tcp --dport 3000 -j ACCEPT; \
                   /usr/sbin/iptables -D INPUT -s %IP% -p tcp --dport 1000 -j ACCEPT; \
                   /usr/sbin/iptables -D INPUT -s %IP% -p tcp --dport 8081 -j ACCEPT; \
                   /usr/sbin/iptables -D INPUT -s %IP% -p tcp --dport 8084 -j ACCEPT) &    # Remove after 8 hours (28800 seconds)
    tcpflags    = syn

[closeSSH]
    sequence    = 9000,8000,7000
    seq_timeout = 5
    command     = /usr/sbin/iptables -D INPUT -s %IP% -p tcp --dport 22 -j ACCEPT; \
                  /usr/sbin/iptables -D INPUT -s %IP% -p tcp --dport 8118 -j ACCEPT; \
                  /usr/sbin/iptables -D INPUT -s %IP% -p tcp --dport 8080 -j ACCEPT; \
                  /usr/sbin/iptables -D INPUT -s %IP% -p tcp --dport 5601 -j ACCEPT; \
                  /usr/sbin/iptables -D INPUT -s %IP% -p tcp --dport 9090 -j ACCEPT; \
                  /usr/sbin/iptables -D INPUT -s %IP% -p tcp --dport 3000 -j ACCEPT; \
                  /usr/sbin/iptables -D INPUT -s %IP% -p tcp --dport 1000 -j ACCEPT; \
                  /usr/sbin/iptables -D INPUT -s %IP% -p tcp --dport 8081 -j ACCEPT; \
                  /usr/sbin/iptables -D INPUT -s %IP% -p tcp --dport 8084 -j ACCEPT
    tcpflags    = syn
EOF
then
    error_exit "Failed to write /etc/knockd.conf"
fi

# Enable and start KnockD service
echo "Enabling and starting KnockD service..."
if ! sudo systemctl enable knockd; then
    error_exit "Failed to enable knockd service"
fi
if ! sudo systemctl restart knockd; then
    error_exit "Failed to start knockd service"
fi

echo "KnockD installation and configuration complete."