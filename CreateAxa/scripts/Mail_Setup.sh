#!/bin/bash

# Setup and Configure Mail
# Install postfix
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y postfix

# configure postfix non interactive
sudo debconf-set-selections <<< "postfix postfix/mailname string $HOSTNAME"
sudo debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"

# Restart postfix to apply changes
sudo systemctl restart postfix
