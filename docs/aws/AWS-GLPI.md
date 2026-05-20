# Stack GLPI (Compute + Datos)

El backend de GLPI se compone de un Auto Scaling Group (compute efímero), una base de datos RDS MariaDB (estado persistente) y un EFS compartido (ficheros y metadata). Las instancias del ASG se lanzan desde un Launch Template con Ubuntu vanilla y se configuran por completo en cada arranque mediante un `user_data` idempotente. La separación compute/datos permite sustituir instancias sin perder información.

> **Nota:** este stack sustituyó a una versión anterior en la que GLPI corría como **una sola EC2** con MariaDB y ficheros en disco local. Esa versión sigue documentada en `AWS-SIMPLE.md` y el código vive en el folder `simple/` del repo. La comparación entre ambas explica por qué se introdujeron RDS, EFS y el ASG.

# 1. Launch Template

---

El Launch Template (`lt-glpi-dracs-...`) define cómo se fabrica cada instancia del ASG. Por defecto usa una AMI Packer (`var.glpi_ami_id`) con Ubuntu 24.04 + Apache + PHP 8.3 + GLPI 10.0.18 pre-instalados, que reduce el tiempo de arranque de ~10 min a ~2 min. Si la variable está vacía, el Launch Template cae a Ubuntu 24.04 LTS vanilla y el `user_data` instala todo desde cero como fallback.

| Atributo | Valor |
| --- | --- |
| AMI | `var.glpi_ami_id != "" ? var.glpi_ami_id : data.aws_ami.ubuntu.id` (Packer o Ubuntu 24.04 LTS latest) |
| Tipo | `t3.small` |
| Key pair | `var.key_name` (en producción `dracs2`) |
| Security Group | `glpi-dracs` |
| IAM profile | `LabInstanceProfile` (habilita SSM Session Manager y acceso ACM para importar certs) |
| Block device | `/dev/sda1` 20 GB gp3, encrypted |
| User data | `templatefile("user_data/glpi_asg.sh.tpl", { rds_endpoint, db_password, efs_dns, glpi_public_url })` |

> **Nota:** la AMI Packer se construye con la plantilla `packer/glpi.pkr.hcl` y hay que regenerarla cada vez que se actualice GLPI o las dependencias. El `user_data` es idempotente, así que la AMI no tiene que estar exactamente al día (los pasos extra se ejecutarán en el primer boot si hace falta).

# 2. user_data idempotente

---

El script se ejecuta en el primer boot de cada instancia. Es completamente idempotente: las operaciones se pueden repetir sin romper nada (lo cual es vital porque el ASG puede sustituir instancias en cualquier momento).

**Pasos que ejecuta:**

1. **Monta EFS en `/mnt/efs`** — ejecuta `mount -t nfs4 -o nfsvers=4.1,...` apuntando al DNS del EFS, pre-crea los subdirectorios que GLPI espera (`_cache`, `_cron`, `_dumps`, `_log`, `_lock`, `_sessions`, etc.) y persiste el mount en `/etc/fstab` (idempotente con `grep -q || echo`). Después crea symlinks `glpi/files → /mnt/efs/files` y `glpi/plugins → /mnt/efs/plugins` para que GLPI no note la diferencia.

2. **Instala certbot y restaura el cert desde EFS** — `apt-get install -y certbot python3-certbot-dns-duckdns`. Si `/mnt/efs/letsencrypt/live/` existe, copia los ficheros a `/etc/letsencrypt`. Esto garantiza que cada instancia nueva del ASG tenga el certificado disponible sin intervención manual; el cert se guarda manualmente en EFS la primera vez que se emite.

3. **Instala dependencias (sólo si no están)** — `apache2`, `nfs-common`, `mariadb-client`, todas las extensiones PHP de GLPI (`php-mysql`, `php-curl`, `php-gd`, `php-intl`, `php-ldap`, `php-mbstring`, etc.). En instancias basadas en la AMI Packer este paso se salta.

4. **Descarga GLPI (sólo si no está)** — `glpi-10.0.18.tgz` desde GitHub. En la AMI Packer ya viene incluido, así que este paso se salta.

5. **Escribe `config_db.php`** — con el endpoint RDS, usuario y contraseña inyectados desde Terraform. Se reescribe en cada arranque para garantizar que apunta al RDS correcto.

6. **Restaura `glpicrypt.key` desde EFS** — si `/mnt/efs/files/_meta/config/glpicrypt.key` existe, lo copia a `/var/www/html/glpi/config/glpicrypt.key`. Sin esta clave GLPI no puede descifrar las contraseñas guardadas en BD (LDAP, mail) y la auth contra el DC falla.

