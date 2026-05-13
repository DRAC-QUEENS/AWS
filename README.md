# AWS DRACS Hybrid Infrastructure

Infraestructura AWS del proyecto DRACS (ASIX2). Arquitectura híbrida con VPN WireGuard site-to-site hacia un cluster Proxmox on-prem, GLPI como sistema de inventario con alta disponibilidad en 2 AZs, TLS terminado en ALB con certificado Let's Encrypt, y backend remoto de Terraform en S3.

## Arquitectura

```
                         INTERNET
                             │
                    ┌────────┴────────┐
                    │  NLB (EIP fija) │  ← DuckDNS apunta aquí
                    │  TCP:80, TCP:443│
                    └────────┬────────┘
                             │
                    ┌────────┴────────┐
                    │      ALB        │  HTTP:80 (redirect→443)
                    │ HTTPS:443 + ACM │  HTTPS:443 (TLS termina aquí)
                    └────────┬────────┘
               ┌─────────────┴─────────────┐
        AZ a (us-east-1a)          AZ b (us-east-1b)
     ┌──────────────────┐       ┌──────────────────┐
     │ PRIVATE 10.0.2.x │       │ PRIVATE 10.0.4.x │
     │  ┌─────────────┐ │       │  ┌─────────────┐ │
     │  │  GLPI (ASG) │ │       │  │  GLPI (ASG) │ │
     │  └──────┬──────┘ │       │  └──────┬──────┘ │
     └─────────┼────────┘       └─────────┼────────┘
               └──────────┬───────────────┘
                      ┌───┴────┐     ┌──────────┐
                      │  RDS   │     │   EFS    │
                      │MariaDB │     │  /files  │
                      └────────┘     └──────────┘

     PUBLIC 10.0.1.x                PUBLIC 10.0.3.x
  ┌─────────────────────┐       ┌──────────────────┐
  │WireGuard (10.0.1.10)│       │ (sin instancias) │
  │Nginx     (10.0.1.20)│       │                  │
  └─────────────────────┘       └──────────────────┘
           ↕ WireGuard VPN (10.8.0.0/24)
     OPNsense on-prem (192.168.x.x)

  Tráfico desde on-prem:
    Cliente on-prem → OPNsense → WireGuard tunnel → AWS VPC →
       (a) Nginx (10.0.1.20) → ALB → GLPI ASG   [si quieres pasar por proxy interno]
       (b) GLPI ASG directo (SG permite 10.8.0/24 + 192.168.x.x)
```

## Componentes

### WireGuard — VPN Gateway
- EC2 t3.micro, subnet pública, IP fija 10.0.1.10, EIP
- Túnel site-to-site UDP:51820 con OPNsense on-prem
- `source_dest_check = false` para actuar como router
- IP forwarding + iptables NAT/FORWARD aplicados via user_data
- Script: `user_data/wireguard.sh.tpl`

### Nginx — Reverse Proxy interno
- EC2 t3.micro, subnet pública, IP fija 10.0.1.20, EIP
- Sirve el tráfico interno (vía VPN) hacia el ALB en HTTPS
- SSL auto-firmado (sólo se usa desde VPN; el FQDN público usa el cert ACM del ALB)
- Script: `user_data/nginx.sh.tpl` (el DNS del ALB se inyecta en `terraform apply`)

### NLB — IP fija para DuckDNS
- Network Load Balancer con Elastic IP estática
- DuckDNS apunta a esta IP; el NLB delega al ALB (TCP:80 y TCP:443)
- Sin SG propio (NLBs no tienen security groups)

