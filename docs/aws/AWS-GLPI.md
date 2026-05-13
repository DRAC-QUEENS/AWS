# Stack GLPI (Compute + Datos)

El backend de GLPI se compone de un Auto Scaling Group (compute efímero), una base de datos RDS MariaDB (estado persistente) y un EFS compartido (ficheros y metadata). Las instancias del ASG se lanzan desde un Launch Template con Ubuntu vanilla y se configuran por completo en cada arranque mediante un `user_data` idempotente. La separación compute/datos permite sustituir instancias sin perder información.

> **Nota:** este stack sustituyó a una versión anterior en la que GLPI corría como **una sola EC2** con MariaDB y ficheros en disco local. Esa versión sigue documentada en `AWS-SIMPLE.md` y el código vive en el folder `simple/` del repo. La comparación entre ambas explica por qué se introdujeron RDS, EFS y el ASG.

# 1. Launch Template

---

El Launch Template (`lt-glpi-dracs-...`) define cómo se fabrica cada instancia del ASG. Usa Ubuntu 24.04 LTS vanilla porque toda la configuración de GLPI vive en el `user_data` (más mantenible que una AMI custom que habría que rehacer cada vez que se actualiza GLPI).

| Atributo | Valor |
| --- | --- |
| AMI | `data.aws_ami.ubuntu.id` (Ubuntu 24.04 LTS latest, `099720109477`) |
| Tipo | `t3.small` |
| Key pair | `var.key_name` (en producción `dracs2`) |
| Security Group | `glpi-dracs` |
| IAM profile | `LabInstanceProfile` (habilita SSM Session Manager y acceso ACM para importar certs) |
| Block device | `/dev/sda1` 20 GB gp3, encrypted |
| User data | `templatefile("user_data/glpi_asg.sh.tpl", { rds_endpoint, db_password, efs_dns, glpi_public_url })` |

# 2. user_data idempotente

---

El script se ejecuta en el primer boot de cada instancia. Es completamente idempotente: las operaciones se pueden repetir sin romper nada (lo cual es vital porque el ASG puede sustituir instancias en cualquier momento).

**Pasos que ejecuta:**

1. **Instala dependencias** — `apache2`, `nfs-common`, `mariadb-client`, todas las extensiones PHP que GLPI necesita (`php-mysql`, `php-curl`, `php-gd`, `php-intl`, `php-ldap`, `php-mbstring`, etc.).

2. **Monta EFS** — crea `/var/www/html/glpi/files`, ejecuta `mount -t nfs4 -o nfsvers=4.1,...` apuntando al DNS del EFS, y persiste el mount en `/etc/fstab` con `grep -q ... || echo ...` (idempotente). Restaura ownership a `www-data`.

3. **Descarga GLPI** — sólo si `/var/www/html/glpi/index.php` no existe. Descarga `glpi-10.0.18.tgz` de GitHub, lo extrae y ajusta permisos.

4. **Escribe `config_db.php`** — con el endpoint RDS, usuario y contraseña inyectados desde Terraform. Se reescribe en cada arranque para garantizar que apunta al RDS correcto (por si se ha rotado la pass).

5. **Restaura `glpicrypt.key` desde EFS** — si `/var/www/html/glpi/files/_meta/config/glpicrypt.key` existe (porque la migración lo dejó allí), lo copia a `/var/www/html/glpi/config/glpicrypt.key`. Sin esta clave GLPI no puede descifrar las contraseñas guardadas en BD (LDAP, mail) y la auth contra el DC falla.

6. **Inicializa BD o actualiza schema** — con un `flock` en EFS para que dos instancias arrancando en paralelo no entren en race condition:
   - Si la tabla `glpi_configs` no existe en RDS → `php bin/console db:install ...`
   - Si ya existe → `php bin/console db:update --no-interaction --force` (idempotente: si schema actual, no-op; si antiguo, migra)

7. **Fuerza `url_base`** — `UPDATE glpi_configs SET value = '${glpi_public_url}' WHERE name = 'url_base'`. Evita que tras migrar un dump con `url_base` viejo, los redirects post-login lleven a `/glpi` y den 404.

8. **Apache VirtualHost** — escribe `/etc/apache2/sites-available/glpi.conf` con `DocumentRoot /var/www/html/glpi` (modo legacy, no `/public`), habilita `mod_rewrite`, deshabilita el default, reinicia Apache.

> **Nota crítica sobre el DocumentRoot:** la documentación oficial moderna recomienda `DocumentRoot /var/www/html/glpi/public`, pero GLPI 10.0.18 hardcodea en su código PHP rutas tipo `public/lib/base.min.css`. Con DocumentRoot=`/public`, esa URL se traduce a `/var/www/html/glpi/public/public/lib/base.min.css` y da 404 (sin CSS, página rota). Con DocumentRoot=`/var/www/html/glpi` la URL resuelve correctamente a `/var/www/html/glpi/public/lib/base.min.css`. Las carpetas sensibles (`/config/`, `/files/`, `/install/`) ya traen `.htaccess` con `Require all denied`, por lo que no se exponen.

![](aws-launch-template.png){width=900px}
<!-- captura: AWS Console → EC2 → Launch Templates → lt-glpi-dracs → versión actual → User data decoded -->

# 3. Auto Scaling Group

---

| Atributo | Valor |
| --- | --- |
| Name | `asg-glpi-dracs` |
| min / max / desired | `0` / `3` / `var.asg_desired` (default `1`) |
| Subnets | `subnet-privada-a-dracs` + `subnet-privada-b-dracs` (multi-AZ) |
| Launch Template | `aws_launch_template.glpi`, version = `latest` |
| Target group | `tg-glpi-dracs` (el ALB lo gestiona) |
| Health check type | `ELB` (no EC2 — usa el resultado del health check del ALB) |
| Grace period | 300 s (tiempo para que el `user_data` termine antes de que el ALB la marque unhealthy) |
| `depends_on` | mount targets EFS (sin esto el ASG podría arrancar antes de que el EFS esté listo) |

`min_size = 0` permite bajar a 0 durante mantenimiento (por ejemplo, durante la migración de datos antes de que RDS+EFS estuvieran poblados). En producción se mantiene `desired = 1` y se puede subir manualmente si hace falta más capacidad.

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
| Filesystem ID | `fs-0e3a12b50ac2f89b3` |
| Encryption | At rest activada |
| DNS endpoint | `fs-0e3a12b50ac2f89b3.efs.us-east-1.amazonaws.com` |
| Mount targets | privada-a (10.0.2.x) + privada-b (10.0.4.x), cada uno con su ENI |
| Security Group | `efs-glpi-dracs` (puerto 2049 sólo desde `glpi-dracs` SG) |
| Punto de montaje | `/var/www/html/glpi/files` en cada instancia |

**Estructura del filesystem:**

```
/                           ← raíz del EFS
├── (uploads GLPI)
├── _meta/
│   └── config/
│       ├── glpicrypt.key   ← clave de cifrado de GLPI (migrada)
│       └── (otros configs de la instalación original)
└── _cache/
    └── (caché de templates Twig)
```

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
