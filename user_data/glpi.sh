#!/bin/bash
apt update -y
apt upgrade -y
apt install -y apache2 mariadb-server php php-mysql php-curl php-gd php-xml php-mbstring unzip wget
systemctl enable apache2
systemctl start apache2
systemctl enable mariadb
systemctl start mariadb
echo "<h1>Servidor GLPI backend</h1>" > /var/www/html/index.html