7. **Inicializa BD si está vacía** — con un `flock` en EFS para evitar que dos instancias arrancando en paralelo ejecuten `db:install` a la vez:
   - Si la tabla `glpi_configs` no existe en RDS → `php bin/console db:install ...`
   - Después fuerza `url_base` en BD con un `UPDATE glpi_configs SET value = '${glpi_public_url}' WHERE name = 'url_base'` (evita que un dump migrado herede el path antiguo).

8. **Reescribe el VirtualHost de Apache** — siempre se ejecuta, sustituye el `glpi.conf` del Packer AMI por la versión definitiva:

   ```apache
   <VirtualHost *:80>
       DocumentRoot /var/www/html/glpi

       RewriteEngine On
       RewriteRule ^/glpi/?(.*)$ /$1 [R=301,L]

       <Directory /var/www/html/glpi>
           Options FollowSymLinks
           AllowOverride All
           Require all granted
       </Directory>
   </VirtualHost>
   ```

   La `RewriteRule` redirige cualquier petición a `/glpi` o `/glpi/...` a la raíz `/`, evitando 404 cuando navegadores con caché vieja entran por el path antiguo. Después habilita `mod_rewrite`, deshabilita el default y reinicia Apache.

> **Nota crítica sobre el DocumentRoot:** la documentación oficial moderna recomienda `DocumentRoot /var/www/html/glpi/public`, pero GLPI 10.0.18 hardcodea en su código PHP rutas tipo `public/lib/base.min.css`. Con DocumentRoot=`/public`, esa URL se traduce a `/var/www/html/glpi/public/public/lib/base.min.css` y da 404 (sin CSS, página rota). Con DocumentRoot=`/var/www/html/glpi` la URL resuelve correctamente a `/var/www/html/glpi/public/lib/base.min.css`. Las carpetas sensibles (`/config/`, `/files/`, `/install/`) ya traen `.htaccess` con `Require all denied`, por lo que no se exponen.

![](aws-launch-template.png){width=900px}
<!-- captura: AWS Console → EC2 → Launch Templates → lt-glpi-dracs → versión actual → User data decoded -->

# 3. Auto Scaling Group

---

| Atributo | Valor |
| --- | --- |
| Name | `asg-glpi-dracs` |
| min / max / desired | `0` / `3` / `var.asg_desired` (default `2`, una por AZ) |
| Subnets | `subnet-privada-a-dracs` + `subnet-privada-b-dracs` (multi-AZ) |
| Launch Template | `aws_launch_template.glpi`, version = `latest` |
| Target group | `tg-glpi-dracs` (el ALB lo gestiona) |
| Health check type | `ELB` (no EC2 — usa el resultado del health check del ALB) |
| Grace period | 300 s (tiempo para que el `user_data` termine antes de que el ALB la marque unhealthy) |
| `depends_on` | mount targets EFS (sin esto el ASG podría arrancar antes de que el EFS esté listo) |

`min_size = 2` garantiza que el par HA (una instancia por AZ) no baje aunque la alarma de scale-in de Target Tracking lo pida. Para mantenimiento agresivo (bajar a 0 o a 1) hay que reducir temporalmente `min_size` en Terraform — un `set-desired-capacity 0` por sí solo no funciona porque AWS lo cap-ea al `min_size`. La política de autoescalado por CPU levanta instancias automáticamente hasta `max_size = 4`.

## 3.1 Política de autoescalado

Junto al ASG se define una `aws_autoscaling_policy` de tipo `TargetTrackingScaling` sobre la métrica `ASGAverageCPUUtilization`:

```hcl
resource "aws_autoscaling_policy" "glpi_cpu" {
  name                   = "asg-glpi-cpu-tracking"
  autoscaling_group_name = aws_autoscaling_group.glpi.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value     = 60.0
    disable_scale_in = false
  }
}
```

El target del 60 % se eligió porque GLPI (PHP + Apache) empieza a degradarse por encima del 65-70 % de CPU. Con 60 % queda margen para absorber el pico mientras AWS lanza la siguiente instancia (~2 min con la AMI Packer). AWS crea y gestiona automáticamente las alarmas CloudWatch internas que disparan la política — no hay que declararlas.

> **Nota sobre health_check_type = ELB:** con esta config, el ASG sustituye una instancia si **el ALB** la marca unhealthy, no solo si la EC2 deja de responder a nivel de hardware. Es lo que se quiere: si GLPI deja de responder por bug software, queremos que se sustituya.

# 4. RDS MariaDB

---

La BD vive fuera de las instancias del ASG para que sobreviva a su sustitución.

