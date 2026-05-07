# AWS DRACS Hybrid Infrastructure

Infraestructura AWS del proyecto DRACS (ASIX2). Arquitectura híbrida con VPN WireGuard site-to-site hacia un cluster Proxmox on-prem, GLPI como sistema de inventario con alta disponibilidad en 2 AZs, y backend remoto de Terraform en S3.

## Arquitectura

```
                         INTERNET
                             │
                    ┌────────┴────────┐
                    │  NLB (EIP fija) │  ← DuckDNS apunta aquí
                    └────────┬────────┘
                             │ TCP:80
                    ┌────────┴────────┐
                    │      ALB        │  HTTP:80, 2 AZs
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
  ┌────────────────────┐         ┌──────────────────┐
  │ WireGuard (10.0.1.10)│        │   (sin instancias)│
  │ Nginx     (10.0.1.20)│        │                  │
  └─────────────────────┘        └──────────────────┘
           ↕ WireGuard VPN (10.8.0.0/24)
     OPNsense on-prem (192.168.x.x)

  Trafico interno (Proxmox → GLPI):
    OPNsense → WireGuard EC2 → Nginx (10.0.1.20) → ALB → GLPI ASG
```

## Componentes

### WireGuard — VPN Gateway
- EC2 t3.micro, subnet pública, IP fija 10.0.1.10, EIP
- Túnel site-to-site UDP:51820 con OPNsense on-prem
- `source_dest_check = false` para actuar como router
- Script: `user_data/wireguard.sh`

### Nginx — Reverse Proxy interno
- EC2 t3.micro, subnet pública, IP fija 10.0.1.20, EIP
- Sirve el tráfico interno (WireGuard/Proxmox) hacia el ALB
- SSL auto-firmado para HTTPS desde la VPN
- Script: `user_data/nginx.sh.tpl` (el DNS del ALB se inyecta en tiempo de despliegue)

### NLB — IP fija para DuckDNS
- Network Load Balancer con Elastic IP estática
- DuckDNS apunta a esta IP; el NLB delega al ALB
- Sin SG propio (NLBs no tienen security groups)

### ALB — Balanceador HTTP
- Application Load Balancer internet-facing en 2 AZs
- Health checks al path `/glpi/` con 30s de intervalo
- Distribuye tráfico entre instancias del ASG

### GLPI — Auto Scaling Group (2 AZs)
- Launch Template: t3.small, AMI configurable via variable
- ASG: min=1, max=3, desired=1 (escala según carga)
- Script: `user_data/glpi_asg.sh.tpl`
- Instancias **sin estado**: la BD está en RDS y los ficheros en EFS

### RDS — MariaDB 10.11
- db.t3.micro, 20 GB gp3, cifrado en reposo
- Subnets privadas en ambas AZs (subnet group)
- Solo accesible desde las instancias del ASG (SG restringido)
- Backups automáticos gestionados por AWS

### EFS — Almacenamiento compartido
- Filesystem NFS compartido entre todas las instancias del ASG
- Montado en `/var/www/html/glpi/files/` (uploads, logs, attachments)
- Mount targets en `private` (AZ a) y `private_b` (AZ b)

## Security Groups

| SG | Ingress | Egress |
|----|---------|--------|
| `wireguard-dracs` | UDP:51820 (0.0.0.0/0), TCP:22 (VPN 10.8.0.0/24), todo desde VPC (10.0.0.0/16) | Todo |
| `nginx-dracs` | TCP:80/443 (0.0.0.0/0), TCP:22 (VPN) | Todo |
| `alb-glpi-dracs` | TCP:80 (0.0.0.0/0), TCP:80 desde nginx SG | Todo |
| `glpi-dracs` | TCP:80 desde alb SG, todo desde VPN + on-prem | Todo |
| `rds-glpi-dracs` | TCP:3306 desde glpi SG | Todo |
| `efs-glpi-dracs` | TCP:2049 desde glpi SG | Todo |

## Archivos del proyecto

```
.
├── provider.tf         → AWS provider + backend S3 (comentado hasta bootstrap)
├── variables.tf        → region, key_name, ami_id, glpi_db_password
├── network.tf          → VPC, 4 subnets (2 AZs), NAT, IGW, rutas on-prem
├── security.tf         → 6 security groups
├── instances.tf        → WireGuard + Nginx EC2; selección de AMI (local.ami)
├── glpi_scaling.tf     → EFS, RDS, ALB, NLB, Launch Template, ASG
├── backend.tf          → S3 (tfstate) + DynamoDB (lock)
├── backups.tf          → S3 (backups app) + AMI snapshots WireGuard/Nginx
├── outputs.tf          → IPs, DNS, endpoints
└── user_data/
    ├── wireguard.sh        → Instala y configura WireGuard + iptables
    ├── nginx.sh.tpl        → Nginx → proxy al ALB (DNS inyectado por Terraform)
    └── glpi_asg.sh.tpl     → GLPI contra RDS + monta EFS (para ASG)
```

## Variables

