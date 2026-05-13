#!/bin/bash
set -e

# =============================================================================
# Nginx Reverse Proxy Setup for GLPI (versión simple)
# =============================================================================
# Reverse proxy directo hacia la instancia GLPI (sin ALB).
# - Trafico externo (internet): llega a la EIP de este Nginx
# - Trafico interno (WireGuard/on-prem): llega a Nginx directamente (10.0.1.20)
# - Backend: ${glpi_ip}  <- IP privada de la instancia GLPI, inyectada por Terraform
# =============================================================================

echo "[$(date)] === Nginx Reverse Proxy Setup Started ==="

GLPI_IP="${glpi_ip}"

# Paso 1: Instalar Nginx
echo "[$(date)] Instalando Nginx..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx openssl
systemctl enable nginx
echo "[OK] Nginx instalado"

# Paso 2: Generar certificado SSL auto-firmado (para HTTPS desde VPN)
mkdir -p /etc/nginx/ssl
if [ ! -f /etc/nginx/ssl/dracs.crt ]; then
  echo "[$(date)] Generando certificado SSL (auto-firmado)..."
  openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
    -keyout /etc/nginx/ssl/dracs.key \
    -out /etc/nginx/ssl/dracs.crt \
    -subj "/C=ES/O=Dracs/CN=dracs.local" 2>/dev/null
  echo "[OK] Certificado creado"
else
  echo "[OK] Certificado ya existe, saltando"
fi

# Paso 3: Configurar Nginx como reverse proxy hacia la instancia GLPI
echo "[$(date)] Configurando reverse proxy hacia GLPI ($GLPI_IP)..."
cat > /etc/nginx/sites-available/glpi << NGINX_CONFIG
server {
    listen 80;
    server_name _;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name _;

    ssl_certificate /etc/nginx/ssl/dracs.crt;
    ssl_certificate_key /etc/nginx/ssl/dracs.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 100M;

    location / {
        proxy_pass http://$GLPI_IP;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
    }
}
NGINX_CONFIG

ln -sf /etc/nginx/sites-available/glpi /etc/nginx/sites-enabled/glpi
rm -f /etc/nginx/sites-enabled/default
echo "[OK] Configuracion reverse proxy creada"

# Paso 4: Validar y arrancar Nginx
echo "[$(date)] Validando configuracion..."
nginx -t
systemctl restart nginx
echo "[OK] Nginx reiniciado"

echo "[$(date)] === Verificacion final ==="
systemctl is-active nginx
ss -tlnp | grep nginx
echo "[$(date)] === FIN ==="
