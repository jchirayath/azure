#!/bin/bash
# touch File
touch /JacobWasHere
# Update APT repository
apt-get -y update
# Install Software
apt-get -y install docker docker.io
apt-get -y install apache2
apt-get -y install php
apt-get -y install php-mysql
apt-get -y install mysql
#apt-get -y install nginx
#apt-get -y install privoxy
apt-get -y install sssd adcli realmd samba-common
#apt-get -y install sssd realmd adcli krb5-workstation samba-common
apt-get -y install expect unzip nmap nfs-utils rsync screen diffutils lsof 
apt-get -y install tcpdump telnet nc traceroute wget perl curl

# Start Docker Service
sudo service docker start

# Define VARIABLES
myHOST=“yumaweb.westus.cloudapp.azure.com”
myMyuSQLHOST=“den1.mysql6.gear.host”
myUser=“guacamoledb”
myPassword=“Of022_E5KvL-”

# Guacamole Install
docker run --name some-guacd -d guacamole/guacd
# Install Start Docker
docker run --name some-guacamole --link some-guacd:guacd \
    -e MYSQL_HOSTNAME=den1.mysql6.gear.host \
    -e MYSQL_DATABASE=guacamoledb  \
    -e MYSQL_USER=guacamoledb    \
    -e MYSQL_PASSWORD=Of022_E5KvL- \
    -d -p 8080:8080 guacamole/guacamole

# Fix Guacamole Tomcat Configuration
# Get Tomcat Config and Update
wget https://raw.githubusercontent.com/jchirayath/azure/master/VMCreate/tomcat-users.xml
docker cp tomcat-users.xml some-guacamole:/usr/local/tomcat/conf/tomcat-users.xml 
docker restart some-guacamole 

# Get Updated Index.htm
wget https://raw.githubusercontent.com/jchirayath/azure/master/VMCreate/index.html
cp index.html /var/www/html/index.html

# Install and configure Mail
#debconf-set-selections <<< "postfix postfix/mailname string $HOSTNAME"
#debconf-set-selections <<< "postfix postfix/main_mailer_type string 'Internet Site'"
echo "postfix postfix/mailname string $HOSTNAME" | debconf-set-selections
echo "postfix postfix/main_mailer_type string 'Internet Site'" | debconf-set-selections 
apt-get -y install mailutils

# Install and run Lynis Security Scanner
git clone https://github.com/CISOfy/lynis
cd lynis; ./lynis audit system -Q --no-colors | mail -s "PEN test for Host $HOSTNAME" jacobjc@hotmail.com

# Fix SSH Port 443
cat << EOF >> /etc/ssh/sshd_config
Port 22
Port 443
EOF
service ssh restart

# Install XRDP
apt-get -y install xrdp
echo encrypt_level=high >> /etc/xrdp/xrdp.ini
ufw allow 3389/tcp
service xrdp restart

# Install fail2ban
apt-get -y install fail2ban
#sed -i 's/# bantime/bantime/g' /etc/fail2ban/jail.conf
service fail2ban restart 

# END of SCRIPT
