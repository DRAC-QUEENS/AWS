# Terraform — IaC, state y migración

Toda la infraestructura está descrita como código en Terraform. El repo contiene los ficheros `.tf` divididos por área funcional, los secretos en `terraform.tfvars` (gitignored), y el state se guarda en S3 con lock en DynamoDB. Este artículo documenta la estructura, las variables, el bootstrap del backend remoto y el procedimiento real seguido para migrar entre cuentas AWS.

# 1. Estructura del repo

---

| Fichero | Contenido |
| --- | --- |
| `provider.tf` | Provider AWS (~> 6.0) + bloque `backend "s3"` (comentado hasta el bootstrap) |
| `backend.tf` | Bucket S3 y tabla DynamoDB para guardar el state remoto |
| `variables.tf` | Todas las variables del proyecto (región, key pair, `glpi_ami_id`, `asg_desired`, contraseñas, claves WG) |
| `network.tf` | VPC, 4 subnets en 2 AZs, IGW, NAT, route tables, rutas a on-prem |
| `security.tf` | Los 6 Security Groups |
| `instances.tf` | EC2 WireGuard (con EIP) + EC2 Nginx (sólo IP privada) |
| `glpi_scaling.tf` | EFS, RDS, ALB (HTTP+HTTPS), NLB, Launch Template, Auto Scaling Group, listeners, target groups y política de autoescalado por CPU |
| `backups.tf` | Bucket S3 de backups de aplicación con lifecycle a Glacier (30 d) y expiración (365 d) |
| `outputs.tf` | Outputs principales (DNS ALB, EIP NLB, EIP WG, endpoint RDS, ID EFS, buckets S3) |
| `packer/glpi.pkr.hcl` | Plantilla Packer para construir la AMI custom con GLPI pre-instalado |
| `user_data/wireguard.sh.tpl` | Bootstrap del WG EC2 (claves inyectadas vía `templatefile`) |
| `user_data/nginx.sh.tpl` | Bootstrap del Nginx EC2 (URL pública inyectada vía `templatefile`) |
| `user_data/glpi_asg.sh.tpl` | Bootstrap idempotente de las instancias del ASG (EFS, certbot restore, BD, VirtualHost con `RewriteRule /glpi → /`) |

# 2. Variables

---

| Variable | Tipo | Default | Descripción |
| --- | --- | --- | --- |
| `region` | string | `us-east-1` | Región AWS |
| `key_name` | string | `dracs-keypair` | Key pair EC2. En la cuenta actual usamos `dracs3` vía `tfvars` |
| `glpi_ami_id` | string | `""` | AMI Packer con GLPI pre-instalado. Vacío = Ubuntu 24.04 LTS latest |
| `asg_desired` | number | `2` | `desired_capacity` del ASG (una instancia por AZ). Se baja a 0 durante mantenimiento |
| `glpi_public_url` | string | `https://dracs-glpi.duckdns.org` | URL pública; se fuerza en `glpi_configs.url_base` en cada arranque del ASG |
| `glpi_db_password` | string (sensitive) | *(requerida)* | Contraseña RDS de GLPI |
| `wg_aws_private_key` | string (sensitive) | *(requerida)* | Clave privada WireGuard del lado AWS |
| `wg_opnsense_public_key` | string (sensitive) | *(requerida)* | Clave pública del peer OPNsense |
| `wg_preshared_key` | string (sensitive) | *(requerida)* | PSK del túnel |

Las variables marcadas `sensitive` no aparecen en logs ni outputs. Se pasan en `terraform.tfvars`:

```hcl
key_name               = "dracs3"
glpi_ami_id            = "ami-0695c86f79f0e87b7"
asg_desired            = 2
glpi_db_password       = "<contraseña>"
wg_aws_private_key     = "<key>"
wg_opnsense_public_key = "<key>"
wg_preshared_key       = "<key>"
```

> **Nota sobre `glpi_ami_id`:** la AMI Packer se construye con la plantilla `packer/glpi.pkr.hcl` y reduce el tiempo de arranque de las instancias del ASG de ~10 min a ~2 min. Si la variable se deja vacía, el Launch Template cae a Ubuntu 24.04 LTS vanilla y el `user_data` instala todo en caliente como fallback.

> **Nota:** `terraform.tfvars` está en `.gitignore`. Hay que regenerarlo manualmente en cada equipo o cuenta nueva.

# 3. Backend remoto S3 + DynamoDB

---

El state remoto vive en un bucket S3 con versioning y SSE, y un table DynamoDB para los locks (impide que dos `apply` simultáneos corrompan el state).

| Recurso | Nombre |
| --- | --- |
| Bucket S3 | `dracs-tfstate-<account_id>` (versionado + AES256 + public-block) |
| Tabla DynamoDB | `dracs-tfstate-lock` (PAY_PER_REQUEST, hash_key `LockID`) |

**Bootstrap (chicken-and-egg).** El bucket y la tabla se crean **con Terraform** desde el state local, pero luego el backend se cambia para usar el bucket recién creado. El procedimiento:

1. Primer `terraform apply` con state local → se crean bucket y tabla.
2. Editar `provider.tf`: descomentar el bloque `backend "s3"` y poner el account ID.
3. `terraform init -migrate-state` → mueve el `.tfstate` local al bucket.
4. A partir de aquí todos los `apply` usan el state remoto.

