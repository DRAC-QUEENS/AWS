#!/bin/bash

# =============================================================================
# Nginx Reverse Proxy Setup for GLPI
# =============================================================================
# Configura Nginx como reverse proxy hacia GLPI (10.0.2.10).
# - HTTP:80 → redirige a HTTPS
# - HTTPS:443 → proxying a http://10.0.2.10:80
# - SSL: auto-firmado (reemplazar con Let's Encrypt en producción)
# =============================================================================

echo "[$(date)] === Nginx Reverse Proxy Setup Started ==="

# Paso 1: Instalar Nginx
echo "[$(date)] Instalando Nginx..."
apt-get update
apt-get install -y nginx openssl
systemctl enable nginx
echo "[✓] Nginx instalado"

# Paso 2: Generar certificado SSL auto-firmado
echo "[$(date)] Generando certificado SSL (auto-firmado)..."
mkdir -p /etc/nginx/ssl
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /etc/nginx/ssl/dracs.key \
  -out /etc/nginx/ssl/dracs.crt \
  -subj "/C=ES/O=Dracs/CN=dracs.local" 2>/dev/null
echo "[✓] Certificado creado"

# Paso 3: Configurar Nginx como reverse proxy
echo "[$(date)] Configurando reverse proxy..."
cat > /etc/nginx/sites-available/glpi << 'NGINX_CONFIG'
server {
    listen 80;
    server_name _;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2;
    server_name _;

    ssl_certificate /etc/nginx/ssl/dracs.crt;
    ssl_certificate_key /etc/nginx/ssl/dracs.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 100M;

    location / {
        proxy_pass http://10.0.2.10;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 120s;
    }
}
NGINX_CONFIG

ln -sf /etc/nginx/sites-available/glpi /etc/nginx/sites-enabled/glpi
rm -f /etc/nginx/sites-enabled/default

echo "[✓] Configuración reverse proxy creada"

# Paso 4: Validar y reiniciar Nginx
echo "[$(date)] Validando configuración..."
nginx -t
systemctl restart nginx
echo "[✓] Nginx reiniciado"

# Verificación
echo "[$(date)] === Verificación final ==="
echo "Nginx status:"
systemctl is-active nginx
echo "Puertos escuchando:"
netstat -tlnp 2>/dev/null | grep nginx || ss -tlnp 2>/dev/null | grep nginx
echo "[✓] Nginx Setup Completed"

echo "[$(date)] === FIN ==="
