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
: '
# KnockD UFW Configuration Script

This script configures KnockD to dynamically manage UFW (Uncomplicated Firewall) rules based on port knocking sequences. When the correct sequence is received, UFW rules are temporarily added to allow access from the knocking IP to specific ports, and then removed after a timeout or upon receiving a closing sequence.

## Port Descriptions:
- **22**: SSH (Secure Shell) - Remote server administration.
- **8118**: Privoxy - Non-caching web proxy.
- **8080**: Alternative HTTP port - Often used for web servers or proxies.
- **5601**: Kibana - Web interface for Elasticsearch.
- **9090**: Prometheus - Monitoring system and time series database.
- **3000**: Grafana - Analytics and monitoring dashboard.
- **1000**: Custom/Reserved - Not a standard service, used as per local requirements.
- **8081**: Alternative HTTP port - Often used for web servers or proxies.
- **8084**: Alternative HTTP port - Often used for web servers or proxies.

## KnockD Sequences:
- **openSSH**: Sequence `7000,8000,9000` opens the above ports for the knocking IP for 8 hours (28800 seconds).
- **closeSSH**: Sequence `9000,8000,7000` immediately closes the above ports for the knocking IP.

All actions are logged via syslog. The configuration ensures that only the IP that performed the correct knock sequence is granted temporary access.
'
# Configure KnockD using UFW
echo "Configuring KnockD..."
if ! sudo tee /etc/knockd.conf > /dev/null <<EOF
[options]
    UseSyslog

[openSSH]
    sequence    = 7000,8000,9000
    seq_timeout = 5
    command     = /usr/sbin/ufw allow from %IP% to any port 22 proto tcp; \
                  /usr/sbin/ufw allow from %IP% to any port 8118 proto tcp; \
                  /usr/sbin/ufw allow from %IP% to any port 8080 proto tcp; \
                  /usr/sbin/ufw allow from %IP% to any port 5601 proto tcp; \
                  /usr/sbin/ufw allow from %IP% to any port 9090 proto tcp; \
                  /usr/sbin/ufw allow from %IP% to any port 3000 proto tcp; \
                  /usr/sbin/ufw allow from %IP% to any port 1000 proto tcp; \
                  /usr/sbin/ufw allow from %IP% to any port 8081 proto tcp; \
                  /usr/sbin/ufw allow from %IP% to any port 8084 proto tcp; \
                  (sleep 28800; \
                   /usr/sbin/ufw delete allow from %IP% to any port 22 proto tcp; \
                   /usr/sbin/ufw delete allow from %IP% to any port 8118 proto tcp; \
                   /usr/sbin/ufw delete allow from %IP% to any port 8080 proto tcp; \
                   /usr/sbin/ufw delete allow from %IP% to any port 5601 proto tcp; \
                   /usr/sbin/ufw delete allow from %IP% to any port 9090 proto tcp; \
                   /usr/sbin/ufw delete allow from %IP% to any port 3000 proto tcp; \
                   /usr/sbin/ufw delete allow from %IP% to any port 1000 proto tcp; \
                   /usr/sbin/ufw delete allow from %IP% to any port 8081 proto tcp; \
                   /usr/sbin/ufw delete allow from %IP% to any port 8084 proto tcp) &    # Remove after 8 hours (28800 seconds)
    tcpflags    = syn

[closeSSH]
    sequence    = 9000,8000,7000
    seq_timeout = 5
    command     = /usr/sbin/ufw delete allow from %IP% to any port 22 proto tcp; \
                  /usr/sbin/ufw delete allow from %IP% to any port 8118 proto tcp; \
                  /usr/sbin/ufw delete allow from %IP% to any port 8080 proto tcp; \
                  /usr/sbin/ufw delete allow from %IP% to any port 5601 proto tcp; \
                  /usr/sbin/ufw delete allow from %IP% to any port 9090 proto tcp; \
                  /usr/sbin/ufw delete allow from %IP% to any port 3000 proto tcp; \
                  /usr/sbin/ufw delete allow from %IP% to any port 1000 proto tcp; \
                  /usr/sbin/ufw delete allow from %IP% to any port 8081 proto tcp; \
                  /usr/sbin/ufw delete allow from %IP% to any port 8084 proto tcp
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