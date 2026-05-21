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
    # Usar $uri (normalizado, con merge_slashes on) en lugar de $request_uri
    # para evitar que un cliente que mande "//" en el path lo propague tal cual
    # al Location del 301 (resultaba en "https://...duckdns.org//...").
    return 301 ${glpi_url}$uri$is_args$args;
}
NGINX_CONFIG

ln -sf /etc/nginx/sites-available/glpi /etc/nginx/sites-enabled/glpi
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl restart nginx

echo "[$(date)] === FIN ==="
