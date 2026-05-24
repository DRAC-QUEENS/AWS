# AWS DRACS Hybrid Infrastructure

Infraestructura AWS del proyecto DRACS (ASIX2). Stack híbrido: GLPI multi-AZ tras NLB+ALB con TLS termination en ACM, RDS MariaDB y EFS compartido, conectado al cluster Proxmox on-prem mediante túnel WireGuard site-to-site. Backend Terraform remoto en S3 con locking DynamoDB.

## Arquitectura

```
                                  Internet
                                     │
                       DuckDNS A: dracs-glpi.duckdns.org  →  35.175.33.121
                                     │
                              ┌──────┴──────┐
                              │     IGW     │
                              └──────┬──────┘
   ╔════════════════════ VPC dracs · 10.0.0.0/16 (us-east-1) ════════════════════╗
   ║                                 │                                           ║
   ║                       ┌─────────┴────────┐                                  ║
   ║                       │  NLB (EIP fija)  │  public-a · single-AZ            ║
   ║                       │  TCP :80, :443   │  (la EIP solo puede vivir en 1)  ║
   ║                       └─────────┬────────┘                                  ║
   ║                                 ▼                                           ║
   ║                       ┌──────────────────┐                                  ║
   ║                       │   ALB cross-AZ   │  public-a + public-b             ║
   ║                       │ :80 → 301 → :443 │  TLS termina aquí                ║
   ║                       │ :443 → cert ACM  │  (Let's Encrypt, DNS-01)         ║
   ║                       └────┬───────┬─────┘                                  ║
   ║          ┌─────────────────┘       └────────────────┐                       ║
   ║          ▼                                          ▼                       ║
   ║   ┌───────── AZ us-east-1a ────────┐   ┌──────── AZ us-east-1b ───────┐     ║
   ║   │ PRIVATE 10.0.2.0/24            │   │ PRIVATE 10.0.4.0/24          │     ║
   ║   │  ┌─────────────────────────┐   │   │  ┌─────────────────────────┐ │     ║
   ║   │  │ GLPI t3.small (ASG)     │◀──┼───┼─▶│ GLPI t3.small (ASG)     │ │     ║
   ║   │  │  Apache :80 (HTTP plano)│   │   │  │  Apache :80 (HTTP plano)│ │     ║
   ║   │  └─────┬─────────────┬─────┘   │   │  └────┬─────────────┬──────┘ │     ║
   ║   │       MySQL          NFS       │   │      NFS         (no RDS)    │     ║
   ║   │        │             │         │   │        │                     │     ║
   ║   │   ┌────▼──────┐  ┌───▼──────┐  │   │   ┌────▼─────┐               │     ║
   ║   │   │ RDS       │  │ EFS mt-a │──┼───┼──▶│ EFS mt-b │ (mismo FS)    │     ║
   ║   │   │ MariaDB   │  └──────────┘  │   │   └──────────┘               │     ║
   ║   │   │ t3.micro  │                │   │                              │     ║
   ║   │   └───────────┘                │   │                              │     ║
   ║   └────────────────────────────────┘   └──────────────────────────────┘     ║
   ║                                                                             ║
   ║   PUBLIC 10.0.1.0/24 (AZ-a · housekeeping)                                  ║
   ║   ┌──────────────────────────┐                                              ║
   ║   │ WireGuard EC2 (EIP)      │ ◀── UDP 51820 ─── OPNsense on-prem           ║
   ║   │ 10.0.1.10                │                                              ║
   ║   │                          │                                              ║
   ║   │ Nginx EC2  ──  10.0.1.20 │ ── redirige tráfico interno (HTTP →          ║
   ║   │                          │    301 https://dracs-glpi.duckdns.org)       ║
   ║   │                          │                                              ║
   ║   │ NAT GW (EIP)             │ ── egress de las subnets privadas            ║
   ║   └──────────────────────────┘                                              ║
   ╚═══════════════════════════════│═════════════════════════════════════════════╝
                                   ▼ WireGuard tunnel · 10.8.0.0/24
                          OPNsense on-prem · 192.168.{1,10,20}.0/24
```

**Flujos principales:**

