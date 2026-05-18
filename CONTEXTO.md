# DRACS — Contexto de infraestructura AWS

> Actualizado: 2026-05-18  
> Cuenta activa: **123561366922** (la nueva)  
> Cuenta antigua desactivada: 947411159788

---

## Resumen de arquitectura

```
Internet
  └─ NLB (EIP fija: 50.19.112.122 → DuckDNS: dracs-glpi.duckdns.org)
       └─ ALB (alb-glpi-dracs, interno distribución L7)
            └─ ASG GLPI (2 × t3.small, una por AZ, subnet privada)
                 ├─ RDS MariaDB 10.11 (rds-glpi-dracs, subnet privada)
                 └─ EFS (fs-00891f16aba18e12b, compartido entre instancias)

On-prem (OPNsense) ←─WireGuard site-to-site─→ EC2 WireGuard (10.0.1.10)
  └─ Nginx (10.0.1.20) redirige HTTP → https://dracs-glpi.duckdns.org
```

---

## IPs y endpoints

| Recurso | IP/DNS | Notas |
|---|---|---|
| WireGuard EC2 | EIP **34.204.119.208** | Puerto 51820/UDP |
| Nginx EC2 | IP privada **10.0.1.20** | Solo accesible vía VPN; redirige a la URL pública |
| NLB | EIP **50.19.112.122** | DuckDNS apunta aquí |
| ALB | alb-glpi-dracs-949041849.us-east-1.elb.amazonaws.com | L7, TLS termina aquí |
| RDS | rds-glpi-dracs.capsrvyl1db1.us-east-1.rds.amazonaws.com | Puerto 3306 |
| EFS | fs-00891f16aba18e12b.efs.us-east-1.amazonaws.com | NFS puerto 2049 |
| GLPI URL | https://dracs-glpi.duckdns.org | TLS via ACM + certbot |

### IPs privadas fijas (EC2)
| Instancia | IP privada | Subnet |
|---|---|---|
| WireGuard | 10.0.1.10 | pública-a |
| Nginx | 10.0.1.20 | pública-a |
| GLPI (ASG) | dinámica en 10.0.2.0/24 o 10.0.4.0/24 | privada-a / privada-b |

> Las instancias del ASG GLPI no tienen IP fija; se obtienen con:
> ```
> aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names asg-glpi-dracs \
>   --query 'AutoScalingGroups[0].Instances[*].InstanceId' --output text
> ```

---

## Redes

| Subnet | CIDR | AZ | Tipo |
|---|---|---|---|
| subnet-publica-a | 10.0.1.0/24 | us-east-1a | pública |
| subnet-publica-b | 10.0.3.0/24 | us-east-1b | pública |
| subnet-privada-a | 10.0.2.0/24 | us-east-1a | privada |
| subnet-privada-b | 10.0.4.0/24 | us-east-1b | privada |

Redes on-prem enrutadas via WireGuard:
- `192.168.1.0/24`
- `192.168.10.0/24`
- `192.168.20.0/24`

Interfaz VPN (WireGuard):
- AWS: `10.8.0.2/24`
- OPNsense peer: `10.8.0.1/32`

---

## Acceso a instancias

### Opción 1: SSM Session Manager (recomendada, sin VPN ni SG)

```bash
# Shell directo
aws ssm start-session --target i-0bc21dfec3bfa79eb --region us-east-1  # WireGuard
aws ssm start-session --target $(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names asg-glpi-dracs --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text) --region us-east-1  # GLPI (ID dinámico)

# SSH via SSM (requiere session-manager-plugin instalado)
ssh wireguard-dracs
ssh glpi-dracs
```

> **NOTA:** Nginx NO tiene LabInstanceProfile → SSM no disponible en Nginx.

Para instalar el plugin de SSM:
```bash
# Ubuntu/Debian
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o /tmp/ssm-plugin.deb
sudo dpkg -i /tmp/ssm-plugin.deb
```

### Opción 2: SSH via proxy-jump por Nginx (sin VPN)

El SG de GLPI permite todo el tráfico desde el SG de Nginx ("Proxy-Jump").  
Nginx actúa como bastión: SSH entra a Nginx y desde ahí salta a GLPI en la subnet privada.

**Cómo funciona el proxy-jump:**
SSH abre un túnel TCP cifrado a través del bastión. La clave privada **no se copia** al bastión — con `ForwardAgent`/`AddKeysToAgent` el agente SSH local la ofrece de forma segura para autenticar el segundo salto.