| Variable | Default | Descripción |
|----------|---------|-------------|
| `region` | `us-east-1` | Región AWS |
| `key_name` | `dracs-keypair` | Key pair EC2 (debe existir en la cuenta) |
| `ami_id` | `""` | AMI custom para migración entre cuentas. Vacío = Ubuntu 24.04 LTS latest |
| `glpi_db_password` | *(requerida)* | Contraseña de la BD RDS de GLPI |
| `create_ami_backup` | `false` | Crear AMI snapshots de WireGuard y Nginx |

### Gestionar la contraseña sin pasarla en CLI

```bash
# Crear terraform.tfvars (ya ignorado por .gitignore, no se sube al repo)
cat > terraform.tfvars << 'EOF'
glpi_db_password = "TuPasswordSegura"
EOF

# O via variable de entorno
export TF_VAR_glpi_db_password="TuPasswordSegura"
```

## Despliegue

### Requisitos previos
- Key pair `dracs-keypair` creado en la cuenta AWS de destino
- AWS CLI configurado (`aws configure` o variables de entorno)
- Terraform >= 1.5.0

### Primer despliegue (cuenta nueva)

```bash
# 1. Crear terraform.tfvars con la contraseña
echo 'glpi_db_password = "TuPassword"' > terraform.tfvars

# 2. Inicializar providers
terraform init

# 3. Ver plan (opcional pero recomendado)
terraform plan

# 4. Aplicar — crea toda la infraestructura incluidos S3 y DynamoDB
terraform apply

# 5. Ver outputs con IPs y endpoints
terraform output
```

### Migración entre cuentas AWS (con AMI custom)

```bash
# 1. En la cuenta origen: crear AMIs de WireGuard y Nginx
terraform apply -var create_ami_backup=true

# 2. Copiar AMIs a la cuenta destino (ver AMI_BACKUP_GUIDE.md)

# 3. En la cuenta destino: desplegar con las AMIs migradas
echo 'ami_id           = "ami-0xxxxxxxxxxxxxxxxx"' >> terraform.tfvars
echo 'glpi_db_password = "TuPassword"'             >> terraform.tfvars
terraform init && terraform apply
```

### Activar backend remoto (S3 + DynamoDB)

```bash
# Tras el primer apply (que crea el bucket y la tabla):
# 1. Ver el nombre del bucket
terraform output tfstate_bucket

# 2. Descomentar el bloque backend en provider.tf y rellenar el account_id
# 3. Migrar el state local al bucket
terraform init -migrate-state
```

## Outputs principales

```bash
terraform output nlb_eip        # IP fija → configurar en DuckDNS
terraform output alb_dns        # DNS del ALB (acceso directo / debugging)
terraform output rds_endpoint   # Endpoint MariaDB RDS
terraform output efs_id         # ID del EFS compartido
terraform output wireguard_ip_publica
terraform output nginx_ip_publica
```

## Troubleshooting

### GLPI no responde tras el deploy
- El ASG tarda ~3-5 min en arrancar la instancia y ejecutar el user_data
- Verificar: AWS Console → EC2 → Auto Scaling Groups → `asg-glpi-dracs` → Activity
- Ver logs de cloud-init en la instancia: `tail -f /var/log/cloud-init-output.log`

### ALB health checks failing
- GLPI necesita unos minutos para inicializarse (RDS + EFS mount + install)
- Grace period del ASG: 300 segundos
- Comprobar que el path `/glpi/` devuelve 200 o 302: `curl -I http://<alb_dns>/glpi/`

### Nginx no llega al GLPI (tráfico WireGuard)
- `nginx -t` en la instancia — verificar que el proxy_pass tiene el DNS del ALB correcto
- El DNS del ALB se inyecta en el user_data en tiempo de `terraform apply`
- Si se recreó el ALB tras crear Nginx: re-aplicar Terraform para actualizar el user_data

### WireGuard no conecta tras migrar de cuenta
- El EIP del WireGuard cambia en cada cuenta → actualizar el Endpoint en OPNsense
- `terraform output wireguard_ip_publica` → nuevo EIP

## Roadmap

- [x] Backend Terraform remoto (S3 + DynamoDB)
- [x] ALB + ASG multi-AZ para GLPI
- [x] RDS MariaDB (BD fuera del ASG)
- [x] EFS para ficheros compartidos
- [x] NLB con EIP fija (para DuckDNS)
- [x] AMI parametrizable para migración entre cuentas
- [ ] HTTPS en ALB (certificado ACM + dominio DuckDNS verificado)
- [ ] VPC Flow Logs para observabilidad
- [ ] Route53 Privado para DNS interno
- [ ] CloudWatch Alarms (CPU, RDS connections, ALB 5xx)
- [ ] IAM Roles para instancias EC2 (acceso S3 sin credenciales hardcoded)
- [ ] Multi-AZ RDS (alta disponibilidad de la BD)

---

**Proyecto**: DRACS — ASIX2, INS Provençana, 2026
**Terraform**: >= 1.5.0 | **AWS Provider**: ~> 6.0
