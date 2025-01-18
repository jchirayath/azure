#!/bin/bash
# Function to install MySQL
function install_mysql() {
    echo "Installing MySQL..."
    sudo apt-get install mysql-server -y
}
install_mysql
