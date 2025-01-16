#!/bin/bash

# Dynamie Variables from CreateVM.sh
# Source the variables from CreateVM.sh
myVM_REGION="<VM_REGION>"
myVM_HOST="<VM_HOSTNAME>"
myVM_RESOURCE_GROUP="<VM_RESOURCE_GROUP>"
myMYSQL_ADMIN_PASSWORD='<MYSQL_ADMIN_PASSWORD>'
myMY_GUACAMOLE_PASSWORD='<MY_GUACAMOLE_PASSWORD>'
myMySQLHOST="<MySQLHOST>"
myMySQLUSER="<MySQLUSER>"
myMySQLPASS='<MySQLPASS>'
myEMAIL_USER='<EMAIL_USER>'
myVAULT_NAME="<VAULT_NAME>"

## Set the hostname to the DNS name of the VM
echo "Setting hostname to $myVM_HOST"
sudo hostnamectl set-hostname $myVM_HOST

# Update resolv.conf to include FQDN
echo "Setting Fully Qualified Domain Name (FQDN) to $myVM_HOST.$myVM_REGION.cloudapp.azure.com"
echo "$myVM_HOST.$myVM_REGION.cloudapp.azure.com" | sudo tee /etc/hostname
echo "127.0.1.1 $myVM_HOST.$myVM_REGION.cloudapp.azure.com $myVM_HOST" | sudo tee -a /etc/hosts

# Update resolv.conf to include FQDN
echo "Updating resolv.conf to include FQDN"
sudo sed -i "s/search.*/search $myVM_HOST.$myVM_REGION.cloudapp.azure.com/g" /etc/resolv.conf

## Set the timezone to California
echo "Setting the timezone to California"
sudo timedatectl set-timezone America/Los_Angeles

## Set the locale to en_US.UTF-8
echo "Setting the locale to en_US.UTF-8"
sudo locale-gen en_US.UTF-8
sudo update-locale LANG=en_US.UTF-8

## Update the package list and upgrade all installed packages
echo "Updating package list and upgrading installed packages"
sudo apt-get update -y
sudo apt-get upgrade -y

## Install necessary software
echo "Installing necessary software"
sudo apt-get install -y nginx git curl unzip expect docker.io apache2 php php-mysql mysql-client mysql-server privoxy sssd adcli realmd samba-common krb5-workstation nmap nfs-client rsync screen diffutils lsof tcpdump telnet netcat traceroute wget perl net-tools mailutils lynis certbot python3-certbot-nginx python3-certbot-apache python3-certbot-postfix

## Take a local OS ubuntu snapshot
echo "Installing timeshift and taking initial setup snapshot"
sudo apt-get install -y timeshift
sudo timeshift --create --comments "Initial setup snapshot" --tags INITIAL_SETUP

## Install Azure CLI
echo "Installing Azure CLI"
AZ_REPO=$(lsb_release -cs)
echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $AZ_REPO main" | sudo tee /etc/apt/sources.list.d/azure-cli.list
sudo apt-get update
sudo apt-get install -y azure-cli

## Configure mailutils and postfix
echo "Configuring mailutils and postfix"
FQDN=$(hostname -d)
sudo debconf-set-selections <<< "postfix postfix/mailname string $FQDN"
sudo debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"
sudo apt-get install -y postfix
echo "Testing mail configuration"
echo "This is a test email" | mail -s "Test email" $myEMAIL_USER

## Install and configure Guacamole
echo "Installing and configuring Guacamole"
sudo docker run --name some-guacd -d guacamole/guacd
sudo docker run --name some-guacamole --link some-guacd:guacd \
    -e MYSQL_HOSTNAME=$myMySQLHOST \
    -e MYSQL_DATABASE=guacamoledb  \
    -e MYSQL_USER=$myMySQLUSER    \
    -e MYSQL_PASSWORD=$myMySQLPASS \
    -d -p 8080:8080 guacamole/guacamole

## Dump the guacamole database for initialization
echo "Dumping the guacamole database for initialization"
sudo docker exec -it some-guacamole /opt/guacamole/bin/initdb.sh --mysql > initdb.sql
echo "Testing connection to the guacamole database"
sudo docker exec -it some-guacamole bash -c "mysql -h $myMySQLHOST -u $myMySQLUSER -p$myMySQLPASS guacamoledb"
echo "Testing connection to guacamole server"
curl http://localhost:8080/guacamole/

## Configure MySQL Server
echo "Configuring MySQL Server"
sudo mysql_secure_installation <<EOF

Y
$myMYSQL_ADMIN_PASSWORD
$myMYSQL_ADMIN_PASSWORD
Y
Y
Y
Y
EOF
## Test MySQL
echo "Testing MySQL"
sudo mysql -u root -p$myMYSQL_ADMIN_PASSWORD

## Configure nginx
echo "Configuring nginx"
sudo tee /etc/nginx/sites-available/default <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root /var/www/html;
    index index.html index.htm index.nginx-debian.html;

    server_name _;

    location / {
        proxy_pass http://localhost:8080/guacamole/;
        proxy_buffering off;
        proxy_http_version 1.1;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Connection \$http_connection;
        access_log off;
    }
}  
EOF

## Enable the nginx configuration
echo "Enabling nginx configuration"
sudo ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
sudo systemctl enable nginx
sudo systemctl start nginx

## Install certificates for nginx, apache2, and postfix
echo "Installing certificates for nginx, apache2, and postfix"
sudo certbot --nginx
sudo certbot --apache
sudo certbot --postfix

## Restart services
echo "Restarting services"
#
echo "Restarting nginx"
sudo systemctl restart nginx
#
echo "Restarting postfix"
sudo systemctl restart postfix
#
echo "Restarting apache2"
sudo systemctl restart apache2
#
echo "Restarting docker"
sudo systemctl restart docker

## Configure Privoxy
echo "Configuring Privoxy"
sudo tee /etc/privoxy/config <<EOF
listen-address 127.0.0.1:8118
forward-socks5 / localhost:1080 .
EOF
sudo systemctl restart privoxy
sudo systemctl status privoxy

## Run Lynis Security Scanner
echo "Running Lynis Security Scanner"
sudo lynis audit system -Q --no-colors | mail -s "PEN test for Host $myVM_HOST" $myEMAIL_USER

## Test configurations and services
echo "Testing configurations and services"
sudo nginx -t
sudo postfix check
sudo apache2ctl configtest
sudo systemctl status docker
sudo lynis audit system -Q --no-colors

## Test Privoxy
echo "Testing Privoxy"
curl -x http://localhost:8118 http://example.com

## Print completion message
echo "VM update and software installation complete."