```hcl
# provider.tf (descomentar tras el bootstrap)
backend "s3" {
  bucket         = "dracs-tfstate-<ACCOUNT_ID>"
  key            = "infra/terraform.tfstate"
  region         = "us-east-1"
  encrypt        = true
  dynamodb_table = "dracs-tfstate-lock"
}
```

El bucket tiene `lifecycle { prevent_destroy = true }` para que un `terraform destroy` no se lleve el state por delante.

# 4. Outputs

---

| Output | Sirve para |
| --- | --- |
| `nlb_eip` | Configurar DuckDNS |
| `alb_dns` | Hacer pruebas directas con curl o configurar Nginx |
| `wireguard_ip_publica` | Actualizar el endpoint del peer en OPNsense |
| `nginx_ip_publica` | Referencia para acceso administrativo |
| `rds_endpoint` | Para tests manuales contra la BD |
| `efs_id` | Para hacer `mount -t nfs4` desde un instancia externa al stack |
| `tfstate_bucket` | Nombre del bucket S3 del state |
| `backups_bucket` | Nombre del bucket de backups de aplicación |

# 5. Migración entre cuentas

---

Este procedimiento se ha aplicado dos veces: primero de `947411159788` → `123561366922` (durante Sprint 2) y después de `123561366922` → la cuenta actual `563771271989` (Sprint 3, 2026-05-22). Se documenta aquí porque está acoplado al código Terraform (AMIs custom, variables, asg_desired). La segunda migración fue más simple porque RDS y EFS persisten entre sesiones de Academy y se reutilizaron presigned URLs cross-account en vez de KMS share.

**Resumen del flujo:**

1. **En la cuenta origen** — desplegar la infraestructura vieja (arquitectura simple, EC2 single-instance) si no estaba. Crear AMIs custom de WG y Nginx (snapshot del estado configurado), y una AMI de la EC2 GLPI (sólo se va a usar como fuente para migrar BD+ficheros, no para correr el ASG).

2. **CMK para cross-account share** — crear `alias/dracs-glpi-share-key` con key policy que autorice al account ID destino. Volver a crear las AMIs con esta CMK (no con `aws/ebs`) o copiar los snapshots existentes especificando la CMK. Sin esto, **no se pueden compartir**.

3. **Compartir AMIs con la cuenta destino** — `modify-image-attribute --launch-permission Add` y `modify-snapshot-attribute --create-volume-permission Add` apuntando al account ID destino, tanto para la AMI como para sus snapshots subyacentes.

4. **En la cuenta destino, preparar Terraform:**
   - `terraform.tfvars` con `wireguard_ami_id` y `nginx_ami_id` apuntando a las AMIs compartidas.
   - `asg_desired = 0` para que el ASG no arranque instancias antes de migrar los datos.
   - `terraform init && terraform apply` → crea VPC, SGs, EIPs, NLB, ALB, RDS (vacío), EFS, Launch Template, ASG (sin instancias), WG EC2, Nginx EC2.

5. **Migrator EC2 temporal** — lanzar una EC2 con la AMI custom de GLPI (la compartida desde la cuenta origen), en una subnet privada, con el SG `glpi-dracs` (que le da acceso a RDS y EFS). Pasarle un `user_data` que:
   - Haga `mysqldump` de la BD MariaDB local.
   - Lo importe a RDS con `mysql -h <endpoint>`.
   - Monte el EFS y haga `rsync` de `/var/www/html/glpi/files/`.
   - Copie `glpicrypt.key` y el resto de `config/` a `/mnt/efs/_meta/config/`.
   - `shutdown -h now` (con `instance-initiated-shutdown-behavior=terminate` la EC2 se autodestruye).

6. **Subir el ASG** — `terraform apply -var asg_desired=1`. La nueva instancia arranca, el `user_data` detecta que la BD tiene tablas (saltea `db:install`), restaura `glpicrypt.key` desde EFS, ejecuta `db:update` para migrar el schema y fuerza `url_base` a la nueva URL.

7. **DuckDNS** — actualizar la IP a la EIP del nuevo NLB.

8. **OPNsense** — actualizar el Endpoint del peer WireGuard a la EIP del nuevo WG EC2. Las claves WG no cambian (vienen de `tfvars` y se mantienen iguales).

9. **Renovar el cert TLS** — el cert no migra. Hay que volver a ejecutar certbot DNS-01 en la cuenta nueva (ver `G2-A-67` / `AWS-BALANCEO.md`).

10. **Verificar** — `https://dracs-glpi.duckdns.org/` debe cargar el login. Hacer un login con un usuario del DC para validar que la auth LDAP funciona (lo que también valida la VPN y la `glpicrypt.key`).

> **Nota:** la cuenta origen se mantiene operativa durante la migración. Solo se apaga (o se deja terminar de Academy) una vez verificada la nueva. La regla 1 de migración: no destruir nada hasta tener funcional la otra parte.

# 6. Documentación relacionada

---

* **G2-A-59 — AWS.md** — visión general
* **G2-A-61 — AWS-SEGURIDAD.md** — CMK para cross-account share y custodia de secretos en tfvars
* **G2-A-66 — AWS-GLPI.md** — detalle del migrator EC2 y del `user_data` idempotente
* **G2-A-67 — AWS-BALANCEO.md** — emisión del cert TLS (no migra, se reemite)
* **G2-A-64 — AWS-RUNBOOK.md** — operativa post-migración
