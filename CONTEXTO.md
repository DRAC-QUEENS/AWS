# DRACS — Contexto de infraestructura AWS

> Actualizado: 2026-05-12  
> Cuenta activa: **123561366922** (la nueva)  
> Cuenta antigua desactivada: 947411159788

---

## Resumen de arquitectura

```
Internet
  └─ NLB (EIP fija: 50.19.112.122 → DuckDNS: dracs-glpi.duckdns.org)
       └─ ALB (alb-glpi-dracs, interno distribución L7)
            └─ ASG GLPI (1-3 × t3.small, subnet privada)
                 ├─ RDS MariaDB 10.11 (rds-glpi-dracs, subnet privada)
                 └─ EFS (fs-0e3a12b50ac2f89b3, compartido entre instancias)

On-prem (OPNsense) ←─WireGuard site-to-site─→ EC2 WireGuard (10.0.1.10)
  └─ Nginx (10.0.1.20) actúa como proxy HTTP hacia el ALB para tráfico interno
```

---

## IPs y endpoints

| Recurso | IP/DNS | Notas |
|---|---|---|
| WireGuard EC2 | EIP **34.204.119.208** | Puerto 51820/UDP |
| Nginx EC2 | EIP **34.205.176.217** | Proxy HTTP → ALB |
| NLB | EIP **50.19.112.122** | DuckDNS apunta aquí |
| ALB | alb-glpi-dracs-949041849.us-east-1.elb.amazonaws.com | L7, TLS termina aquí |
| RDS | rds-glpi-dracs.capsrvyl1db1.us-east-1.rds.amazonaws.com | Puerto 3306 |
| EFS | fs-0e3a12b50ac2f89b3.efs.us-east-1.amazonaws.com | NFS puerto 2049 |
| GLPI URL | https://dracs-glpi.duckdns.org | TLS via ACM + certbot |

### IPs privadas fijas (EC2)
| Instancia | IP privada | Subnet |
|---|---|---|
| WireGuard | 10.0.1.10 | pública-a |
| Nginx | 10.0.1.20 | pública-a |
| GLPI (ASG, actual) | 10.0.4.131 | privada-b |

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
aws ssm start-session --target i-08bc1c7d44b3319bc --region us-east-1  # GLPI

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
ssh -A -J ubuntu@34.205.176.217 -i ~/.ssh/dracs2.pem ubuntu@10.0.4.131
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
ssh -i ~/.ssh/dracs2.pem ubuntu@10.0.4.131

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

## Problema pendiente: GLPI no autentifica via DC

**Síntoma:** la autenticación LDAP/AD contra el DC on-prem falla tras migrar a la nueva cuenta y nueva arquitectura.

**Lo que se sabe:**
- El túnel WireGuard levanta correctamente y hay ping.
- Antes de la migración (arquitectura simple, cuenta vieja) la auth LDAP funcionaba.
- El DC responde (puerto 389 verificado en el pasado).

**Hipótesis más probable:**
El DC estaba registrado en GLPI con las credenciales LDAP, pero GLPI cifra la config sensible (contraseña LDAP, etc.) con `glpicrypt.key`. Si la clave se migró correctamente al EFS, debería funcionar. Si no, GLPI no puede descifrar la contraseña del DC y falla silenciosamente.

**Verificar cuando Proxmox esté operativo:**

1. **Túnel WireGuard** — confirmar handshake activo:
   ```bash
   aws ssm start-session --target i-0bc21dfec3bfa79eb --region us-east-1
   sudo wg show
   # Debe mostrar: endpoint, latest handshake, transfer para el peer OPNsense
   # Si no hay handshake: actualizar Endpoint en OPNsense → 34.204.119.208:51820
   ```

2. **AllowedIPs en OPNsense (CRÍTICO)** — GLPI está ahora en `10.0.4.x` (subnet privada), antes estaba en `10.0.1.x`. El peer AWS en OPNsense debe tener `10.0.0.0/16` (o al menos `10.0.4.0/24`) en AllowedIPs. Sin esto, el DC recibe la petición LDAP pero no puede enrutar la respuesta a `10.0.4.131` por el túnel → falla silenciosamente.

3. **Verificar conectividad GLPI → DC desde la instancia:**
   ```bash
   aws ssm start-session --target i-08bc1c7d44b3319bc --region us-east-1
   nc -zv 192.168.10.10 389    # LDAP
   nc -zv 192.168.10.10 88     # Kerberos (si usa autenticación integrada)
   ```

4. **glpicrypt.key** — ya verificado, está en ambos sitios:
   - EFS: `/var/www/html/glpi/files/_meta/config/glpicrypt.key` ✓
   - Config activo: `/var/www/html/glpi/config/glpicrypt.key` ✓

5. **Config LDAP en BD** (ya verificado):
   - Servidor: `192.168.10.10:389` (DC en red `192.168.10.0/24`) ✓
   - Bind DN: `CN=Administrador,CN=Users,DC=dracs,DC=local`
   - TLS: desactivado

**Problema conocido en WireGuard EC2 — regla iptables huérfana:**
Hay una regla `MASQUERADE` en `eth0` que no debería existir (la interfaz es `ens5`). Es inofensiva pero se acumula con reinicios. Para limpiarla:
```bash
sudo iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE
sudo iptables-save > /etc/iptables/rules.v4
```

---

## Variables Terraform (referencias, no valores)

Fichero `terraform.tfvars` está gitignored. Variables necesarias:

| Variable | Descripción |
|---|---|
| `key_name` | `dracs2` |
| `wireguard_ami_id` | AMI migrada de cuenta vieja (o vacío para Ubuntu latest) |
| `nginx_ami_id` | AMI migrada de cuenta vieja (o vacío para Ubuntu latest) |
| `asg_desired` | 0 durante mantenimiento, 1 en producción |
| `glpi_db_password` | Contraseña RDS |
| `wg_aws_private_key` | Clave privada WireGuard AWS |
| `wg_opnsense_public_key` | Clave pública del peer OPNsense |
| `wg_preshared_key` | PSK del túnel |

---

## IDs de recursos clave (cuenta 123561366922)

| Recurso | ID |
|---|---|
| VPC | vpc-dracs |
| EFS | fs-0e3a12b50ac2f89b3 |
| RDS | rds-glpi-dracs |
| ASG | asg-glpi-dracs |
| ALB | alb-glpi-dracs |
| NLB | nlb-glpi-dracs |
| EC2 WireGuard | i-0bc21dfec3bfa79eb |
| EC2 Nginx | i-0826d318ae07dfe40 |
| EC2 GLPI (ASG, actual) | i-08bc1c7d44b3319bc |

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

# Shell en GLPI sin SSH ni VPN
aws ssm start-session --target i-08bc1c7d44b3319bc --region us-east-1

# Shell en WireGuard sin SSH ni VPN
aws ssm start-session --target i-0bc21dfec3bfa79eb --region us-east-1
```