**Paso a paso para que funcione:**

```bash
# 1. Añadir la clave al agente SSH local (solo hay que hacerlo una vez por sesión)
ssh-add ~/.ssh/dracs2.pem

# 2. Conectar directamente con el alias del config (hace todo automático)
ssh glpi-dracs-jump

# O en una sola línea sin config:
ssh -A -J ubuntu@34.205.176.217 -i ~/.ssh/dracs2.pem ubuntu@<ip-privada-glpi>
```

**Por qué falla sin `-A` (o sin `AddKeysToAgent`):**
Sin agent forwarding, cuando Nginx intenta autenticarse en GLPI, no tiene la clave — la tienes tú en tu máquina local. El error típico es `Permission denied (publickey)` en el segundo salto aunque el primero funcione.

**El `~/.ssh/config` ya lo tiene configurado:**
```
Host nginx-dracs          ← bastión (primer salto)
  AddKeysToAgent yes      ← añade la clave al agente automáticamente

Host glpi-dracs-jump      ← destino final
  ProxyJump nginx-dracs   ← le dice a SSH que pase por nginx-dracs
```
Con esto basta con `ssh glpi-dracs-jump` y SSH gestiona los dos saltos solo.

**Limitación:** el SG de Nginx solo permite SSH desde `10.8.0.0/24` (VPN) y `192.168.x.x` (on-prem). Si no tienes la VPN activa ni estás en on-prem, usa la opción SSM.

---

### Opción 3: SSH directo (requiere túnel WireGuard activo)

```bash
# GLPI acepta SSH desde 192.168.x.x (on-prem) si VPN está up
ssh -i ~/.ssh/dracs2.pem ubuntu@<ip-privada-glpi>

# Nginx y WireGuard solo desde 10.8.0.0/24 (el propio OPNsense)
```

### Key pair
- Nombre en AWS: `dracs2`
- Fichero local: `~/.ssh/dracs2.pem`
- Usuario SSH en todas las instancias: `ubuntu`

---

## WireGuard VPN

Config en `/etc/wireguard/wg0.conf` de la EC2 (generada por Terraform):

```ini
[Interface]
Address = 10.8.0.2/24
ListenPort = 51820
PrivateKey = <wg_aws_private_key>   # en terraform.tfvars

[Peer]
PublicKey = <wg_opnsense_public_key>  # en terraform.tfvars
PreSharedKey = <wg_preshared_key>     # en terraform.tfvars
AllowedIPs = 10.8.0.1/32,192.168.1.0/24,192.168.10.0/24,192.168.20.0/24
PersistentKeepalive = 25
```

**Al migrar de cuenta:** solo hay que actualizar el Endpoint en OPNsense al nuevo EIP (`34.204.119.208`). Las claves son las mismas.

**Diagnóstico rápido:**
```bash
# En la EC2 WireGuard (via SSM):
sudo wg show
```

---

## Estado de problemas conocidos

| Problema | Estado | Resolución |
|---|---|---|
| GLPI auth LDAP/AD falla | ✅ RESUELTO | Windows Firewall del DC bloqueaba TCP/389 desde las subnets nuevas. Se amplió el scope a `10.0.0.0/16` en las reglas inbound del DC. |
| CSS roto (GLPI sin estilos) | ✅ RESUELTO | `DocumentRoot` cambiado de `/public` a `/var/www/html/glpi` (modo legacy GLPI 10). |
| 404 tras login (`/glpi`) | ✅ RESUELTO | `url_base` en BD apuntaba a ruta antigua. Se fuerza en cada arranque del ASG via `user_data`. |
| `glpicrypt.key` no encontrada | ✅ RESUELTO | `user_data` restaura desde EFS `/_meta/config/` en cada arranque. |
| WireGuard no establecía handshake | ✅ RESUELTO | OPNsense apuntaba al EIP de la cuenta vieja. Actualizado a `34.204.119.208:51820`. |
| ACM no encontraba el cert ECDSA | ✅ RESUELTO | `key_types = ["EC_prime256v1", "EC_secp384r1"]` en `data "aws_acm_certificate"`. |
| NLB→ALB race condition en `apply` | ✅ RESUELTO | Añadido `depends_on = [aws_lb_listener.alb_http]` al `target_group_attachment`. |
| Nginx cert autofirmado (aviso navegador) | ✅ RESUELTO | Nginx ya no sirve tráfico de aplicación; redirige al dominio público con cert ACM válido. |
| ASG health-check falla en instancias nuevas | ✅ RESUELTO | GLPI requería subdirectorios en EFS (`_plugins`, `_sessions`, etc.) antes de `db:install`. El `user_data` los pre-crea. |
| Regla iptables huérfana en WG EC2 | ⚠️ INOFENSIVA | Regla `MASQUERADE` en `eth0` (interfaz correcta es `ens5`). Se acumula con reinicios pero no afecta al funcionamiento. Para limpiar: `sudo iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE` |
| Cert TLS renovación automatizada | 🔲 PENDIENTE | Let's Encrypt caduca cada 90 días (próxima caducidad ~2026-08-09). Ver `AWS-RUNBOOK.md` sección 5. Mitigado parcialmente con persistencia en EFS desde Sprint 5 (las instancias nuevas heredan el cert sin reinstalar certbot). |
| GLPI redirige a `/glpi` y da 404 | ✅ RESUELTO | Sprint 5: el VirtualHost de Apache trae `RewriteRule ^/glpi/?(.*)$ /$1 [R=301,L]` que se reescribe en cada arranque (Paso 7 del `user_data/glpi_asg.sh.tpl`). |

