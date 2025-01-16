#!/bin/bash

# Dynamie Variables from CreateVM.sh
# Source the variables from CreateVM.sh
myVM_REGION=<VM_REGION>
myVM_HOSTNAME=<VM_HOSTNAME>
myVM_RESOURCE_GROUP=<VM_RESOURCE_GROUP>
myMYSQL_ADMIN_PASSWORD=<MYSQL_ADMIN_PASSWORD>
myMY_GUACAMOLE_PASSWORD=<MY_GUACAMOLE_PASSWORD>
myMySQLHOST=<MySQLHOST>
myMySQLUSER=<MySQLUSER>
myMySQLPASS=<MySQLPASS>
myEMAIL_USER=<EMAIL_USER>
myVAULT_NAME=<VAULT_NAME>

# Set the hostname to the DNS name of the VM
sudo hostnamectl set-hostname $myVM_HOST

# Update the package list and upgrade all installed packages
sudo apt-get update -y
sudo apt-get upgrade -y

# Install necessary software
sudo apt-get install -y nginx git curl unzip expect docker.io apache2 php php-mysql mysql-client mysql-server privoxy sssd adcli realmd samba-common krb5-workstation nmap nfs-client rsync screen diffutils lsof tcpdump telnet netcat traceroute wget perl net-tools mailutils lynis certbot python3-certbot-nginx python3-certbot-apache python3-certbot-postfix

# Take a local OS ubuntu snapshot
sudo apt-get install -y timeshift
# Take a snapshot of the OS with timeshift
sudo timeshift --create --comments "Initial setup snapshot" --tags INITIAL_SETUP

# Configure mailutils and postfix
FQDN=$(hostname -d)
sudo debconf-set-selections <<< "postfix postfix/mailname string $FQDN"
sudo debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"
sudo apt-get install -y postfix

# Install Azure CLI
AZ_REPO=$(lsb_release -cs)
echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $AZ_REPO main" | sudo tee /etc/apt/sources.list.d/azure-cli.list
sudo apt-get update
sudo apt-get install -y azure-cli

# Install and configure Guacamole
sudo docker run --name some-guacd -d guacamole/guacd
sudo docker run --name some-guacamole --link some-guacd:guacd \
    -e MYSQL_HOSTNAME=$myMySQLHOST \
    -e MYSQL_DATABASE=guacamoledb  \
    -e MYSQL_USER=$myMySQLUSER    \
    -e MYSQL_PASSWORD=$myMySQLPASS \
    -d -p 8080:8080 guacamole/guacamole
sudo docker exec -it some-guacamole /opt/guacamole/bin/initdb.sh --mysql > initdb.sql

# Configure nginx
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
sudo ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl reload nginx
sudo systemctl enable nginx
sudo systemctl start nginx

# Install certificates for nginx, apache2, and postfix
sudo certbot --nginx
sudo certbot --apache
sudo certbot --postfix

# Restart services
sudo systemctl restart nginx
sudo systemctl restart postfix
sudo systemctl restart apache2
sudo systemctl restart docker

# Run Lynis Security Scanner
sudo lynis audit system -Q --no-colors | mail -s "PEN test for Host $VM_" $EMAIL_USER

# Test mail
echo "This is a test email" | mail -s "Test email" $EMAIL_USER

# Test the Guacamole installation
curl http://localhost:8080/guacamole/

# Test configurations and services
sudo nginx -t
sudo postfix check
sudo apache2ctl configtest
sudo systemctl status docker
sudo lynis audit system -Q --no-colors

# Configure Privoxy
listen-address 127.0.0.1:8118
listen-address
forward-socks5 / localhost:1080 .
EOF
sudo systemctl restart privoxy
sudo systemctl status privoxy
# Test Privoxy
curl -x http://localhost:8118 http://example.com

# Configure MySQL Server
sudo mysql_secure_installation
sudo mysql -u root -p


# Test Tomcat
sudo docker exec -it some-guacamole bash -c "cat /usr/local/tomcat/conf/tomcat-users.xml"
# Fix guacamole Tomcat configuration have a default index.html
sudo docker exec -it some-guacamole bash -c "echo '<html><body><h1>Guacamole</h1></body></html>' > /usr/local/tomcat/webapps/guacamole/index.html"
# Fix Tomcat server root configuration to have a default index.html
sudo docker exec -it some-guacamole bash -c "mkdir -p /usr/local/tomcat/webapps/ROOT && echo '<html><body><h1>Tomcat Server</h1></body></html>' > /usr/local/tomcat/webapps/ROOT/index.html"

# Print completion message
echo "VM update and software installation complete."