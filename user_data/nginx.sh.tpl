#!/bin/bash
set -e

echo "[$(date)] === Nginx Setup Started ==="

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx
systemctl enable nginx

cat > /etc/nginx/sites-available/glpi << 'NGINX_CONFIG'
server {
    listen 80;
    server_name _;
    return 301 ${glpi_url}$request_uri;
}
NGINX_CONFIG

ln -sf /etc/nginx/sites-available/glpi /etc/nginx/sites-enabled/glpi
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl restart nginx

echo "[$(date)] === FIN ==="
