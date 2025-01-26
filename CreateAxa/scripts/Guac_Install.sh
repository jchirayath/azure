#!/bin/bash

# Define VARIABLES
myMySQLHOST="den1.mysql6.gear.host"
myMySQLUSER="guacamoledb"
myMySQLPASS="Of022_E5KvL-"

# export myMySQLHOST="den1.mysql6.gear.host"
# export myMySQLUSER="guacamoledb"
# export myMySQLPASS="Of022_E5KvL-"

# Generate a new password for the Tomcat Manager
echo "## Generating a new password for the Tomcat Manager"
TOMCAT_MANAGER_PASSWORD=$(openssl rand -base64 32)
echo "Tomcat Manager Password: $TOMCAT_MANAGER_PASSWORD"
echo "Storing the Tomcat Manager Password in a file"
echo "Tomcat Manager Password: $TOMCAT_MANAGER_PASSWORD" > tomcat_manager_password.txt

# Guacamole Install and run Guacd Daemon
echo "## Installing and configuring Guacamole using Docker"
sudo docker run --name some-guacd -d guacamole/guacd
sudo docker run --name some-guacamole --link some-guacd:guacd \
    -e MYSQL_HOSTNAME="$myMySQLHOST" \
    -e MYSQL_DATABASE=guacamoledb  \
    -e MYSQL_USER="$myMySQLUSER"    \
    -e MYSQL_PASSWORD="$myMySQLPASS" \
    -d -p 8080:8080 guacamole/guacamole

## Dump the guacamole database for initialization
echo "## Dumping the guacamole database for initialization"
sudo docker exec -it some-guacamole /opt/guacamole/bin/initdb.sh --mysql > initdb.sql

## Use the dump file to configure the guacamole database
echo "## Configuring the guacamole database - NEW"
mysql -h $myMySQLHOST -u $myMySQLUSER -p$myMySQLPASS guacamoledb < initdb.sql

# # Update the mysql database guacmole user and password with new password
# echo "## Updating the guacamole user password in the database"
# mysql -h $myMySQLHOST -u $myMySQLUSER -p$myMySQLPASS guacamoledb -e "UPDATE guacamole_user SET password_hash = SHA2(CONCAT(password_salt, 'newpassword'), 256) WHERE user_id = 1;"

# Restart the Guacamole container
sudo docker restart some-guacamole

## Test Guacamole
echo "## Testing connection to guacamole server"
curl http://localhost:8080/guacamole/
