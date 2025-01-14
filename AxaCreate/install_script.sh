#!/bin/bash
# Update APT repository
apt-get -y update
# Install Software
apt-get -y install docker docker.io
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

# Stop Apache
service stop apache2

# Install Azure CLI
AZ_REPO=$(lsb_release -cs)
echo "deb [arch=amd64] https://packages.microsoft.com/repos/azure-cli/ $AZ_REPO main" |
    sudo tee /etc/apt/sources.list.d/azure-cli.list
apt-get update
apt-get install azure-cli

# Assumption is that DBs are hosted on GearHost.com
# That way I dont need Pay for a database service in Azure seperately.

# Create Secret in Azure Key Vault
VAULT_NAME="kv-aspl-eastus"
myMyuSQLHOST=“den1.mysql6.gear.host”
myUser=“guacamoledb”
myPassword=“Of022_E5KvL-”
az keyvault secret set --vault-name $VAULT_NAME --name "guacamoledbhost" --value $myMyuSQLHOST
az keyvault secret set --vault-name $VAULT_NAME --name "guacamoledbuser" --value $myUser
az keyvault secret set --vault-name $VAULT_NAME --name "guacamoledbpass" --value $myPassword

# Get hostname from Azure Key Vault
myMyuSQLHOST=$(az keyvault secret show --vault-name $VAULT_NAME --name "guacamoledbhost" --query value -o tsv)
myUser=$(az keyvault secret show --vault-name $VAULT_NAME --name "guacamoledbuser" --query value -o tsv)
myPassword=$(az keyvault secret show --vault-name $VAULT_NAME --name "guacamoledbpass" --query value -o tsv)

# Define Web Hostname
myHOST=“axa.eastus2.cloudapp.azure.com”

# Guacamole Install
docker run --name some-guacd -d guacamole/guacd
# Install Start Docker GUACAMOLE
docker run --name some-guacamole --link some-guacd:guacd \
    -e MYSQL_HOSTNAME=$myMyuSQLHOST \
    -e MYSQL_DATABASE=guacamoledb  \
    -e MYSQL_USER=$myUser    \
    -e MYSQL_PASSWORD=$myPassword \
    -d -p 8080:8080 guacamole/guacamole

# Update the Guacamole Tomcat Configuration
mysql --host=$myMyuSQLHOST --user=$myUser --password=$myPassword -e "intidb.sql"

# GUACD Install
docker run --name some-guacd -d guacamole/guacd
docker run --name some-guacamole --link some-guacd:guacd \
    -e MYSQL_HOSTNAME=$myMyuSQLHOST \
    -e MYSQL_DATABASE=guacamoledb  \
    -e MYSQL_USER=$myUser    \
    -e MYSQL_PASSWORD=$myPassword \
    -d -p 8080:8080 guacamole/guacamole

# Fix  Tomcat Configuration for guacamole
# Get username and password from Azure Key Vault
guacAdminUser=$(az keyvault secret show --vault-name $VAULT_NAME --name "guacadminuser" --query value -o tsv)
guacAdminPassword=$(az keyvault secret show --vault-name $VAULT_NAME --name "guacadminpass" --query value -o tsv)
docker exec -it some-guacamole bash -c "sed -i 's/<\/tomcat-users>/  <role rolename=\"guacamole-admin\"\/>\n  <user username=\"tomcat\" password=\"$guacAdminPassword\" roles=\"guacamole-admin\"\/>\n<\/tomcat-users>/' /usr/local/tomcat/conf/tomcat-users.xml"

# Restart Docker Guacamole and Guacd
docker update  --restart unless-stopped some-guacamole
docker update  --restart unless-stopped some-guacd

# Get Updated Index.htm from GitHub
wget https://raw.githubusercontent.com/jchirayath/aws/master/s3/config/index.html
cp index.html /var/www/html/index.html

# Get Updated nginx Config from GitHub
#wget https://raw.githubusercontent.com/jchirayath/aws/master/s3/config/nginx.conf
#cp nginx.conf /etc/nginx/nginx.conf

# Get Updated nginx Index.htm from GitHub
wget https://raw.githubusercontent.com/jchirayath/aws/master/s3/config/usr-share-nginx-html-index.html 
cp usr-share-nginx-html-index.html /usr/share/nginx/html/index.html

# Install and configure Mail
apt-get -y install postfix mailutils

# Configure Postfix
debconf-set-selections <<< "postfix postfix/mailname string $HOSTNAME"
debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"
dpkg-reconfigure -f noninteractive postfix

# Start Postfix service
systemctl start postfix
systemctl enable postfix

# Install and run Lynis Security Scanner
apt-get -y install lynis
lynis audit system -Q --no-colors | mail -s "PEN test for Host $HOSTNAME" jacobjc@aspl.net
git clone https://github.com/CISOfy/lynis

# Install Certificate for Server
apt install python3-certbot-apache
apt install python3-certbot-nginx
certbot --apache -d axa.eastus2.cloudapp.azure.com --non-interactive --agree-tos -m jacobc@aspl.net
certbot --nginx -d axa.eastus2.cloudapp.azure.com --non-interactive --agree-tos -m jacobc@aspl.net
