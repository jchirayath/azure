#!/bin/bash
MAIL_USER="jacobc@aspl.net"

# Get machine FQDN
FQDN=$(hostname -f)
# Ensure FQDN is valid
if [ -z "$FQDN" ] || [ "$FQDN" = *"localhost"* ]; then
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
# sudo debconf-set-selections <<< "postfix postfix/mailname string $FQDN"
# sudo debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"

# send test mail
echo "This is a test email" | mail -s "Test Email" "$MAIL_USER"

# Configure mail to support SSL
# Install Certbot for SSL certificates
sudo apt-get install -y certbot

# Obtain SSL certificate
# Check if HOSTNAME and MAIL_USER are not empty
if [ -z "$FQDN" ]; then
    echo "FQDN is empty"
    exit 1
fi

if [ -z "$MAIL_USER" ]; then
    echo "MAIL_USER is empty"
    exit 1
fi

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

# Test postfix server
echo "This is a test email from postfix" | mail -s "Postfix Test Email" "$MAIL_USER"
if [ $? -eq 0 ]; then
    echo "Postfix test email sent successfully"
else
    echo "Failed to send postfix test email"
    exit 1
fi

# Verify Postfix SSL certificate
CERT_FILE="/etc/letsencrypt/live/$FQDN/fullchain.pem"
KEY_FILE="/etc/letsencrypt/live/$FQDN/privkey.pem"

if sudo [ -f "$KEY_FILE" ] && sudo [ -f "$CERT_FILE" ]; then
    echo "SSL key and certificate files exist"
else
    echo "SSL key or certificate file is missing"
    exit 1
fi

# Check certificate expiration date
EXPIRATION_DATE=$(sudo openssl x509 -enddate -noout -in "$CERT_FILE" | cut -d= -f2)
echo "SSL certificate expiration date: $EXPIRATION_DATE"

# Test postfix server using openssl
openssl s_client -connect "$FQDN":25 -starttls smtp -crlf -quiet <<EOF
EHLO $FQDN
MAIL FROM:<$MAIL_USER>
RCPT TO:<$MAIL_USER>
DATA
Subject: OpenSSL Test Email

This is a test email sent using OpenSSL.
.
QUIT
EOF
# Send the e-mail
if [ $? -eq 0 ]; then
    echo "OpenSSL test email sent successfully"
else
    echo "Failed to send OpenSSL test email"
    exit 1
fi

# End of Script
