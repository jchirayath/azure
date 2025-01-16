#!/bin/bash

# Exit if any command fails
set -e

# Update APT repository
apt-get -y update

# Install Software
apt-get -y install docker.io
apt-get -y install apache2
apt-get -y install php
apt-get -y install php-mysql
apt-get -y install mysql-client
apt-get -y install nginx
apt-get -y install privoxy
#apt-get -y install sssd adcli realmd  samba-common
#apt-get -y install sssd realmd adcli krb5-workstation samba-common
apt-get -y install expect unzip nmap nfs-client rsync screen diffutils lsof 
apt-get -y install tcpdump telnet netcat traceroute wget perl curl
apt-get -y install net-tools

# Install Azure CLI
AZ_REPO=$(lsb_release -cs)
echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $AZ_REPO main" |
    sudo tee /etc/apt/sources.list.d/azure-cli.list
apt-get update
apt-get install azure-cli

# Assumption is that DBs are hosted on GearHost.com
# That way I dont need Pay for a database service in Azure seperately.
VM_REGION="westus3"
VAULT_NAME="kv-aspl-$VM_REGION"
EMAIL_USER='jacobc@aspl.net'
# Define Web Hostname
myHOST="axa.$VM_REGION.cloudapp.azure.com"

# Get hostname/username/password from Azure Key Vault
# myMySQLHOST=$(az keyvault secret show --vault-name $VAULT_NAME --name "guacamoledbhost" --query value -o tsv)
# myMySQLUSER=$(az keyvault secret show --vault-name $VAULT_NAME --name "guacamoledbuser" --query value -o tsv)
# myMySQLPASS=$(az keyvault secret show --vault-name $VAULT_NAME --name "guacamoledbpass" --query value -o tsv)

myMySQLHOST="den1.mysql6.gear.host"
myMySQLUSER="guacamoledb"
myMySQLPASS='Of022_E5KvL-'

# Run the Guacamole scrip to generate the MySQL config file - not required since we are using GearHost
# docker run --rm guacamole/guacamole /opt/guacamole/bin/initdb.sh --mysql > initdb.sql

## Guacamole Install
docker run --name some-guacd -d guacamole/guacd
# Install Start Docker GUACAMOLE
docker run --name some-guacamole --link some-guacd:guacd \
    -e MYSQL_HOSTNAME=$myMySQLHOST \
    -e MYSQL_DATABASE=guacamoledb  \
    -e MYSQL_USER=$myMySQLUSER    \
    -e MYSQL_PASSWORD=$myMySQLPASS \
    -d -p 8080:8080 guacamole/guacamole

# Update the Guacamole MySQL Configuration - not required since we are using GearHost
# mysql --host=$myMySQLHOST --user=$myMySQLUSER --password=$myMySQLPASS -e "intidb.sql"

# Fix  Tomcat Configuration for guacamole
# Get username and password from Azure Key Vault
# guacAdminUser=$(az keyvault secret show --vault-name $VAULT_NAME --name "guacadminuser" --query value -o tsv)
# guacAdminPassword=$(az keyvault secret show --vault-name $VAULT_NAME --name "guacadminpass" --query value -o tsv)
# TomcatAdminUser="tomcat"
# TomcatAdminPass="tomcat"
# docker exec -it some-guacamole bash -c "sed -i 's/<\/tomcat-users>/  <role rolename=\"$TomcatAdminUser\"\/>\n  <user username=\"tomcat\" password=\"$TomcatAdminPass\" roles=\"guacamole-admin\"\/>\n<\/tomcat-users>/' /usr/local/tomcat/conf/tomcat-users.xml"
wget https://raw.githubusercontent.com/jchirayath/aws/master/s3/config/tomcat-users.xml
docker cp tomcat-users.xml some-guacamole:/usr/local/tomcat/conf/tomcat-users.xml 

# Restart Docker Guacamole and Guacd
docker update  --restart unless-stopped some-guacamole
docker update  --restart unless-stopped some-guacd

## Configure Apache Web Server
# Stop Apache to update the configuration files
service apache2 stop

# Get Updated Index.htm from GitHub and copy to /var/www/html
wget https://raw.githubusercontent.com/jchirayath/aws/master/s3/config/index.html
cp index.html /var/www/html/index.html

# Get Updated nginx Config from GitHub and copy to /etc/nginx/nginx.conf
#wget https://raw.githubusercontent.com/jchirayath/aws/master/s3/config/nginx.conf
#cp nginx.conf /etc/nginx/nginx.conf

# Get Updated nginx Config from GitHub and copy to /etc/nginx/nginx.conf
wget https://raw.githubusercontent.com/jchirayath/aws/master/s3/config/usr-share-nginx-html-index.html 
cp usr-share-nginx-html-index.html /usr/share/nginx/html/index.html

## Install and configure Mail
DEBIAN_FRONTEND=noninteractive 
apt-get -y install postfix mailutils

# Configure Postfix
postconf -e "myhostname = $myHOST"
postconf -e "mydestination = $myHOST, localhost.localdomain, localhost"
# debconf-set-selections <<< "postfix postfix/mailname string $myHOST"
# debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"
dpkg-reconfigure -f noninteractive postfix

# Start Postfix service
systemctl start postfix
systemctl enable postfix

## Install and run Lynis Security Scanner
apt-get -y install lynis
lynis audit system -Q --no-colors | mail -s "PEN test for Host $myHOST" $EMAIL_USER
#git clone https://github.com/CISOfy/lynis

# Install Certificate for Server
apt-get -y install python3-certbot-apache
apt-get -y install python3-certbot-nginx
certbot --apache -d $myHOST --non-interactive --agree-tos -m $EMAIL_USER
certbot --nginx -d $myHOST --non-interactive --agree-tos -m $EMAIL_USER

# Install certificate for Postfix
apt-get -y install certbot
certbot certonly --standalone -d $myHOST --non-interactive --agree-tos -m $EMAIL_USER

# Configure Postfix to use the certificate
postconf -e "smtpd_tls_cert_file=/etc/letsencrypt/live/$myHOST/fullchain.pem"
postconf -e "smtpd_tls_key_file=/etc/letsencrypt/live/$myHOST/privkey.pem"
postconf -e "smtpd_use_tls=yes"
postconf -e "smtpd_tls_session_cache_database = btree:/var/lib/postfix/smtpd_scache"
postconf -e "smtp_tls_session_cache_database = btree:/var/lib/postfix/smtp_scache"

# Restart Postfix to apply changes
systemctl restart postfix

# Install mysqldaemon
apt-get -y install mysql-server
systemctl start mysql
systemctl enable mysql

# Enable default access policies for mysqldaemon
# MYSQL_ADMIN_PASSWORD=$(az keyvault secret show --vault-name $VAULT_NAME --name "mysqladminpass" --query value -o tsv)
MYSQL_ADMIN_PASSWORD="Of022_E5KvL-"
mysql -e "CREATE USER 'admin'@'%' IDENTIFIED BY '$MYSQL_ADMIN_PASSWORD';"
mysql -e "GRANT ALL PRIVILEGES ON *.* TO 'admin'@'%' WITH GRANT OPTION;"
mysql -e "FLUSH PRIVILEGES;"

# install cloudpanel
curl -sSL https://installer.cloudpanel.io/ce/v2/install.sh | sudo bash