- **Externo**: Internet → DuckDNS → NLB EIP → ALB (TLS) → ASG GLPI :80 → RDS+EFS.
- **Interno (on-prem)**: cliente → OPNsense → WG tunnel → o bien Nginx (HTTP) que devuelve 301 al dominio público, o bien directo al ALB; en ambos casos el cert público sirve a todo el mundo.

## Componentes

| Componente | Detalle | Doc |
|---|---|---|
| **WireGuard EC2** | t3.micro · EIP · UDP 51820 · `source_dest_check=false` | `docs/aws/AWS-VPN.md` |
| **Nginx EC2** | t3.micro · 10.0.1.20 · sólo `return 301` al dominio público | `docs/aws/AWS-VPN.md` |
| **NLB** | EIP fija para DuckDNS · TCP 80/443 → ALB · sin SG propio | `docs/aws/AWS-BALANCEO.md` |
| **ALB** | Multi-AZ · `:80 → 301 :443` · ACM Let's Encrypt | `docs/aws/AWS-BALANCEO.md` |
| **ASG GLPI** | Launch Template t3.small · min=2, max=4 · Target Tracking CPU 60% · AMI Packer | `docs/aws/AWS-GLPI.md` |
| **RDS** | MariaDB 10.11 · db.t3.micro · 20GB gp3 · backups 7d | `docs/aws/AWS-GLPI.md` |
| **EFS** | NFS compartido entre AZs · `/mnt/efs/{files,plugins,letsencrypt}` | `docs/aws/AWS-GLPI.md` |
| **ACM** | Cert Let's Encrypt importado · `most_recent=true` data source | `docs/aws/AWS-BALANCEO.md` |

**Bootstrap de las instancias del ASG**: el `user_data` es idempotente y reaplica en cada arranque — monta EFS, restaura `glpicrypt.key` y `/etc/letsencrypt` desde EFS, escribe `config_db.php` y el VirtualHost Apache, lanza `db:install` con `flock` (evita race entre instancias arrancando a la vez), y arranca Apache. Si la AMI es Packer arranca en ~2 min; con Ubuntu vanilla ~10 min.

## Security Groups

| SG | Ingress |
|----|---------|
| `wireguard-dracs` | UDP:51820 (0.0.0.0/0), todo desde VPC y desde 10.8.0.0/24 |
| `nginx-dracs` | TCP:80 y :22 desde 10.8.0.0/24 y on-prem (192.168.{1,10,20}.0/24) |
| `alb-glpi-dracs` | TCP:80, TCP:443 (0.0.0.0/0); TCP:80 desde nginx SG |
| `glpi-dracs` | TCP:80 desde alb SG; todo desde 10.8.0.0/24 y on-prem |
| `rds-glpi-dracs` | TCP:3306 desde glpi SG |
| `efs-glpi-dracs` | TCP:2049 desde glpi SG |

Detalle completo en `docs/aws/AWS-SEGURIDAD.md`.

## Variables

| Variable | Default | Notas |
|---|---|---|
| `region` | `us-east-1` | |
| `key_name` | `dracs-keypair` | En la cuenta actual: `dracs3` |
| `glpi_ami_id` | `""` | AMI Packer; vacío = Ubuntu 24.04 vanilla (boot ~10 min) |
| `asg_desired` | `2` | Bajar a 0 durante mantenimiento |
| `glpi_public_url` | `https://dracs-glpi.duckdns.org` | Se fuerza en `url_base` de GLPI cada arranque |
| `glpi_db_password` | *(sensitive)* | |
| `wg_aws_private_key` / `wg_opnsense_public_key` / `wg_preshared_key` | *(sensitive)* | Claves del túnel |

Los secretos viven en `terraform.tfvars` (gitignored). Ejemplo:

```hcl
key_name           = "dracs3"
glpi_ami_id        = "ami-..."
asg_desired        = 2
glpi_db_password   = "..."
wg_aws_private_key = "..."
# ...
```

## Despliegue

```bash
# 1. Configurar credenciales y crear terraform.tfvars
$EDITOR terraform.tfvars

# 2. Init (state local hasta el primer apply)
terraform init

# 3. Plan + apply
terraform plan
terraform apply

# 4. Migrar state al backend remoto (S3 + DynamoDB ya creados por el apply)
#    Descomentar bloque backend "s3" en provider.tf con el account_id correcto
terraform init -migrate-state

# 5. Ver outputs
terraform output
```