| Atributo | Valor |
| --- | --- |
| Identifier | `rds-glpi-dracs` |
| Engine | MariaDB 10.11 |
| Clase | `db.t3.micro` |
| Almacenamiento | 20 GB gp3, encrypted |
| Endpoint | `rds-glpi-dracs.capsrvyl1db1.us-east-1.rds.amazonaws.com:3306` |
| BD inicial | `glpi`, usuario `glpi`, contraseña en `var.glpi_db_password` |
| Subnet group | `rds-subnet-glpi-dracs` (privada-a + privada-b) |
| Security Group | `rds-glpi-dracs` (sólo desde `glpi-dracs` SG, puerto 3306) |
| Backups | 7 días de retención automática |
| `skip_final_snapshot` | `true` (entorno de laboratorio; en producción se debería poner a `false`) |

# 5. EFS

---

EFS es el almacenamiento NFS compartido entre todas las instancias del ASG. Aloja los uploads de GLPI, logs, datos de sesión y la metadata de migración (`glpicrypt.key`).

| Atributo | Valor |
| --- | --- |
| Filesystem ID | `fs-00891f16aba18e12b` |
| Encryption | At rest activada |
| DNS endpoint | `<fs-id>.efs.us-east-1.amazonaws.com` |
| Mount targets | privada-a (10.0.2.x) + privada-b (10.0.4.x), cada uno con su ENI |
| Security Group | `efs-glpi-dracs` (puerto 2049 sólo desde `glpi-dracs` SG) |
| Punto de montaje | `/mnt/efs` en cada instancia (con symlinks a `glpi/files` y `glpi/plugins`) |

**Estructura del filesystem:**

```
/                            ← raíz del EFS (montada en /mnt/efs)
├── files/                   ← uploads, logs, sesiones, caché de GLPI
│   └── _meta/config/
│       └── glpicrypt.key    ← clave de cifrado de GLPI (migrada)
├── plugins/                 ← plugins instalados (compartidos entre instancias)
└── letsencrypt/             ← cert TLS persistido para que sobreviva al reemplazo del ASG
    └── live/dracs-glpi/
```

> **Nota:** desde Sprint 4 el filesystem se monta en `/mnt/efs` (raíz limpia) y desde ahí se hacen symlinks a `/var/www/html/glpi/files` y `/var/www/html/glpi/plugins`. Esto permite tener también los plugins compartidos entre instancias, y aloja directorios auxiliares (como `letsencrypt/`) que no son parte de GLPI.

> **Nota:** `_meta/config/glpicrypt.key` se puso ahí durante la migración (ver punto 6). El `user_data` la restaura a `/var/www/html/glpi/config/` en cada instancia del ASG, porque la carpeta `config/` está fuera del DocumentRoot accesible y, además, vive en el disco efímero de cada instancia.

# 6. Migración de datos a este stack

---

La migración desde la cuenta anterior se hizo con una EC2 temporal lanzada desde la AMI custom de GLPI vieja, dentro de la VPC nueva, con el SG `glpi-dracs` (que le da acceso a RDS y EFS).

El `user_data` del migrator:

1. Espera a que MariaDB local (la del AMI) esté arriba.
2. `mysqldump -u root --single-transaction --routines --triggers --databases glpi > /tmp/glpi.sql`.
3. `mysql -h <rds_endpoint> -u glpi -p<pass>` para crear la BD y aplicar el dump.
4. Monta el EFS y hace `rsync -av /var/www/html/glpi/files/ /mnt/efs/`.
5. Copia `glpicrypt.key` y resto de `config/` a `/mnt/efs/_meta/config/`.
6. Marca `/mnt/efs/.migration-done` para diagnóstico.
7. `shutdown -h now` (con `instance_initiated_shutdown_behavior = terminate` la instancia se autodestruye).

Tras la migración el ASG se levanta (`asg_desired=1`), el `user_data` detecta que la BD tiene tablas y `db:update` migra el schema de 10.0.12 (versión origen) a 10.0.18 (versión actual).

# 7. Documentación relacionada

---

* **AWS.md** — visión general
* **AWS-RED.md** — subnets privadas donde viven el ASG, RDS y EFS
* **AWS-BALANCEO.md** — ALB que reparte tráfico al target group del ASG
* **AWS-SEGURIDAD.md** — los Security Groups que limitan quién puede hablar con RDS/EFS
* **AWS-RUNBOOK.md** — reemplazo de instancia ASG, cambio de `desired_capacity`, troubleshooting
* **AWS-SIMPLE.md** — versión previa monolítica (GLPI standalone con MariaDB+ficheros locales) para comparar con este stack