---

## Variables Terraform (referencias, no valores)

Fichero `terraform.tfvars` está gitignored. Variables necesarias:

| Variable | Descripción |
|---|---|
| `key_name` | `dracs2` |
| `glpi_ami_id` | AMI Packer con GLPI pre-instalado (vacío = Ubuntu 24.04 LTS latest) |
| `asg_desired` | 0 durante mantenimiento, 2 en producción (una instancia por AZ) |
| `glpi_db_password` | Contraseña RDS |
| `wg_aws_private_key` | Clave privada WireGuard AWS |
| `wg_opnsense_public_key` | Clave pública del peer OPNsense |
| `wg_preshared_key` | PSK del túnel |

---

## IDs de recursos clave (cuenta 123561366922)

| Recurso | ID |
|---|---|
| VPC | vpc-dracs |
| EFS | fs-00891f16aba18e12b |
| RDS | rds-glpi-dracs |
| ASG | asg-glpi-dracs |
| ALB | alb-glpi-dracs |
| NLB | nlb-glpi-dracs |
| EC2 WireGuard | i-0bc21dfec3bfa79eb |
| EC2 Nginx | i-0826d318ae07dfe40 |
| AMI GLPI (Packer) | ami-0f69b2f6a15d477e3 |
| EC2 GLPI | dinámico (ASG); recupera con `aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names asg-glpi-dracs` |

---

## Comandos de diagnóstico rápido

```bash
# Estado general de instancias
aws ec2 describe-instances --region us-east-1 \
  --query 'Reservations[*].Instances[*].{Name:Tags[?Key==`Name`]|[0].Value,State:State.Name,PrivateIP:PrivateIpAddress,PublicIP:PublicIpAddress}' \
  --output table

# Salud del target group GLPI
aws elbv2 describe-target-health --region us-east-1 \
  --target-group-arn arn:aws:elasticloadbalancing:us-east-1:123561366922:targetgroup/tg-glpi-dracs/8f84735419d18c83 \
  --output table

# Shell en GLPI sin SSH ni VPN (ID dinámico del ASG)
aws ssm start-session --region us-east-1 --target \
  $(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names asg-glpi-dracs \
    --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)

# Shell en WireGuard sin SSH ni VPN
aws ssm start-session --target i-0bc21dfec3bfa79eb --region us-east-1
```

---

## Histórico de trabajo por sesión

### Sprint 2 (antes de 2026-05-12)
- Desplegada arquitectura simple (`simple/`): 3 EC2 en subnet pública (WireGuard 10.0.1.10, Nginx 10.0.1.20, GLPI 10.0.1.30), VPN WireGuard operativa, autenticación LDAP verificada contra el DC.
- GLPI accesible en `https://dracs-glpi.duckdns.org` con cert autofirmado en Nginx.
- Cuenta AWS: **947411159788**.