**Migración entre cuentas AWS**: aplicada dos veces (`947411159788` → `123561366922` → `563771271989`). Procedimiento detallado en `docs/aws/AWS-TERRAFORM.md` §5.

## Outputs

```bash
terraform output nlb_eip               # → DuckDNS A-record
terraform output alb_dns               # → debug HTTPS directo
terraform output rds_endpoint          # → MariaDB
terraform output efs_id                # → mount NFS desde fuera del stack
terraform output wireguard_ip_publica  # → OPNsense peer Endpoint
```

## Troubleshooting

**GLPI no responde tras deploy** — el ASG tarda 3-5 min en arrancar y pasar el health check (Packer AMI ~2 min, Ubuntu vanilla ~10 min). Logs vía SSM: `aws ssm start-session --target <i-…>` → `tail -f /var/log/cloud-init-output.log`.

**Health checks ALB en `unhealthy`** — `curl -I https://dracs-glpi.duckdns.org/` debería dar 200/302. Si es 404, el `url_base` en BD apunta al path antiguo (`/glpi`): el `user_data` lo corrige cada boot, pero si se acaba de importar un dump puede aparecer. Manual: `UPDATE glpi_configs SET value='https://dracs-glpi.duckdns.org' WHERE name='url_base';`.

**Asset CSS no carga** — el VirtualHost de Apache debe tener `DocumentRoot /var/www/html/glpi` (modo legacy GLPI 10), no `/public`.

**Auth LDAP/AD falla** — comprobar TCP/389 al DC: `bash -c "</dev/tcp/192.168.10.10/389"`. Si ICMP llega pero TCP no, el firewall del DC bloquea la subnet privada; añadir `10.0.0.0/16` al scope LDAP/Kerberos. También verificar `glpicrypt.key` en `/var/www/html/glpi/config/` — sin él GLPI no descifra la pass LDAP.

**WireGuard no conecta tras migrar de cuenta** — el EIP de WG cambia; actualizar el `Endpoint` del peer en OPNsense (`terraform output wireguard_ip_publica`). Las claves WG son las mismas (`terraform.tfvars`).

Más en `docs/aws/AWS-RUNBOOK.md` y `docs/aws/PROBLEMAS-INFRA.md`.

## Documentación

- `docs/aws/AWS.md` — visión general y decisiones de diseño
- `docs/aws/AWS-RED.md` — VPC, subnets, route tables, NAT, IGW
- `docs/aws/AWS-BALANCEO.md` — NLB, ALB, ACM, TLS termination
- `docs/aws/AWS-GLPI.md` — ASG, Launch Template, RDS, EFS, user_data
- `docs/aws/AWS-VPN.md` — WireGuard site-to-site
- `docs/aws/AWS-SEGURIDAD.md` — SGs, IAM, cifrado, secretos
- `docs/aws/AWS-TERRAFORM.md` — IaC, state remoto, migración entre cuentas
- `docs/aws/AWS-RUNBOOK.md` — procedimientos operativos recurrentes
- `docs/aws/AWS-COSTES.md` — estimación mensual y palancas de ahorro
- `docs/aws/AWS-STRESS-TEST.md` — validación manual del autoescalado
- `docs/aws/PROBLEMAS-INFRA.md` — incidentes resueltos y lecciones
- `docs/aws/AWS-HISTORICO-MONOLITICA.md` — versión anterior monolítica (referencia histórica)

## Roadmap

- [x] Backend Terraform remoto · ALB+ASG multi-AZ · RDS+EFS · NLB con EIP · TLS Let's Encrypt
- [x] AMI Packer con GLPI pre-instalado · Target Tracking CPU
- [x] Persistencia del cert TLS en EFS
- [ ] Renovación automatizada del cert (cron + re-import ACM)
- [ ] VPC Flow Logs · CloudWatch Alarms (CPU, RDS, ALB 5xx)
- [ ] Multi-AZ RDS

---

**Proyecto**: DRACS — ASIX2, INS Provençana, 2026
**Terraform**: ≥ 1.5.0 · **AWS Provider**: ~> 6.0