### ALB — Balanceador HTTP/HTTPS y TLS termination
- Application Load Balancer internet-facing en 2 AZs
- Listener 80 → redirect 301 a 443
- Listener 443 → cert ACM (Let's Encrypt vía certbot DNS-01 con DuckDNS)
- Health checks al path `/` con 30s de intervalo
- Distribuye tráfico entre instancias del ASG

### GLPI — Auto Scaling Group (2 AZs)
- Launch Template: t3.small, **Ubuntu 24.04 LTS vanilla** (el user_data instala GLPI desde cero)
- ASG: min=0, max=3, desired=`var.asg_desired` (default 1)
- IAM profile: `LabInstanceProfile` (AWS Academy) → habilita SSM Session Manager
- Script: `user_data/glpi_asg.sh.tpl`
- Instancias **sin estado**: BD en RDS, ficheros en EFS
- El user_data es idempotente y reaplica en cada arranque:
  - `config_db.php` apuntando a RDS
  - Restauración de `glpicrypt.key` desde EFS si existe (sin él GLPI no descifra datos sensibles)
  - `db:install` si BD vacía, `db:update` si schema antiguo
  - Forzado de `url_base` en BD a `var.glpi_public_url`

### RDS — MariaDB 10.11
- db.t3.micro, 20 GB gp3, cifrado en reposo
- Subnets privadas en ambas AZs (subnet group)
- Solo accesible desde las instancias del ASG (SG restringido)
- Backups automáticos gestionados por AWS

### EFS — Almacenamiento compartido
- Filesystem NFS compartido entre todas las instancias del ASG
- Montado en `/var/www/html/glpi/files/` (uploads, logs, attachments)
- También guarda `_meta/config/glpicrypt.key` (clave de cifrado GLPI, necesaria tras migración)
- Mount targets en ambas subnets privadas

### ACM — Certificado TLS
- Certificado Let's Encrypt para `dracs-glpi.duckdns.org`
- Emitido por `certbot` con plugin `dns-duckdns` (DNS-01 challenge)
- Importado a ACM (`aws_acm_certificate` data source con `most_recent = true`)
- Renovación cada 90 días: re-emitir + re-importar a ACM (no automatizado)

## Security Groups

| SG | Ingress | Egress |
|----|---------|--------|
| `wireguard-dracs` | UDP:51820 (0.0.0.0/0), TCP:22 (VPN 10.8.0.0/24), todo desde VPC (10.0.0.0/16) | Todo |
| `nginx-dracs` | TCP:80/443 (0.0.0.0/0), TCP:22 (VPN) | Todo |
| `alb-glpi-dracs` | TCP:80 y TCP:443 (0.0.0.0/0), TCP:80 desde nginx SG | Todo |
| `glpi-dracs` | TCP:80 desde alb SG, todo desde VPN + on-prem (10.8.0/24, 192.168.1/24, 192.168.10/24, 192.168.20/24) | Todo |
| `rds-glpi-dracs` | TCP:3306 desde glpi SG | Todo |
| `efs-glpi-dracs` | TCP:2049 desde glpi SG | Todo |

## Archivos del proyecto

```
.
├── provider.tf         → AWS provider + backend S3 (comentado hasta bootstrap)
├── variables.tf        → región, key_name, AMIs, asg_desired, contraseñas y claves WG
├── network.tf          → VPC, 4 subnets (2 AZs), NAT, IGW, rutas on-prem via WG ENI
├── security.tf         → 6 security groups
├── instances.tf        → WireGuard + Nginx EC2 (AMIs custom o Ubuntu vanilla)
├── glpi_scaling.tf     → EFS, RDS, ALB (HTTP+HTTPS), NLB, Launch Template, ASG
├── backend.tf          → S3 (tfstate) + DynamoDB (lock)
├── backups.tf          → S3 (backups app) + AMI snapshots WireGuard/Nginx
├── outputs.tf          → IPs, DNS, endpoints
└── user_data/
    ├── wireguard.sh.tpl   → Instala WireGuard, IP forwarding, iptables NAT
    ├── nginx.sh.tpl       → Nginx → proxy HTTPS al ALB (DNS inyectado por Terraform)
    └── glpi_asg.sh.tpl    → GLPI contra RDS + EFS, restaura glpicrypt.key, fuerza url_base
```

## Variables

| Variable | Default | Descripción |
|----------|---------|-------------|
| `region` | `us-east-1` | Región AWS |
| `key_name` | `dracs-keypair` | Key pair EC2 (debe existir en la cuenta). En la cuenta nueva usamos `dracs2` vía tfvars |
| `wireguard_ami_id` | `""` | AMI custom de WireGuard (migración). Vacío = Ubuntu 24.04 LTS latest |
| `nginx_ami_id` | `""` | AMI custom de Nginx (migración). Vacío = Ubuntu 24.04 LTS latest |
| `asg_desired` | `1` | Instancias deseadas en el ASG. Bajar a 0 durante migración de datos a RDS+EFS |
| `glpi_public_url` | `https://dracs-glpi.duckdns.org` | URL pública; se fuerza en `glpi_configs.url_base` cada arranque |
| `glpi_db_password` | *(requerida)* | Contraseña de la BD RDS de GLPI |
| `wg_aws_private_key` | *(requerida)* | WireGuard private key del gateway AWS |
| `wg_opnsense_public_key` | *(requerida)* | WireGuard public key del peer OPNsense |
| `wg_preshared_key` | *(requerida)* | WireGuard preshared key (PSK) del túnel |
| `create_ami_backup` | `false` | Crear AMI snapshots de WireGuard y Nginx |

### Gestionar secretos sin pasarlos en CLI

```bash
# Crear terraform.tfvars (ya ignorado por .gitignore, no se sube al repo)
cat > terraform.tfvars << 'EOF'
key_name               = "dracs2"
glpi_db_password       = "TuPasswordSegura"
wg_aws_private_key     = "..."
wg_opnsense_public_key = "..."
wg_preshared_key       = "..."
EOF

# O vía variables de entorno
export TF_VAR_glpi_db_password="TuPasswordSegura"
export TF_VAR_wg_aws_private_key="..."
```

## Despliegue

### Requisitos previos
- Key pair creado en la cuenta AWS (nombre referenciado por `var.key_name`)
- AWS CLI configurado (`aws configure --profile dracs-new` recomendado)
- Terraform >= 1.5.0

### Primer despliegue (cuenta nueva)

```bash
# 1. Crear terraform.tfvars con los secretos
$EDITOR terraform.tfvars

# 2. Inicializar providers (state local hasta que se active el backend remoto)
AWS_PROFILE=dracs-new terraform init

# 3. Plan + apply
AWS_PROFILE=dracs-new terraform plan
AWS_PROFILE=dracs-new terraform apply

# 4. Ver outputs (IPs, endpoints)
AWS_PROFILE=dracs-new terraform output
```

### Migración entre cuentas AWS

Procedimiento real seguido para migrar de `947411159788` a `123561366922`:

1. **En cuenta origen**: AMIs custom de WG y Nginx (snapshot del estado configurado) y AMI de GLPI (sólo para extraer los datos).
2. **Compartir AMIs+snapshots** a la cuenta destino. Si están cifradas, usar CMK (KMS) con key policy que permita a la cuenta destino.
3. **En cuenta destino**:
   - `terraform.tfvars` con `wireguard_ami_id` y `nginx_ami_id` apuntando a las AMIs compartidas, `asg_desired = 0`.
   - `terraform apply` — crea todo excepto instancias GLPI.
   - **Migrar datos GLPI**: instancia temporal desde la AMI de GLPI compartida → `mysqldump` a RDS, `rsync /var/www/html/glpi/files/` a EFS, copia de `glpicrypt.key` a EFS (`_meta/config/`). Auto-terminate.
   - Subir `asg_desired` a 1.
4. **DuckDNS**: actualizar IP al nuevo NLB EIP.
5. **OPNsense**: actualizar Endpoint del peer WireGuard al nuevo EIP de WG EC2. Las claves WG no cambian.
6. **Renovar cert**: `certbot --dns-duckdns -d dracs-glpi.duckdns.org` y re-importar a ACM (el data source coge la versión más reciente automáticamente).

### Activar backend remoto (S3 + DynamoDB)

```bash
# Tras el primer apply (que crea el bucket y la tabla):
AWS_PROFILE=dracs-new terraform output tfstate_bucket

# Editar provider.tf: descomentar bloque backend "s3" y poner el account_id
# Migrar state local al bucket:
AWS_PROFILE=dracs-new terraform init -migrate-state
```

## Outputs principales

```bash
terraform output nlb_eip               # IP fija → DuckDNS
terraform output alb_dns               # DNS ALB (debugging/HTTPS directo)
terraform output rds_endpoint          # Endpoint MariaDB
terraform output efs_id                # ID del EFS compartido
terraform output wireguard_ip_publica  # EIP WG → OPNsense peer endpoint
terraform output nginx_ip_publica
```

## Troubleshooting

### GLPI no responde tras el deploy
- El ASG tarda ~3-5 min en arrancar la instancia y ejecutar el user_data
- Console → EC2 → Auto Scaling Groups → `asg-glpi-dracs` → Activity
- Logs vía SSM: `aws ssm start-session --target <instance-id>` → `tail -f /var/log/cloud-init-output.log`

### ALB health checks failing
- GLPI necesita unos minutos para inicializarse (RDS + EFS mount + install)
- Grace period del ASG: 300 segundos
- Comprobar: `curl -I https://dracs-glpi.duckdns.org/` (200/302 esperado)

### Después de login GLPI redirige a /glpi y da 404
- El `url_base` en BD aún tiene el path antiguo. El user_data lo arregla en cada boot, pero si se acaba de importar un dump puede pasar.
- Manual: `UPDATE glpi_configs SET value = 'https://dracs-glpi.duckdns.org' WHERE name = 'url_base';`

### Asset CSS no carga (página sin estilos)
- Apache vhost debe tener `DocumentRoot /var/www/html/glpi` (modo legacy GLPI 10), NO `/var/www/html/glpi/public`. GLPI 10.0.x hardcodea `public/lib/...` en las URLs

### Auth LDAP/AD falla
- Verificar conectividad TCP 389 desde GLPI ASG al DC: SSM al GLPI y `bash -c "</dev/tcp/192.168.10.10/389"`
- Si ICMP llega pero TCP no: firewall del DC (Windows Firewall por origen) probablemente bloquea la subnet privada del ASG. Añadir `10.0.0.0/16` al scope de la regla LDAP/Kerberos
- Verificar que `glpicrypt.key` está en `/var/www/html/glpi/config/` (sin él GLPI no puede descifrar la pass LDAP)

### WireGuard no conecta tras migrar de cuenta
- El EIP de WG cambia → actualizar el Endpoint en OPNsense
- `terraform output wireguard_ip_publica` da el nuevo EIP
- Las claves WG no cambian (están en `terraform.tfvars`)

### "El handshake aparece en OPNsense pero AWS no recibe nada"
- Probable: OPNsense aún apunta a la EIP de la cuenta vieja. Verificar en OPNsense → VPN → WireGuard → Peers → AWS → Endpoint

## Roadmap

- [x] Backend Terraform remoto (S3 + DynamoDB)
- [x] ALB + ASG multi-AZ para GLPI
- [x] RDS MariaDB (BD fuera del ASG)
- [x] EFS para ficheros compartidos
- [x] NLB con EIP fija (para DuckDNS)
- [x] AMI parametrizable para migración entre cuentas (WG y Nginx)
- [x] HTTPS en ALB (cert Let's Encrypt vía certbot + DuckDNS + ACM)
- [ ] Renovación automatizada del cert TLS (cron + persistencia en EFS + re-import a ACM)
- [ ] VPC Flow Logs para observabilidad
- [ ] Route53 Privado para DNS interno
- [ ] CloudWatch Alarms (CPU, RDS connections, ALB 5xx)
- [ ] Multi-AZ RDS (alta disponibilidad de la BD)

---

**Proyecto**: DRACS — ASIX2, INS Provençana, 2026
**Terraform**: >= 1.5.0 | **AWS Provider**: ~> 6.0
