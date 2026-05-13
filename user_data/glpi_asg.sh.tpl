#!/bin/bash
set -e

# =============================================================================
# GLPI ASG Instance Setup
# =============================================================================
# Configura cada instancia del Auto Scaling Group del GLPI.
# - MariaDB NO se instala localmente (BD en RDS: ${rds_endpoint})
# - /var/www/html/glpi/files/ se comparte via EFS (${efs_dns})
# - La BD se inicializa solo en la primera instancia; las siguientes
#   detectan que ya existe y solo configuran el config_db.php
# =============================================================================

echo "[$(date)] === GLPI ASG Instance Setup Started ==="

GLPI_VERSION="10.0.18"
RDS_ENDPOINT="${rds_endpoint}"
DB_NAME="glpi"
DB_USER="glpi"
DB_PASS="${db_password}"
EFS_DNS="${efs_dns}"

# Paso 1: Instalar Apache, PHP y cliente MariaDB (sin servidor de BD)
echo "[$(date)] Instalando Apache, PHP y dependencias..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  apache2 nfs-common mariadb-client \
  php php-mysql php-curl php-gd php-intl php-ldap \
  php-mbstring php-xml php-xmlrpc php-zip php-bz2 php-imap php-apcu
systemctl enable apache2
echo "[✓] Apache y PHP instalados"

# Paso 2: Montar EFS para ficheros compartidos (uploads, logs, sesiones)
echo "[$(date)] Montando EFS ($EFS_DNS)..."
mkdir -p /var/www/html/glpi/files
mount -t nfs4 -o nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2 \
  "$EFS_DNS:/" /var/www/html/glpi/files

# Persistir el mount entre reinicios (idempotente: solo si no esta ya en fstab)
grep -q "glpi/files" /etc/fstab || echo "$EFS_DNS:/ /var/www/html/glpi/files nfs4 nfsvers=4.1,rsize=1048576,wsize=1048576,hard,timeo=600,retrans=2,_netdev 0 0" >> /etc/fstab

# El mount resetea la propiedad del directorio; restaurar para que Apache escriba
chown www-data:www-data /var/www/html/glpi/files
echo "[✓] EFS montado en /var/www/html/glpi/files"

# Paso 3: Descargar e instalar GLPI si no existe ya
if [ ! -f /var/www/html/glpi/index.php ]; then
  echo "[$(date)] Descargando GLPI $GLPI_VERSION..."
  cd /tmp
  wget -q --timeout=60 --tries=3 \
    "https://github.com/glpi-project/glpi/releases/download/$GLPI_VERSION/glpi-$GLPI_VERSION.tgz"
  tar -xzf "glpi-$GLPI_VERSION.tgz" -C /var/www/html/
  chown -R www-data:www-data /var/www/html/glpi
  chmod -R 755 /var/www/html/glpi
  echo "[✓] GLPI extraido"
fi

# Paso 4: Configurar config_db.php apuntando a RDS
# Se sobreescribe en cada arranque para garantizar que apunta al RDS correcto
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
echo "[✓] config_db.php configurado (BD: $RDS_ENDPOINT)"

# Paso 4b: Recuperar glpicrypt.key desde EFS si existe (poblado durante migracion).
# Imprescindible cuando se migra una BD GLPI desde otra cuenta/version: GLPI cifra
# datos sensibles (LDAP, mail, etc.) con esta clave y sin ella db:update aborta.
if [ -f /var/www/html/glpi/files/_meta/config/glpicrypt.key ]; then
  cp /var/www/html/glpi/files/_meta/config/glpicrypt.key /var/www/html/glpi/config/glpicrypt.key
  chown www-data:www-data /var/www/html/glpi/config/glpicrypt.key
  echo "[✓] glpicrypt.key restaurada desde EFS"
fi

# Paso 5: Inicializar BD solo si las tablas no existen aun.
# Lock en EFS (compartido entre instancias del ASG) para evitar race condition
# si dos instancias arrancan a la vez y ambas intentan db:install.
echo "[$(date)] Comprobando estado de la BD (con lock en EFS)..."
exec 9>/var/www/html/glpi/files/.db-init.lock
flock -x 9

# || echo "" tolera fallos de conexion al RDS (puede no estar listo aun)
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
  echo "[✓] BD inicializada"
else
  echo "[✓] BD ya existente ($DB_EXISTS tablas); ejecutando db:update por si el schema es de version anterior..."
  php /var/www/html/glpi/bin/console db:update --no-interaction --force || \
    echo "[!] db:update fallo o no era necesario, continuando"
  echo "[✓] Schema BD verificado/actualizado"
fi

flock -u 9

# Paso 5b: Forzar url_base/url_base_api en BD. Es idempotente y evita que
# herencia de un dump migrado (donde apuntaba al hostname/path viejo)
# rompa los redirects post-login con 404 en /glpi.
mysql -h "$RDS_ENDPOINT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "
  UPDATE glpi_configs SET value = '${glpi_public_url}' WHERE name = 'url_base';
  UPDATE glpi_configs SET value = '${glpi_public_url}/apirest.php/' WHERE name = 'url_base_api';
" 2>/dev/null && echo "[✓] url_base fijado a ${glpi_public_url}"

# Paso 6: VirtualHost Apache
echo "[$(date)] Configurando Apache VirtualHost..."
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
systemctl restart apache2
echo "[✓] Apache configurado"

echo "[$(date)] === FIN ==="