### Sprint 3 — Migración y nueva arquitectura (2026-05-12)
**Migración de cuenta 947411159788 → 123561366922:**
- Código Terraform refactorizado (variables simplificadas, `wireguard_ami_id` / `nginx_ami_id`, `asg_desired`).
- AMIs de WireGuard y Nginx re-cifradas con CMK `alias/dracs-glpi-share-key` y compartidas con la cuenta destino.
- Nueva arquitectura desplegada: VPC multi-AZ, 4 subnets, NLB+ALB, ASG GLPI, RDS MariaDB, EFS, NAT Gateway.
- EC2 migrator temporal: `mysqldump` de MariaDB local → RDS; `rsync /files/` → EFS; copia `glpicrypt.key` y `config/` → EFS `/_meta/config/`.
- Segundo migrator: `glpicrypt.key` no estaba en el primer rsync → se copió `config/` completo.
- Cert TLS Let's Encrypt emitido con certbot DNS-01 + plugin `certbot-dns-duckdns`, importado a ACM.
- GLPI operativo en `https://dracs-glpi.duckdns.org` con TLS válido.
- Auth LDAP rota → causa: Windows Firewall del DC limitaba el scope a la subnet antigua. Fix: ampliar a `10.0.0.0/16`.
- GLPI 100% funcional con autenticación AD. Cuenta vieja **947411159788** desactivada.

**Fixes técnicos en el código:**
- `DocumentRoot` de Apache cambiado a `/var/www/html/glpi` (modo legacy) — GLPI 10.0.x hardcodea `public/` en URLs de assets.
- `depends_on = [aws_lb_listener.alb_http]` en NLB→ALB attachment (race condition en `terraform apply`).
- `key_types = ["EC_prime256v1", "EC_secp384r1", "RSA_2048"]` en `data "aws_acm_certificate"`.
- `user_data` fuerza `url_base` en BD en cada arranque (evita redireccionamiento a `/glpi` post-migración).

### Sprint 4 — Simplificación y AMI Packer (2026-05-14)

**Objetivo:** limpiar la infra, eliminar complejidad heredada de la migración y mejorar el tiempo de arranque del ASG.

**Cambios principales:**
- **Nginx simplificado:** de reverse proxy con cert autofirmado (causa de los warnings en navegador normal) a redirector HTTP→HTTPS puro. Sin `proxy_pass`, sin `openssl`. La EIP de Nginx eliminada; solo accesible en `10.0.1.20` vía VPN.
- **Packer AMI** (`ami-0f69b2f6a15d477e3`): Ubuntu 24.04 + Apache + PHP 8.3 + GLPI 10.0.18 pre-instalados. Tiempo de arranque de instancias: ~2 min vs ~8-10 min con descarga en caliente.
- **EFS restructurado:** montaje único en `/mnt/efs` + symlinks `glpi/files → /mnt/efs/files` y `glpi/plugins → /mnt/efs/plugins`. Los plugins de GLPI ahora también son compartidos entre instancias del ASG.
- **`user_data` simplificado:** instalación condicional (salta `apt-get` y descarga si el AMI Packer ya lo trae). Pre-crea todos los subdirectorios que GLPI necesita en EFS antes de `db:install` (fix del race condition de health-check).
- **AMI backups eliminados:** la función de backup de AMIs (`create_ami_backup`) era innecesaria con RDS y EFS.
- **Variables limpias:** eliminadas `wireguard_ami_id` y `nginx_ami_id` (migración ya completada); añadida `glpi_ami_id`.
- **ASG desired = 2:** una instancia por AZ para alta disponibilidad real.
- **ACM simplificado:** `key_types = ["EC_prime256v1", "EC_secp384r1"]` (sin RSA).
- **`glpicrypt.key` en EFS** (`files/_meta/config/`): se restaura automáticamente en cada arranque. Protege las integraciones LDAP/SMTP contra recreación de instancias.

**Nota técnica — SQL vía SSM:**
El paso de SQL con comillas simples a través del array `commands` de SSM es propenso a bugs de quoting (`'; WHERE` en vez de `' WHERE` convierte un UPDATE con WHERE en un UPDATE sin WHERE que sobreescribe toda la tabla). La solución definitiva: codificar el SQL en base64 y decodificarlo en el pipe de mysql.
```bash
echo "<sql_en_base64>" | base64 -d | mysql -h $RDS -u $USER -p$PASS $DB
```

### Sprint 5 — Autoescalado, redirect `/glpi` y persistencia del cert (2026-05-18)

**Objetivo:** cerrar los flecos operativos pendientes tras Sprint 4.

**Cambios principales:**

