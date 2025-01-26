#!/bin/bash
# Function to install MySQL
function install_mysql() {
    echo "Installing MySQL..."
    sudo apt-get install mysql-server -y
}
install_mysql

# Get MySQL username and password from Azure Key Vault
echo "Retrieving MySQL credentials from Azure Key Vault..."
MYSQL_USERNAME=$(az keyvault secret show --name MySQLUsername --vault-name YourKeyVaultName --query value -o tsv)
MYSQL_ADMIN_PASSWORD=$(az keyvault secret show --name MySQLPassword --vault-name YourKeyVaultName --query value -o tsv)

# Test MySQL
echo "## Testing MySQL"
if sudo mysql -u root -p"$myMYSQL_ADMIN_PASSWORD" -e "SHOW DATABASES;"; then
    echo "MySQL test succeeded."
else
    echo "MySQL test failed."
fi