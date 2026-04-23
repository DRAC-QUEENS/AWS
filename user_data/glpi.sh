#!/bin/bash
set -e

WAZUH_MANAGER="192.168.10.30"
ZABBIX_SERVER="192.168.10.20"
GLPI_VERSION="10.0.18"
DB_NAME="glpi"
DB_USER="glpi"
DB_PASS="Gl1p!Dracs2025"

apt-get update -y > /dev/null 2>&1
apt-get install -y \
  apache2 mariadb-server \
  php php-mysql php-curl php-gd php-xml php-mbstring php-intl php-zip \
  php-bz2 php-ldap php-xmlrpc php-soap php-apcu php-cas \
  curl wget gpg unzip > /dev/null 2>&1

# ── MariaDB ───────────────────────────────────────────────────────────────────
systemctl enable mariadb
systemctl start mariadb

mysql -u root << SQLSETUP
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQLSETUP

# ── GLPI ──────────────────────────────────────────────────────────────────────
wget -q "https://github.com/glpi-project/glpi/releases/download/${GLPI_VERSION}/glpi-${GLPI_VERSION}.tgz" \
  -O /tmp/glpi.tgz
tar -xzf /tmp/glpi.tgz -C /var/www/html/
chown -R www-data:www-data /var/www/html/glpi
rm /tmp/glpi.tgz

# ── Apache vhost ──────────────────────────────────────────────────────────────
cat > /etc/apache2/sites-available/glpi.conf << 'APACHECONF'
<VirtualHost *:80>
    DocumentRoot /var/www/html/glpi/public

    <Directory /var/www/html/glpi/public>
        AllowOverride All
        Options -Indexes +FollowSymLinks
        Require all granted
    </Directory>

    ErrorLog  ${APACHE_LOG_DIR}/glpi_error.log
    CustomLog ${APACHE_LOG_DIR}/glpi_access.log combined
</VirtualHost>
APACHECONF

a2ensite glpi.conf > /dev/null 2>&1
a2dissite 000-default.conf > /dev/null 2>&1
a2enmod rewrite > /dev/null 2>&1
systemctl enable apache2
systemctl restart apache2

# ── Instalación desatendida GLPI ──────────────────────────────────────────────
php /var/www/html/glpi/bin/console db:install \
  --db-host=localhost \
  --db-name="${DB_NAME}" \
  --db-user="${DB_USER}" \
  --db-password="${DB_PASS}" \
  --default-language=es_ES \
  --no-interaction > /dev/null 2>&1

# Elimina el fichero de instalación para prevenir reinstalación accidental
rm -f /var/www/html/glpi/install/install.php

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