- **Política de autoescalado por CPU.** Se ha añadido un `aws_autoscaling_policy` tipo `TargetTrackingScaling` al ASG con target del 60 % sobre `ASGAverageCPUUtilization`. AWS crea las alarmas CloudWatch internas automáticamente; no hace falta declararlas. El target del 60 % deja margen para absorber el pico mientras arranca la siguiente instancia (~2 min con la AMI Packer).
- **Redirect `/glpi` → `/` en Apache.** Algunos navegadores con caché del path antiguo (`https://dracs-glpi.duckdns.org/glpi`) recibían un 404. Se añade `RewriteRule ^/glpi/?(.*)$ /$1 [R=301,L]` al VirtualHost del `user_data` (Paso 7), que se reescribe en cada arranque para cubrir tanto instalaciones frescas como instancias desde la AMI Packer.
- **Persistencia del cert TLS en EFS.** Sin esto, cada vez que el ASG reemplaza una instancia se pierde `/etc/letsencrypt` (vive en el disco efímero). El `user_data` ahora instala certbot y, si encuentra `/mnt/efs/letsencrypt/live/`, copia los ficheros a `/etc/letsencrypt`. Tras emitir/renovar manualmente el cert hay que sincronizarlo a EFS con `cp -a /etc/letsencrypt/. /mnt/efs/letsencrypt/` para que sobreviva al siguiente reemplazo.
- **Consolidación de políticas de escalado.** Se intentó dividir las políticas en un fichero `autoscaling_policies.tf` con alarmas adicionales por request rate y unhealthy hosts, pero se revirtió por simplicidad: la política CPU sola es suficiente para el alcance del proyecto y vive en `glpi_scaling.tf` junto al resto del stack.
- **Documentación reorganizada.** Se añade `INFRAESTRUCTURA.md` en la raíz como guía pedagógica de la infraestructura completa con referencias a cada fichero `.tf`. Se eliminan `EXPLICACION_INFRAESTRUCTURA.md` y `POST_DEPLOYMENT.md` (contenido obsoleto, integrado en el resto de docs).

**Procedimiento para aplicar el redirect a instancias en ejecución (sin instance refresh):**

El cambio en `user_data` solo afecta a instancias nuevas. Para parchear una instancia ya en marcha sin esperar al reemplazo, se puede usar `aws ssm send-command` codificando el nuevo VirtualHost en base64 (ver `AWS-RUNBOOK.md` sección 7).

### Documentación (2026-05-13)
Generados 10 documentos en `docs/aws/` siguiendo el estilo de documentación del proyecto (tono narrativo, tablas, `> Nota:`, sección "Documentación relacionada"):

| Fichero | Contenido |
|---|---|
| `AWS.md` | Visión general, diagrama ASCII, decisiones de diseño, problemas encontrados |
| `AWS-RED.md` | VPC, subnets, IGW, NAT, route tables, rutas on-prem |
| `AWS-VPN.md` | EC2 WireGuard + EC2 Nginx, user_data, iptables |
| `AWS-BALANCEO.md` | NLB, ALB, target groups, cert TLS (certbot+ACM+DuckDNS) |
| `AWS-GLPI.md` | Launch Template, user_data idempotente, ASG, RDS, EFS, migrator |
| `AWS-SEGURIDAD.md` | Security Groups (6), IAM, KMS CMK, secretos |
| `AWS-TERRAFORM.md` | Estructura IaC, variables, backend S3+DynamoDB, migración entre cuentas |
| `AWS-RUNBOOK.md` | SSM, reemplazo ASG, renovación cert, escalado, troubleshooting |
| `AWS-SIMPLE.md` | Arquitectura previa Sprint 2 (monolítica), comparativa con la actual |
| `AWS-COSTES.md` | Estimación mensual arquitectura simple (~69 $) vs actual (~98 $), comparativa, alarmas |

**Diagrama de arquitectura:**
- Script `docs/aws/generar_diagrama.py` (Python `diagrams` library) genera `aws-arquitectura.png` con iconografía AWS oficial.
- Ejecutar: `python3 docs/aws/generar_diagrama.py` (requiere `pip install diagrams` + `graphviz`).

**Correcciones en `simple/`:**
- Añadida `subnet-privada-dracs` (10.0.2.0/24) — el GLPI estaba en la pública por error.
- EC2 GLPI movida a subnet privada (`10.0.2.30`).
- NAT Gateway y route table privada añadidos al Terraform (justificación: GLPI privado necesita NAT para salir a internet en el arranque).
