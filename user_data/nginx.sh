#!/bin/bash
set -e

GLPI_BACKEND="10.0.2.10"
WAZUH_MANAGER="192.168.10.30"
ZABBIX_SERVER="192.168.10.20"

apt-get update -y > /dev/null 2>&1
apt-get install -y nginx openssl curl wget gpg > /dev/null 2>&1

# ── SSL auto-firmado (reemplazar con Let's Encrypt en producción) ─────────────
mkdir -p /etc/nginx/ssl
openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
  -keyout /etc/nginx/ssl/dracs.key \
  -out    /etc/nginx/ssl/dracs.crt \
  -subj "/C=ES/O=Dracs/CN=dracs-glpi" 2>/dev/null

# ── Configuración Nginx reverse proxy para GLPI ───────────────────────────────
cat > /etc/nginx/sites-available/glpi << 'NGINXCONF'
server {
    listen 80;
    server_name _;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name _;

    ssl_certificate     /etc/nginx/ssl/dracs.crt;
    ssl_certificate_key /etc/nginx/ssl/dracs.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    client_max_body_size 100M;

    location / {
        proxy_pass         http://GLPI_BACKEND_PLACEHOLDER;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 120s;
        proxy_connect_timeout 10s;
    }
}
NGINXCONF

sed -i "s|GLPI_BACKEND_PLACEHOLDER|${GLPI_BACKEND}|g" /etc/nginx/sites-available/glpi

ln -sf /etc/nginx/sites-available/glpi /etc/nginx/sites-enabled/glpi
rm -f /etc/nginx/sites-enabled/default

nginx -t
systemctl enable nginx
systemctl restart nginx

# ── Zabbix Agent 2 ────────────────────────────────────────────────────────────
wget -q https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest+ubuntu24.04_all.deb -O /tmp/zabbix-release.deb
dpkg -i /tmp/zabbix-release.deb > /dev/null 2>&1
apt-get update -y > /dev/null 2>&1
apt-get install -y zabbix-agent2 > /dev/null 2>&1

HOSTNAME=$(hostname)
cat > /etc/zabbix/zabbix_agent2.conf << ZBXCONF
Server=${ZABBIX_SERVER}
ServerActive=${ZABBIX_SERVER}
Hostname=${HOSTNAME}
LogFile=/var/log/zabbix/zabbix_agent2.log
LogFileSize=10
PidFile=/run/zabbix/zabbix_agent2.pid
SocketDir=/run/zabbix
ZBXCONF

systemctl enable zabbix-agent2
systemctl start zabbix-agent2

# ── Wazuh Agent ───────────────────────────────────────────────────────────────
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
  > /etc/apt/sources.list.d/wazuh.list
apt-get update -y > /dev/null 2>&1
WAZUH_MANAGER="${WAZUH_MANAGER}" apt-get install -y wazuh-agent > /dev/null 2>&1

sed -i "s|<address>.*</address>|<address>${WAZUH_MANAGER}</address>|" /var/ossec/etc/ossec.conf
sed -i "s|<protocol>.*</protocol>|<protocol>tcp</protocol>|" /var/ossec/etc/ossec.conf

systemctl daemon-reload
systemctl enable wazuh-agent
systemctl start wazuh-agent
