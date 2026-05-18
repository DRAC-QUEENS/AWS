#!/bin/bash
set -e

GLPI_VERSION="10.0.18"
RDS_ENDPOINT="${rds_endpoint}"
DB_NAME="glpi"
DB_USER="glpi"
DB_PASS="${db_password}"
EFS_DNS="${efs_dns}"
GLPI_URL="${glpi_public_url}"

echo "[$(date)] === GLPI ASG Instance Setup Started ==="

# Paso 1: Montar EFS en /mnt/efs y crear subdirectorios si no existen
echo "[$(date)] Montando EFS..."
mkdir -p /mnt/efs
mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 \
  "$EFS_DNS:/" /mnt/efs
mkdir -p /mnt/efs/files /mnt/efs/plugins
chown www-data:www-data /mnt/efs/files /mnt/efs/plugins

grep -q "/mnt/efs" /etc/fstab || echo "$EFS_DNS:/ /mnt/efs nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,_netdev 0 0" >> /etc/fstab

# Pre-crear subdirectorios que GLPI espera encontrar ya existentes
for dir in _cache _cron _dumps _graphs _lock _log _maps _pictures _plugins _rss _sessions _tmp _uploads _meta/config; do
  mkdir -p "/mnt/efs/files/$dir"
done
chown -R www-data:www-data /mnt/efs/files /mnt/efs/plugins

# Enlazar los directorios EFS a las rutas que espera GLPI
rm -rf /var/www/html/glpi/files /var/www/html/glpi/plugins
ln -s /mnt/efs/files   /var/www/html/glpi/files
ln -s /mnt/efs/plugins /var/www/html/glpi/plugins
echo "[✓] EFS montado y symlinks creados"

# Certbot: instalar y restaurar cert desde EFS si existe
apt-get install -y certbot python3-certbot-dns-duckdns 2>/dev/null || true
if [ -d /mnt/efs/letsencrypt/live ]; then
  cp -a /mnt/efs/letsencrypt/. /etc/letsencrypt/
  echo "[✓] Certbot cert restaurado desde EFS"
else
  echo "[$(date)] Sin cert en EFS — se requiere emision manual con certbot"
fi

# Paso 2: Instalar paquetes si no están (en AMI Packer ya vienen instalados)
if ! command -v apache2 &>/dev/null; then
  echo "[$(date)] Instalando Apache, PHP y dependencias..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    apache2 nfs-common mariadb-client \
    php php-mysql php-curl php-gd php-intl php-ldap \
    php-mbstring php-xml php-xmlrpc php-zip php-bz2 php-imap php-apcu
  systemctl enable apache2
  echo "[✓] Paquetes instalados"
fi

# Paso 3: Descargar e instalar GLPI si no está (en AMI Packer ya viene instalado)
if [ ! -f /var/www/html/glpi/index.php ]; then
  echo "[$(date)] Descargando GLPI $GLPI_VERSION..."
  cd /tmp
  wget -q --timeout=60 --tries=3 \
    "https://github.com/glpi-project/glpi/releases/download/$GLPI_VERSION/glpi-$GLPI_VERSION.tgz"
  tar -xzf "glpi-$GLPI_VERSION.tgz" -C /var/www/html/
  chown -R www-data:www-data /var/www/html/glpi

  # VirtualHost Apache (el AMI Packer ya lo trae configurado)
  cat > /etc/apache2/sites-available/glpi.conf << 'APACHE_CONF'
<VirtualHost *:80>
    DocumentRoot /var/www/html/glpi
    <Directory /var/www/html/glpi>
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
  echo "[✓] GLPI instalado"
fi

# Paso 4: config_db.php — se sobreescribe en cada arranque para garantizar que apunta al RDS correcto
mkdir -p /var/www/html/glpi/config
cat > /var/www/html/glpi/config/config_db.php << 'EOF'
<?php
class DB extends DBmysql {
   public $dbhost     = '${rds_endpoint}';
   public $dbuser     = 'glpi';
   public $dbpassword = '${db_password}';
   public $dbdefault  = 'glpi';
}
EOF
chown www-data:www-data /var/www/html/glpi/config/config_db.php
echo "[✓] config_db.php configurado"

