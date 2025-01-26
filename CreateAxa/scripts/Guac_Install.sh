#!/bin/bash

# Log in to Azure with identity
echo "## Logging in to Azure with identity"
for i in {1..3}; do
    if az login --identity; then
        echo "Successfully logged in to Azure."
        break
    else
        echo "Failed to log in to Azure. Attempt $i of 3."
        if [ $i -eq 3 ]; then
            echo "Exceeded maximum login attempts. Exiting."
            exit 1
        fi
        sleep 5
    fi
done

# Get the VM region from azure
echo "## Getting the VM region from Azure"
az keyvault list --query "[].name" -o tsv

# get vm name from azure
echo "## Getting the VM name from Azure"    
VM_HOST=$(az vm list --query "[].name" -o tsv)

# Get the VM region from azure
echo "## Getting the VM region from Azure"
VM_REGION=$(az vm list --query "[].location" -o tsv | head -n 1)

# Set Key Vault Name
KEYVAULT_NAME="kv-$VM_HOST-$VM_REGION"

# Check if the key vault exists and retrive the guacamoleHost
echo "## Checking if the Key Vault exists and retrieving the MYSQL admin password"
if ! az keyvault secret show --name guacamoleHost --vault-name "$KEYVAULT_NAME"; then
    echo "Key Vault does not exist or MySQL admin password not found."
    exit 1
else
    # echo "## Getting the guacamoleHost the Key Vault"
    myMySQLHOST=$(az keyvault secret show --name guacamoleHost --vault-name "$KEYVAULT_NAME" --query value -o tsv)
    # echo "## Getting the guacamoleUser the Key Vault"
    myMySQLUSER=$(az keyvault secret show --name guacamoleUser --vault-name "$KEYVAULT_NAME" --query value -o tsv)
    # echo "## Getting the guacamolePassword the Key Vault"
    myMySQLPASS=$(az keyvault secret show --name guacamolePassword --vault-name "$KEYVAULT_NAME" --query value -o tsv)
fi

# If the myMySQLHOST is empty set the value to default
if [ -z "$myMySQLHOST" ]; then
    echo "myMySQLHOST not found in Key Vault. Setting to default value..."
    myMySQLHOST="den1.mysql6.gear.host"
fi
# If the myMySQLUSER is empty set the value to default
if [ -z "$myMySQLUSER" ]; then
    echo "myMySQLUSER not found in Key Vault. Setting to default value..."
    myMySQLUSER="guacamoledb"
fi
# If the myMySQLPASS is empty set the value to default
if [ -z "$myMySQLPASS" ]; then
    echo "myMySQLPASS not found in Key Vault. Setting to default value..."
    myMySQLPASS="Of022_E5KvL-"
fi

# Check if the Guacamole container is already running
echo "## Checking if the Guacamole container is already running"
if sudo docker ps -a --format '{{.Names}}' | grep -Eq "^some-guacamole$"; then
    echo "Guacamole container is already running. Stopping and removing the container."
    sudo docker stop some-guacamole
    sudo docker rm some-guacamole
fi

# Check if the Guacd container is already running
echo "## Checking if the Guacd container is already running"
if sudo docker ps -a --format '{{.Names}}' | grep -Eq "^some-guacd$"; then
    echo "Guacd container is already running. Stopping and removing the container."
    sudo docker stop some-guacd
    sudo docker rm some-guacd
fi

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
sudo docker exec some-guacamole /opt/guacamole/bin/initdb.sh --mysql > initdb.sql

# ## Use the dump file to configure the guacamole database
# echo "## Configuring the guacamole database - NEW"
# mysql -h $myMySQLHOST -u $myMySQLUSER -p$myMySQLPASS guacamoledb < initdb.sql

# Restart the Guacamole container
echo "## Restarting the Guacamole container"
sudo docker restart some-guacamole

# Wait for the Guacamole container to start
echo "## Waiting for the Guacamole container to start"
sleep 10

## Test Guacamole
echo "## Testing connection to guacamole server"
response=$(curl --write-out "%{http_code}" --silent --output /dev/null http://localhost:8080/guacamole/)

if [ "$response" -eq 200 ]; then
    echo "Guacamole server is up and running."
else
    echo "Failed to connect to Guacamole server. HTTP status code: $response"
fi

# Finish the script
echo "## Guacamole Installation - Done"

