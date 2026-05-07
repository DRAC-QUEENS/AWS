#!/bin/bash

# =============================================================================
# Nginx Reverse Proxy Setup for GLPI
# =============================================================================
# Reverse proxy hacia el ALB del GLPI.
# - Trafico externo (internet): llega via NLB con IP fija
# - Trafico interno (WireGuard/Proxmox): llega a Nginx directamente (10.0.1.20)
# - ALB backend: ${alb_dns}  <- inyectado por Terraform en tiempo de despliegue
# =============================================================================

echo "[$(date)] === Nginx Reverse Proxy Setup Started ==="

ALB_DNS="${alb_dns}"

# Paso 1: Instalar Nginx
echo "[$(date)] Instalando Nginx..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx openssl
systemctl enable nginx
echo "[✓] Nginx instalado"

# Paso 2: Generar certificado SSL auto-firmado (para HTTPS desde VPN)
echo "[$(date)] Generando certificado SSL (auto-firmado)..."
mkdir -p /etc/nginx/ssl
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /etc/nginx/ssl/dracs.key \
  -out /etc/nginx/ssl/dracs.crt \
  -subj "/C=ES/O=Dracs/CN=dracs.local" 2>/dev/null
echo "[✓] Certificado creado"

# Paso 3: Configurar Nginx como reverse proxy hacia el ALB
echo "[$(date)] Configurando reverse proxy hacia ALB ($ALB_DNS)..."
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
        proxy_pass http://$ALB_DNS;
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
echo "[✓] Configuracion reverse proxy creada"

# Paso 4: Validar y arrancar Nginx
echo "[$(date)] Validando configuracion..."
nginx -t
systemctl restart nginx
echo "[✓] Nginx reiniciado"

echo "[$(date)] === Verificacion final ==="
systemctl is-active nginx
ss -tlnp | grep nginx
echo "[$(date)] === FIN ==="
