#!/bin/bash
apt update -y
apt upgrade -y
apt install -y nginx
systemctl enable nginx
systemctl start nginx
echo "<h1>Nginx Reverse Proxy DRACS</h1>" > /var/www/html/index.html