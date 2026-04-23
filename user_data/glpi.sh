#!/bin/bash

# =============================================================================
# GLPI Inventory Management System Setup
# =============================================================================
# Instala GLPI 10.0.18 con Apache2 y MariaDB en una instancia AWS.
# - BD: MariaDB local
# - Web: Apache2 en puerto 80
# - Acceso: vía Nginx reverse proxy en HTTPS
# =============================================================================

echo "[$(date)] === GLPI Setup Started ==="

# Configuración
GLPI_VERSION="10.0.18"
DB_NAME="glpi"
DB_USER="glpi"
DB_PASS="Gl1p!Dracs2025"

# Paso 1: Instalar dependencias
echo "[$(date)] Instalando dependencias..."
apt-get update
apt-get install -y \
  apache2 mariadb-server \
  php php-mysql php-curl php-gd php-xml php-mbstring php-intl php-zip \
  php-bz2 php-ldap php-xml php-soap php-apcu \
  curl wget unzip
echo "[✓] Dependencias instaladas"

# Paso 2: Configurar MariaDB
echo "[$(date)] Configurando MariaDB..."
systemctl enable mariadb
systemctl start mariadb

mysql -u root << SQL_SETUP
CREATE DATABASE IF NOT EXISTS ${DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL_SETUP

echo "[✓] MariaDB configurado"

# Paso 3: Descargar e instalar GLPI
echo "[$(date)] Descargando GLPI ${GLPI_VERSION}..."
cd /var/www/html
wget -q "https://github.com/glpi-project/glpi/releases/download/${GLPI_VERSION}/glpi-${GLPI_VERSION}.tgz"
tar -xzf glpi-${GLPI_VERSION}.tgz
rm glpi-${GLPI_VERSION}.tgz
chown -R www-data:www-data /var/www/html/glpi
echo "[✓] GLPI descargado e instalado"

# Paso 4: Configurar Apache2
echo "[$(date)] Configurando Apache2 para GLPI..."
cat > /etc/apache2/sites-available/glpi.conf << 'APACHE_CONFIG'
<VirtualHost *:80>
    DocumentRoot /var/www/html/glpi/public
    <Directory /var/www/html/glpi/public>
        AllowOverride All
        Options -Indexes +FollowSymLinks
        Require all granted
    </Directory>
    ErrorLog ${APACHE_LOG_DIR}/glpi_error.log
    CustomLog ${APACHE_LOG_DIR}/glpi_access.log combined
</VirtualHost>
APACHE_CONFIG

a2ensite glpi.conf
a2dissite 000-default.conf 2>/dev/null || true
a2enmod rewrite
systemctl enable apache2
systemctl restart apache2
echo "[✓] Apache2 configurado"

# Paso 5: Instalar GLPI (CLI)
echo "[$(date)] Instalando GLPI en BD..."
php /var/www/html/glpi/bin/console db:install \
  --db-host=localhost \
  --db-name="${DB_NAME}" \
  --db-user="${DB_USER}" \
  --db-password="${DB_PASS}" \
  --default-language=es_ES \
  --no-interaction 2>&1 | tail -5

# Remover archivo de instalación
rm -f /var/www/html/glpi/install/install.php
echo "[✓] GLPI instalado en BD"

# Verificación
echo "[$(date)] === Verificación final ==="
echo "Apache2 status:"
systemctl is-active apache2
echo "MariaDB status:"
systemctl is-active mariadb
echo "GLPI directory:"
ls -ld /var/www/html/glpi
echo "[✓] GLPI Setup Completed"

echo "[$(date)] === FIN ==="
echo ""
echo "GLPI está listo en http://localhost (vía Nginx reverse proxy en https://)"
echo "Credenciales default: admin/admin (CAMBIAR en primera login)"
