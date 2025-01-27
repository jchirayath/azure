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

# ## Get the key vault name from azure
# echo "## Getting the Key Vault name from Azure"
# KEYVAULT_NAME=$(az keyvault list --query "[].name" -o tsv)

# Check if the key vault exists and retrive the MYSQL admin password
echo "## Checking if the Key Vault exists and retrieving the MYSQL admin password"
if ! az keyvault secret show --name mysqlAdminPassword --vault-name "$KEYVAULT_NAME"; then
    echo "Key Vault does not exist or MySQL admin password not found."
    exit 1
else
    # echo "## Getting the MYSQL admin password from the Key Vault"
    MYSQL_ADMIN_PASSWORD=$(az keyvault secret show --name mysqlAdminPassword --vault-name "$KEYVAULT_NAME" --query value -o tsv)
fi

# If the MYSQL admin password is empty, create a new password and store it in a local file in current directory
if [ -z "$MYSQL_ADMIN_PASSWORD" ]; then
    echo "MYSQL admin password not found in Key Vault. Creating a new password..."
    MYSQL_ADMIN_PASSWORD=$(openssl rand -base64 12)
    echo "MYSQL_ADMIN_PASSWORD=$MYSQL_ADMIN_PASSWORD" > /root/mysql_admin_password.txt
    echo "MYSQL admin password created and stored in mysql_admin_password.txt"
fi

# # Vault the MySQL admin password
# echo "Storing MySQL admin password in Azure Key Vault..."
# if ! az keyvault secret set --name mysqlAdminPassword --vault-name "$KEYVAULT_NAME" --value "$MYSQL_ADMIN_PASSWORD"; then
#     echo "Failed to store MySQL admin password in Azure Key Vault."
#     echo "Continuing with the installation..."
# fi

# Install MySQL if not already installed

# Check if MySQL server is already installed
echo "## Checking if MySQL server is already installed"
if dpkg-query -W -f='${Status}' mysql-server 2>/dev/null | grep -q "ok installed"; then
    echo "MySQL server is already installed."
else
    echo "MySQL server is not installed."
    # Install MySQL server
    echo "Installing MySQL server..."
    if sudo apt-get install mysql-server -y; then
        echo "MySQL server installation succeeded."
    else
        echo "MySQL server installation failed."
        exit 1
    fi  
fi

# check if mysql service is running
echo "## Checking if MySQL service is running"
if sudo systemctl is-active --quiet mysql; then
    echo "MySQL service is already running."
    # Restart MySQL service
    echo "Restarting MySQL service..."
    if sudo systemctl restart mysql; then
        echo "MySQL service restarted."
    else
        echo "Failed to restart MySQL service."
        exit 1
    fi
else
    echo "MySQL service is not running."
    # Start and enable MySQL service
    echo "Starting and enabling MySQL service..."
    if sudo systemctl start mysql && sudo systemctl enable mysql; then
        echo "MySQL service started and enabled."
    else
        echo "Failed to start and enable MySQL service."
        exit 1
    fi
fi

# Set the MySQL root password
echo "## Setting the MySQL root password"
if sudo mysql -u root -p"$MYSQL_ADMIN_PASSWORD" -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ADMIN_PASSWORD';"; then
    echo "MySQL root password set successfully."
else
    echo "Failed to set MySQL root password."
    exit 1
fi

# Test MySQL
echo "## Testing MySQL"
if sudo mysql -u root -p"$MYSQL_ADMIN_PASSWORD" -e "SHOW DATABASES;"; then
    echo "MySQL test succeeded."
else
    echo "MySQL test failed."
    exit 1
fi

# Complete MySQL installation
echo "MySQL installation completed successfully."
exit 0