# Paso 5: glpicrypt.key — clave de cifrado de GLPI para datos sensibles en BD.
# GLPI cifra las contraseñas de integraciones (LDAP, SMTP, etc.) con esta clave.
# Si se destruye y recrea la instancia sin restaurar la clave, GLPI no puede
# descifrar esos datos y las integraciones dejan de funcionar.
# Tras la primera configuracion de integraciones, copiar manualmente a EFS:
#   cp /var/www/html/glpi/config/glpicrypt.key /mnt/efs/files/_meta/config/
if [ -f /mnt/efs/files/_meta/config/glpicrypt.key ]; then
  cp /mnt/efs/files/_meta/config/glpicrypt.key /var/www/html/glpi/config/glpicrypt.key
  chown www-data:www-data /var/www/html/glpi/config/glpicrypt.key
  echo "[✓] glpicrypt.key restaurada desde EFS"
fi

# Paso 6: Inicializar BD solo si esta vacia.
# flock: candado en EFS compartido entre instancias del ASG. Evita el race condition
# en el que dos instancias detectan la BD vacia a la vez y ambas intentan ejecutar
# db:install simultaneamente, lo que corrompe las tablas. La segunda instancia espera
# a que la primera termine; cuando adquiere el lock, la BD ya tiene tablas y no instala.
echo "[$(date)] Comprobando estado de la BD..."
exec 9>/mnt/efs/files/.db-init.lock
flock -x 9

DB_EXISTS=$(mysql -h "$RDS_ENDPOINT" -u "$DB_USER" -p"$DB_PASS" \
  -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_NAME';" \
  2>/dev/null | tail -1 || echo "")

if [ "$DB_EXISTS" = "0" ] || [ -z "$DB_EXISTS" ]; then
  echo "[$(date)] Inicializando BD GLPI en RDS..."
  php /var/www/html/glpi/bin/console db:install \
    --db-host="$RDS_ENDPOINT" \
    --db-name="$DB_NAME" \
    --db-user="$DB_USER" \
    --db-password="$DB_PASS" \
    --no-interaction

  # db:install no acepta --url; se fija via SQL justo despues de la instalacion
  mysql -h "$RDS_ENDPOINT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
    UPDATE glpi_configs SET value = '$GLPI_URL' WHERE name = 'url_base';
    UPDATE glpi_configs SET value = '$GLPI_URL/apirest.php/' WHERE name = 'url_base_api';
  " 2>/dev/null
  echo "[✓] BD inicializada, url_base=$GLPI_URL"
else
  echo "[✓] BD ya existente ($DB_EXISTS tablas)"
fi

flock -u 9

# Paso 7: VirtualHost Apache — se sobreescribe siempre para garantizar RewriteRule
# (cubre tanto instalaciones frescas como instancias desde AMI Packer)
cat > /etc/apache2/sites-available/glpi.conf << 'APACHE_CONF'
<VirtualHost *:80>
    DocumentRoot /var/www/html/glpi

    RewriteEngine On
    RewriteRule ^/glpi(/.*)?$ /$1 [R=301,L]

    <Directory /var/www/html/glpi>
        Options FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    ErrorLog /var/log/apache2/glpi_error.log
    CustomLog /var/log/apache2/glpi_access.log combined
</VirtualHost>
APACHE_CONF
a2ensite glpi.conf 2>/dev/null || true
a2dissite 000-default.conf 2>/dev/null || true
a2enmod rewrite
echo "[✓] VirtualHost Apache actualizado"

# Paso 8: Arrancar Apache
systemctl restart apache2
echo "[✓] Apache arrancado"

echo "[$(date)] === FIN ==="
