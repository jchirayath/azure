#!/bin/bash
MAIL_USER="jacobc@aspl.net"

# Get machine FQDN
FQDN=$(hostname -f)
# Ensure FQDN is valid
if [[ -z "$FQDN" || "$FQDN" == *"localhost"* ]]; then
    echo "Invalid FQDN: $FQDN"
    exit 1
fi
echo "Machine FQDN: $FQDN"

# Setup and Configure Mail
# Install postfix
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postfix
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y mailutils

# configure postfix non interactive
# sudo debconf-set-selections <<< "postfix postfix/mailname string $HOSTNAME"
# sudo debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"

# send test mail
echo "This is a test email" | mail -s "Test Email" "$MAIL_USER"

# Configure mail to support SSL
# Install Certbot for SSL certificates
sudo apt-get install -y certbot

# Obtain SSL certificate
if ! sudo certbot certonly --standalone -d "$FQDN" --non-interactive --agree-tos -m "$MAIL_USER"; then
    echo "Failed to obtain SSL certificate"
    exit 1
fi

# Configure Postfix to use the SSL certificate only if the previous command passes
if [ $? -eq 0 ]; then
    sudo postconf -e "smtpd_tls_cert_file=/etc/letsencrypt/live/$FQDN/fullchain.pem"
    sudo postconf -e "smtpd_tls_key_file=/etc/letsencrypt/live/$FQDN/privkey.pem"
    sudo postconf -e 'smtpd_use_tls=yes'
else
    echo "Previous command failed, skipping Postfix SSL configuration"
    exit 1
fi

# Restart postfix to apply changes
sudo systemctl restart postfix
