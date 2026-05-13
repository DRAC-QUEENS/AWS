#!/bin/bash
set -e

# =============================================================================
# GLPI Setup con MariaDB local (versión simple)
# =============================================================================
# Todo en una sola instancia: Apache + PHP + MariaDB + GLPI.
# Sin EFS, sin RDS, sin ASG. Los datos quedan en el disco local de la instancia.
#
# Para no perder datos entre despliegues, hacer snapshot de esta instancia
# antes de un `terraform destroy` (o usar el flag create_ami_backup del repo).
# =============================================================================

echo "[$(date)] === GLPI Setup Started ==="

GLPI_VERSION="10.0.18"
DB_NAME="glpi"
DB_USER="glpi"
DB_PASS="${db_password}"

# Paso 1: Instalar Apache, PHP y MariaDB server
echo "[$(date)] Instalando Apache, PHP y MariaDB..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  apache2 mariadb-server \
  php php-mysql php-curl php-gd php-intl php-ldap \
  php-mbstring php-xml php-xmlrpc php-zip php-bz2 php-imap php-apcu
systemctl enable apache2
systemctl enable mariadb
echo "[OK] Paquetes instalados"

# Paso 2: Configurar MariaDB
echo "[$(date)] Configurando MariaDB..."
systemctl start mariadb

# Crear BD y usuario solo si no existen (idempotente)
mysql -u root << SQL
CREATE DATABASE IF NOT EXISTS $DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
echo "[OK] BD y usuario GLPI creados"

# Paso 3: Descargar e instalar GLPI
if [ ! -f /var/www/html/glpi/index.php ]; then
  echo "[$(date)] Descargando GLPI $GLPI_VERSION..."
  cd /tmp
  wget -q --timeout=60 --tries=3 \
    "https://github.com/glpi-project/glpi/releases/download/$GLPI_VERSION/glpi-$GLPI_VERSION.tgz"
  tar -xzf "glpi-$GLPI_VERSION.tgz" -C /var/www/html/
  chown -R www-data:www-data /var/www/html/glpi
  chmod -R 755 /var/www/html/glpi
  echo "[OK] GLPI extraido en /var/www/html/glpi"
fi

# Paso 4: Crear config_db.php apuntando a localhost
mkdir -p /var/www/html/glpi/config
cat > /var/www/html/glpi/config/config_db.php << 'EOF'
<?php
class DB extends DBmysql {
   public $dbhost     = 'localhost';
   public $dbuser     = 'glpi';
   public $dbpassword = '${db_password}';
   public $dbdefault  = 'glpi';
}
EOF
chown www-data:www-data /var/www/html/glpi/config/config_db.php
echo "[OK] config_db.php configurado"

# Paso 5: Inicializar la BD si las tablas no existen aun
echo "[$(date)] Comprobando estado de la BD..."
TABLE_COUNT=$(mysql -u "$DB_USER" -p"$DB_PASS" \
  -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME';" \
  2>/dev/null | tail -1)

if [ "$TABLE_COUNT" = "0" ] || [ -z "$TABLE_COUNT" ]; then
  echo "[$(date)] Inicializando BD GLPI..."
  php /var/www/html/glpi/bin/console db:install \
    --db-host=localhost \
    --db-name="$DB_NAME" \
    --db-user="$DB_USER" \
    --db-password="$DB_PASS" \
    --no-interaction
  echo "[OK] BD inicializada"
else
  echo "[OK] BD ya existente ($TABLE_COUNT tablas), saltando inicializacion"
fi

# Paso 6: VirtualHost Apache
echo "[$(date)] Configurando Apache VirtualHost..."
cat > /etc/apache2/sites-available/glpi.conf << 'APACHE_CONF'
<VirtualHost *:80>
    DocumentRoot /var/www/html/glpi/public

    <Directory /var/www/html/glpi/public>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog /var/log/apache2/glpi_error.log
    CustomLog /var/log/apache2/glpi_access.log combined
</VirtualHost>
APACHE_CONF

a2ensite glpi.conf
a2dissite 000-default.conf
a2enmod rewrite
systemctl restart apache2
echo "[OK] Apache configurado"

echo "[$(date)] === FIN ==="
echo "[$(date)] GLPI disponible en http://$(hostname -I | awk '{print $1}')/glpi/"
echo "[$(date)] Login inicial: glpi / glpi  (cambiar en primer acceso)"
