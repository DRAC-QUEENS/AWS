# Infraestructura DRACS en AWS — Guía completa

Este documento explica la infraestructura AWS del proyecto DRACS desde lo más
básico hasta lo más complejo. Cada sección referencia el fichero `.tf` y las
líneas donde se define cada recurso. Está pensado para entender la arquitectura
de principio a fin, no como manual operativo (para eso está `docs/aws/AWS-RUNBOOK.md`).

---

# 1. Idea general

---

Se despliega **GLPI**, una aplicación web PHP de gestión de activos IT, sobre
AWS de modo que sea:

- Accesible desde internet con HTTPS y un dominio público (`dracs-glpi.duckdns.org`).
- Accesible desde la red on-prem a través de una VPN site-to-site con OPNsense.
- Tolerante a la caída de una zona de disponibilidad.
- Capaz de escalar el número de instancias según la carga.
- Operable sin abrir SSH (todo el acceso administrativo va por AWS SSM).

Toda la infraestructura está definida como código en Terraform y vive en este
repositorio. Las decisiones de diseño están condicionadas por el entorno de
**AWS Academy** (credenciales rotatorias, sin permisos para crear roles IAM
propios, presupuesto de 100 $ por laboratorio).

---

# 2. Visión general

---

```
                         INTERNET
                             │
                    ┌────────┴────────┐
                    │  NLB (EIP fija) │  ← DuckDNS apunta aquí
                    │  TCP:80, TCP:443│
                    └────────┬────────┘
                             │
                    ┌────────┴────────┐
                    │      ALB        │  HTTP:80 (redirect 301 a HTTPS)
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
```

A grandes rasgos: el tráfico de internet entra por un NLB con IP fija (a la que
apunta DuckDNS) que delega en un ALB. El ALB termina TLS y reparte entre las
instancias GLPI del Auto Scaling Group en dos AZs. Las instancias comparten
datos a través de RDS (BD) y EFS (ficheros). El tráfico desde on-prem entra por
el túnel WireGuard y atraviesa Nginx (redirector) antes de seguir el mismo
camino que el tráfico público.

---

# 3. Capa 1 — La VPC

---

Una VPC (*Virtual Private Cloud*) es una red privada aislada dentro de AWS. Se
ha creado una VPC propia (`vpc-dracs`) con CIDR `10.0.0.0/16` para tener espacio
amplio para crecer y no mezclar nada con la VPC default de la cuenta.

| Atributo | Valor |
| --- | --- |
| Name | `vpc-dracs` |
| CIDR | `10.0.0.0/16` (65 536 IPs) |
| `enable_dns_hostnames` | `true` (los recursos AWS resuelven DNS interno) |

### Dónde está definido

`network.tf` — `resource "aws_vpc" "main"` (líneas 16-20).

---

# 4. Capa 2 — Subnets

---

Una subnet es una subred dentro de la VPC, ligada a una AZ concreta. Se han
creado cuatro subnets, dos por AZ (`us-east-1a` y `us-east-1b`), divididas en
**públicas** y **privadas**.

| Subnet | CIDR | AZ | Tipo | Uso |
| --- | --- | --- | --- | --- |
| `subnet-publica-a-dracs` | `10.0.1.0/24` | us-east-1a | Pública | WireGuard, Nginx, NLB, ALB |
| `subnet-publica-b-dracs` | `10.0.3.0/24` | us-east-1b | Pública | ALB (segunda AZ) |
| `subnet-privada-a-dracs` | `10.0.2.0/24` | us-east-1a | Privada | ASG GLPI, mount EFS, RDS |
| `subnet-privada-b-dracs` | `10.0.4.0/24` | us-east-1b | Privada | ASG GLPI, mount EFS, RDS |

La diferencia técnica entre pública y privada está en la **route table** a la
que se asocian (ver siguiente sección), no en el tipo de subnet en sí. Las
públicas tienen ruta directa a internet via Internet Gateway; las privadas
salen por NAT Gateway.

Las subnets públicas tienen `map_public_ip_on_launch = true` para que cualquier
EC2 que se lance en ellas reciba IP pública automáticamente.

### Por qué dos AZs

Una AZ es un datacenter físicamente separado dentro de la región. Si `us-east-1a`
cae (corte eléctrico, problema de red), `us-east-1b` sigue operativa. Para que
esto sirva de algo, los recursos críticos (ALB, ASG, RDS, EFS) tienen que estar
registrados en ambas AZs.

### Dónde está definido

`network.tf` — `resource "aws_subnet" "public"`, `"public_b"`, `"private"`,
`"private_b"` (líneas 24-52).

---

# 5. Capa 3 — Internet Gateway, NAT Gateway y rutas

---

Las route tables definen cómo se enruta el tráfico desde cada subnet. Se han
creado dos: una para las públicas y otra para las privadas.

### Internet Gateway (IGW)

Es el componente que da salida y entrada de internet a la VPC. Sin IGW las
subnets públicas no podrían recibir ni enviar tráfico de internet.

| Atributo | Valor |
| --- | --- |
| Name | `igw-dracs` |
| Adjunto a | `vpc-dracs` |

### NAT Gateway

Las subnets privadas no tienen ruta directa a internet, pero las instancias del
ASG necesitan salir a internet para descargar paquetes apt y actualizaciones.
Para eso se ha desplegado un único **NAT Gateway** en `subnet-publica-a` con su
propia EIP. Las dos subnets privadas comparten el mismo NAT.

> **Nota:** poner un único NAT en una AZ es un compromiso intencional. Si cae
> `us-east-1a`, las instancias del ASG en `us-east-1b` pierden conectividad de
> salida. La alternativa (un NAT por AZ) duplicaría el coste mensual (~32 $/NAT).

### Route tables

| Route table | Asociadas | Rutas |
| --- | --- | --- |
| `rt-publica-dracs` | publica-a, publica-b | `10.0.0.0/16` → local; `0.0.0.0/0` → IGW; CIDRs on-prem → ENI WireGuard |
| `rt-privada-dracs` | privada-a, privada-b | `10.0.0.0/16` → local; `0.0.0.0/0` → NAT; CIDRs on-prem → ENI WireGuard |

### Rutas a on-prem

En **ambas** route tables se inyectan rutas estáticas a las redes on-prem
(`192.168.1.0/24`, `192.168.10.0/24`, `192.168.20.0/24`), todas apuntando a la
ENI del WireGuard EC2. Esto permite que cualquier recurso de la VPC pueda
hablar con on-prem como si fueran subnets locales.

```hcl
locals {
  onprem_cidrs = ["192.168.1.0/24", "192.168.10.0/24", "192.168.20.0/24"]
}
resource "aws_route" "onprem_private" {
  for_each               = toset(local.onprem_cidrs)
  route_table_id         = aws_route_table.privada.id
  destination_cidr_block = each.value
  network_interface_id   = aws_instance.wireguard.primary_network_interface_id
}
```

### Dónde está definido

`network.tf` — IGW (líneas 56-58), NAT (líneas 63-73), route tables (líneas 77-93),
asociaciones (líneas 97-115), rutas on-prem (líneas 121-137).

---

# 6. Capa 4 — Security Groups (firewall)

---

Cada recurso en AWS tiene un Security Group: una lista de qué tráfico puede
entrar y salir. Son **stateful** — si permites entrada, la respuesta sale
automáticamente. Se han definido seis SG aplicando el principio de mínimo
acceso: cada capa solo acepta tráfico de la capa inmediatamente anterior.

| Security Group | Ingress | Egress |
| --- | --- | --- |
| `sg-wireguard-dracs` | UDP:51820 desde internet; TCP:22 desde 10.8.0.0/24; todo desde 10.0.0.0/16 | Todo |
| `sg-nginx-dracs` | TCP:80 y TCP:22 desde 10.8.0.0/24 (VPN) y desde las redes on-prem (192.168.1/24, 192.168.10/24, 192.168.20/24) | Todo |
| `sg-alb-glpi-dracs` | TCP:80/443 desde 0.0.0.0/0; TCP:80 desde nginx SG | Todo |
| `sg-glpi-dracs` | TCP:80 desde ALB SG; todo desde redes VPN+on-prem; todo desde nginx SG | Todo |
| `sg-rds-glpi-dracs` | TCP:3306 sólo desde glpi SG | Todo |
| `sg-efs-glpi-dracs` | NFS:2049 sólo desde glpi SG | Todo |

La cadena se lee de fuera a dentro:

```
Internet → ALB (80/443)
              ↓
        GLPI ASG (80, sólo desde ALB)
              ↓
        RDS (3306, sólo desde GLPI)
        EFS (2049, sólo desde GLPI)
```

Nada de internet llega directamente a GLPI, RDS ni EFS. El único punto de
entrada público es el NLB (que no tiene SG propio porque los NLB classic no lo
soportan — el filtrado lo hace el SG del ALB).

### Dónde está definido

`security.tf` — los 6 Security Groups completos (168 líneas).

---

# 7. Capa 5 — Instancias estáticas (WireGuard y Nginx)

---

Hay dos EC2 que no escalan ni se reemplazan automáticamente. Viven en la subnet
pública-a con IP privada fija. Las dos se definen en `instances.tf`.

## 7.1 WireGuard — gateway VPN site-to-site

Es el extremo AWS del túnel WireGuard. Se conecta con el OPNsense on-prem y
permite que los recursos de la VPC y los de on-prem se vean como si estuvieran
en la misma red.

| Atributo | Valor |
| --- | --- |
| Name | `ec2-wireguard-dracs` |
| Tipo | `t3.micro` |
| AMI | Ubuntu 24.04 LTS latest (`data.aws_ami.ubuntu`) |
| IP privada | `10.0.1.10` |
| EIP | `34.204.119.208` (DuckDNS de OPNsense apunta aquí) |
| `source_dest_check` | `false` (imprescindible para que actúe como router) |
| `lifecycle` | `ignore_changes = [ami, user_data]` (instancia "pet", no se reemplaza por cambios de AMI) |

El `user_data` (`user_data/wireguard.sh.tpl`):

1. Instala el paquete `wireguard`.
2. Habilita IP forwarding en `/etc/sysctl.d/`.
3. Escribe `/etc/wireguard/wg0.conf` con las claves inyectadas vía `templatefile`.
4. Aplica reglas `iptables` para FORWARD y NAT (`MASQUERADE` con excepción para
   tráfico hacia `10.0.0.0/8`, para que las IPs origen no se NATeen entre VPC y on-prem).
5. Levanta el servicio con `systemctl enable --now wg-quick@wg0`.

Las claves son `sensitive` y vienen de `terraform.tfvars` (gitignored).

### Dónde está definido

`instances.tf` — `resource "aws_instance" "wireguard"` (líneas 3-31), EIP y
asociación (líneas 60-69). User_data en `user_data/wireguard.sh.tpl`.

## 7.2 Nginx — redirector HTTP

Una EC2 mínima que sólo hace una cosa: recibir peticiones HTTP de los usuarios
que entran por WireGuard y devolver un 301 al dominio público.

| Atributo | Valor |
| --- | --- |
| Name | `ec2-nginx-dracs` |
| Tipo | `t3.micro` |
| AMI | Ubuntu 24.04 LTS latest |
| IP privada | `10.0.1.20` |
| EIP | Ninguna (solo accesible desde la VPN) |

El `user_data` (`user_data/nginx.sh.tpl`) escribe una única `server` block:

```nginx
server {
    listen 80;
    server_name _;
    # $uri (normalizado, merge_slashes on) en vez de $request_uri para que
    # un cliente con "//" en el path no propague esos slashes al Location.
    return 301 ${glpi_url}$uri$is_args$args;
}
```

Donde `${glpi_url}` lo inyecta Terraform con el valor de `var.glpi_public_url`.

> **Nota:** anteriormente Nginx hacía `proxy_pass` con TLS autofirmado al ALB,
> lo que provocaba avisos de certificado en el navegador. Tras Sprint 4 se
> simplificó a un simple redirect 301. El TLS lo termina el ALB con el cert
> público de Let's Encrypt para todos los usuarios, incluso los que vienen de VPN.

### Dónde está definido

`instances.tf` — `resource "aws_instance" "nginx"` (líneas 33-56).
User_data en `user_data/nginx.sh.tpl`.

---

# 8. Capa 6 — Balanceadores (NLB + ALB)

---

Hay dos balanceadores en cascada. El motivo es técnico: el ALB termina TLS y
hace todo el trabajo de capa 7, pero su DNS público no tiene IP fija. DuckDNS
necesita una IP estática, así que delante se pone un NLB con una Elastic IP.

```
DuckDNS apunta a EIP fija (50.19.112.122)
                │
                ▼
           NLB (capa 4, TCP)
           listeners :80 y :443
                │  pasa el TCP tal cual
                ▼
           ALB (capa 7, HTTP/HTTPS)
           :80 → redirect 301 → :443
           :443 → cert ACM, forward a target group
                │  HTTP plano dentro de la VPC
                ▼
       Target Group `tg-glpi-dracs`
       (instancias del ASG, registradas dinámicamente)
```

## 8.1 NLB — IP fija para DuckDNS

| Atributo | Valor |
| --- | --- |
| Name | `nlb-glpi-dracs` |
| Tipo | Network Load Balancer (capa 4) |
| EIP | `50.19.112.122` (DuckDNS apunta aquí) |
| AZ | us-east-1a (single AZ; la EIP solo puede ir a una AZ) |
| Listeners | TCP:80, TCP:443 |

Los listeners forwardean a target groups de `target_type = "alb"`, una
integración nativa que permite usar el ALB como destino del NLB sin tener que
listar IPs manualmente (que cambiarían con el tiempo).

## 8.2 ALB — capa 7 y terminación TLS

| Atributo | Valor |
| --- | --- |
| Name | `alb-glpi-dracs` |
| Tipo | Application Load Balancer (capa 7) |
| Subnets | publica-a + publica-b (multi-AZ) |
| Security Group | `alb-glpi-dracs` |
| Listener HTTP:80 | Redirect 301 a HTTPS |
| Listener HTTPS:443 | Termina TLS con cert ACM, forward al target group de GLPI |
| SSL policy | `ELBSecurityPolicy-TLS13-1-2-2021-06` (solo TLS 1.2 y 1.3) |

El listener 80 no sirve nada, solo redirige:

```hcl
default_action {
  type = "redirect"
  redirect { port = "443" protocol = "HTTPS" status_code = "HTTP_301" }
}
```

## 8.3 Target Groups y health checks

| Target group | Protocolo:Puerto | Type | Health check |
| --- | --- | --- | --- |
| `tg-glpi-dracs` | HTTP:80 | instance | path `/`, matcher `200-302`, 30 s |
| `nlb-to-alb-dracs` | TCP:80 | alb | HTTP `/`, matcher `200-302` |
| `nlb-to-alb-443-dracs` | TCP:443 | alb | HTTPS `/`, matcher `200-302` |

> **Nota sobre el health check path:** se usa `/` porque GLPI se sirve desde la
> raíz de Apache (con `DocumentRoot /var/www/html/glpi`). Si se usase `/glpi/`,
> el target group siempre estaría unhealthy aunque GLPI estuviera funcionando.

El attachment del NLB al ALB declara explícitamente `depends_on` al listener
del ALB. Sin esto el primer `terraform apply` falla porque el ALB todavía no
tiene listener cuando se intenta registrar el attachment:

```hcl
resource "aws_lb_target_group_attachment" "nlb_to_alb_443" {
  target_group_arn = aws_lb_target_group.nlb_to_alb_443.arn
  target_id        = aws_lb.alb.arn
  port             = 443
  depends_on       = [aws_lb_listener.alb_https]
}
```

### Dónde está definido

`glpi_scaling.tf`:
- ALB (líneas 63-70), listeners (líneas 90-127), target group GLPI (líneas 72-88)
- NLB y EIP (líneas 131-150), target groups y attachments NLB→ALB (líneas 152-228)

---

# 9. Capa 7 — Almacenamiento compartido (EFS + RDS)

---

Las instancias del ASG son **efímeras**: pueden aparecer y desaparecer en
cualquier momento. Por eso ni los ficheros ni la BD pueden vivir en el disco
local de cada instancia. Se sacan a dos servicios separados.

## 9.1 EFS — ficheros compartidos

EFS (*Elastic File System*) es un sistema de ficheros NFS gestionado por AWS.
Se monta como un volumen normal en `/mnt/efs` en cada instancia.

| Atributo | Valor |
| --- | --- |
| Encryption | At rest activada |
| DNS endpoint | `<fs-id>.efs.us-east-1.amazonaws.com` |
| Mount targets | privada-a y privada-b (uno por AZ) |
| Security Group | `efs-glpi-dracs` (puerto 2049 sólo desde GLPI SG) |
| Punto de montaje | `/mnt/efs` (raíz del filesystem) |

**Estructura del filesystem:**

```
/mnt/efs/
├── files/                    ← uploads, logs, caché de GLPI
│   └── _meta/config/
│       └── glpicrypt.key     ← clave de cifrado de GLPI (necesaria tras migración)
├── plugins/                  ← plugins instalados de GLPI
└── letsencrypt/              ← persistencia del cert TLS (opcional)
    └── live/dracs-glpi/
```

El `user_data` de cada instancia hace symlinks para que GLPI no note la diferencia:

```bash
ln -s /mnt/efs/files   /var/www/html/glpi/files
ln -s /mnt/efs/plugins /var/www/html/glpi/plugins
```

## 9.2 RDS — base de datos MariaDB

RDS (*Relational Database Service*) es la BD gestionada por AWS. Vive en las
subnets privadas y no es accesible desde internet.

| Atributo | Valor |
| --- | --- |
| Engine | MariaDB 10.11 |
| Clase | `db.t3.micro` |
| Almacenamiento | 20 GB gp3 cifrado |
| BD inicial | `glpi`, usuario `glpi`, password en `var.glpi_db_password` |
| Subnet group | privada-a + privada-b |
| Backup retention | 7 días automáticos |
| Security Group | `rds-glpi-dracs` (solo TCP:3306 desde GLPI SG) |

### Dónde está definido

`glpi_scaling.tf`:
- EFS y mount targets (líneas 12-27)
- RDS y subnet group (líneas 31-59)

---

# 10. Capa 8 — ASG y Launch Template

---

El Auto Scaling Group es el corazón de la arquitectura. Lanza, mantiene y
reemplaza instancias GLPI siguiendo una receta definida en el Launch Template.

## 10.1 Launch Template

Define cómo se fabrica cada instancia GLPI:

| Atributo | Valor |
| --- | --- |
| AMI | `var.glpi_ami_id` (Packer) o `data.aws_ami.ubuntu` si está vacío |
| Tipo | `t3.small` |
| Key pair | `var.key_name` (`dracs2`) |
| Security Group | `glpi-dracs` |
| IAM profile | `LabInstanceProfile` (habilita SSM y permisos ACM) |
| Block device | 20 GB gp3 cifrado |
| User data | `user_data/glpi_asg.sh.tpl` con `rds_endpoint`, `db_password`, `efs_dns` y `glpi_public_url` |

### AMI Packer vs Ubuntu vanilla

La variable `var.glpi_ami_id` apunta a una AMI custom construida con Packer que
tiene Apache, PHP 8.3 y GLPI 10.0.18 pre-instalados. Esto reduce el tiempo de
arranque de una instancia nueva de ~10 minutos (descarga e instalación en
caliente) a ~2 minutos (sólo `apt-get` lo crítico).

Si `glpi_ami_id` está vacío, se usa Ubuntu 24.04 LTS vanilla y el `user_data`
instala todo desde cero. Es el modo "fallback" si la AMI Packer no está
disponible (por ejemplo, al cambiar de cuenta).

La AMI Packer se construye con la plantilla `packer/glpi.pkr.hcl`.

## 10.2 user_data — el bootstrap de cada instancia

El `user_data/glpi_asg.sh.tpl` es idempotente y se ejecuta en cada arranque.
Pasos:

1. **Paso 1: Monta EFS** en `/mnt/efs`, crea subdirectorios (`_cache`, `_cron`,
   `_dumps`, `_log`, `_lock`, etc.) y hace symlinks `glpi/files → /mnt/efs/files`
   y `glpi/plugins → /mnt/efs/plugins`.
2. **Certbot + restore del cert desde EFS** — instala `certbot` y el plugin
   `python3-certbot-dns-duckdns`. Si `/mnt/efs/letsencrypt/live/` existe (porque
   se persistió previamente), copia los ficheros a `/etc/letsencrypt`.
3. **Paso 2: Instala paquetes** (sólo si no son los de la AMI Packer): Apache,
   PHP y extensiones.
4. **Paso 3: Descarga GLPI** (sólo si no está): GLPI 10.0.18 desde GitHub.
5. **Paso 4: `config_db.php`** apuntando al endpoint RDS.
6. **Paso 5: Restaura `glpicrypt.key`** desde EFS si existe (necesaria para que
   GLPI descifre contraseñas guardadas, p. ej. la del bind LDAP).
7. **Paso 6: Inicializa la BD** con un `flock` sobre un fichero de EFS para
   evitar que dos instancias arrancando a la vez ejecuten `db:install` en paralelo.
8. **Paso 7: Escribe el VirtualHost de Apache** con `DocumentRoot /var/www/html/glpi`
   y una `RewriteRule` que redirige `/glpi` → `/` (evita 404 cuando navegadores
   con caché vieja entran por la URL antigua). Este paso siempre se ejecuta para
   que tanto instalaciones frescas como instancias basadas en AMI Packer queden
   con la misma configuración.
9. **Paso 8: Arranca Apache.**

> **Nota crítica sobre DocumentRoot:** la doc oficial moderna recomienda
> `/var/www/html/glpi/public`, pero GLPI 10.0.x hardcodea en su código PHP
> rutas tipo `public/lib/base.min.css`. Con `DocumentRoot=/public` esas URLs
> dan 404 (CSS roto). Por eso se usa el modo legacy `/var/www/html/glpi`.

## 10.3 ASG

| Atributo | Valor |
| --- | --- |
| Name | `asg-glpi-dracs` |
| min / max / desired | `0 / 3 / var.asg_desired` (default `2`) |
| Subnets | privada-a + privada-b |
| Target group | `tg-glpi-dracs` (registro automático) |
| Health check type | `ELB` (usa el resultado del health check del ALB) |
| Grace period | 300 s |

`min=2` garantiza que siempre haya dos instancias activas (una por AZ) para
mantener HA real, incluso cuando la alarma de scale-in de Target Tracking
intenta reducir el ASG por CPU baja en reposo. Para bajar el ASG durante
mantenimiento hay que reducir temporalmente `min_size` (no basta con bajar
`desired_capacity`, ya que se cap-ea al `min_size`). `max=4` permite escalar
hasta el doble del par HA cuando la política de CPU dispara.

> **Nota sobre `health_check_type = ELB`:** con esta configuración el ASG
> sustituye una instancia si **el ALB** la marca unhealthy, no solo si la EC2
> deja de responder a nivel de hardware. Si GLPI deja de servir por bug
> software, queremos que se reemplace.

### Dónde está definido

`glpi_scaling.tf`:
- Launch Template (líneas 232-260)
- ASG (líneas 262-288)

Variables relacionadas en `variables.tf`: `glpi_ami_id`, `asg_desired`,
`key_name`, `glpi_public_url`, `glpi_db_password`.

---

# 11. Capa 9 — Autoescalado

---

La política configurada es **Target Tracking sobre la CPU media del ASG al 60 %**.

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

Funcionamiento:

- AWS monitoriza automáticamente la métrica `ASGAverageCPUUtilization` (no hace
  falta CloudWatch Agent ni configuración extra).
- Si la CPU media supera el 60 % de forma sostenida, el ASG lanza una instancia
  adicional (hasta `max_size = 4`).
- Si la CPU lleva tiempo por debajo, la alarma `AlarmLow` dispara pero el ASG
  no puede bajar de `min_size = 2`, por lo que la alarma queda permanentemente
  en estado `ALARM` en reposo (comportamiento esperado, no es un fallo).
- AWS crea y gestiona las alarmas CloudWatch internas asociadas
  automáticamente — no hace falta declararlas.

> **Nota sobre el target del 60 %:** GLPI (PHP + Apache) empieza a degradarse
> por encima del 65-70 % de CPU. Un target del 60 % deja margen para absorber
> el pico mientras arranca la nueva instancia (que tarda ~2 min con la AMI Packer).

### Dónde está definido

`glpi_scaling.tf` — `resource "aws_autoscaling_policy" "glpi_cpu"` (líneas 292-305).

---

# 12. Capa 10 — TLS y certificados

---

El flujo completo del certificado público de GLPI:

1. **Emisión con certbot.** Se usa `certbot` con el plugin `dns-duckdns` y el
   challenge **DNS-01**: certbot crea un registro TXT temporal en DuckDNS para
   demostrar que controlamos el dominio. Esto evita tener que abrir puerto 80
   público (que está ocupado por el redirect 301 del ALB). El cert que emite
   Let's Encrypt es ECDSA por defecto.

2. **Import a ACM.** Tras emitirlo se importa con `aws acm import-certificate`.
   Como las instancias del ASG tienen `LabInstanceProfile` con permiso
   `acm:ImportCertificate`, el procedimiento se ejecuta desde una instancia
   GLPI vía SSM.

3. **Consumo desde Terraform.** Un `data source` recoge automáticamente la
   versión más reciente del cert:

   ```hcl
   data "aws_acm_certificate" "glpi" {
     domain      = "dracs-glpi.duckdns.org"
     most_recent = true
     statuses    = ["ISSUED"]
     key_types   = ["EC_prime256v1", "EC_secp384r1"]
   }
   ```

   Sin el filtro `key_types` el data source no encuentra el cert (por defecto
   busca RSA, y certbot emite ECDSA).

4. **Uso en el ALB.** El listener HTTPS:443 referencia el ARN del data source.
   Cualquier cert nuevo importado se aplica al hacer `terraform apply` sin
   tocar código.

### Persistencia entre arranques del ASG

Los ficheros del cert viven en `/etc/letsencrypt` que es efímero — si el ASG
reemplaza una instancia, los ficheros se pierden. Para resolverlo, el
`user_data` restaura desde EFS si encuentra `/mnt/efs/letsencrypt/live/`. La
operación inversa (guardar en EFS tras emitir/renovar) es manual de momento.

### Renovación

Let's Encrypt caduca cada 90 días. La renovación es manual:

1. Conectar por SSM a una instancia del ASG.
2. `certbot ... --force-renewal`.
3. `aws acm import-certificate`.
4. `terraform apply` (el data source recoge la versión nueva).
5. Opcionalmente, `cp -a /etc/letsencrypt/. /mnt/efs/letsencrypt/` para que
   las próximas instancias la encuentren.

### Dónde está definido

`glpi_scaling.tf` — `data "aws_acm_certificate" "glpi"` (líneas 108-114),
`aws_lb_listener.alb_https` (líneas 116-127). Procedimiento de renovación en
`docs/aws/AWS-RUNBOOK.md` sección 5.

---

# 13. Capa 11 — DNS (DuckDNS)

---

No hay dominio propio registrado. Se usa **DuckDNS**, un servicio de DNS dinámico
gratuito que da el subdominio `dracs-glpi.duckdns.org`. Su registro A apunta a
la EIP del NLB (`50.19.112.122`).

Como la EIP del NLB es fija, el registro es estático — no hace falta cliente
DDNS actualizándolo.

DuckDNS también proporciona un **token** que certbot usa para crear los
registros TXT del challenge DNS-01. Ese token vive en
`/etc/certbot/duckdns.ini` con permisos `0600` en cada instancia donde se
renueve el cert (no está en Terraform).

### Dónde está definido

EIP del NLB en `glpi_scaling.tf` — `resource "aws_eip" "nlb"` (líneas 131-135).

---

# 14. Capa 12 — Acceso operacional (SSM)

---

Las instancias del ASG **no tienen SSH expuesto**: el SG de GLPI no abre puerto
22 desde fuera de la VPN/on-prem. El acceso administrativo es por **AWS Systems
Manager Session Manager**.

Esto requiere que la instancia tenga `LabInstanceProfile` adjunto (el Launch
Template lo declara). Con eso:

```bash
# Shell directo en una instancia GLPI
GLPI=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names asg-glpi-dracs \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
aws ssm start-session --target $GLPI

# Comando remoto (sin sesión interactiva)
aws ssm send-command --instance-ids $GLPI \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["systemctl status apache2"]'
```

Ventajas respecto a SSH:

- No hay claves SSH que gestionar.
- No hay puertos abiertos.
- Cada sesión queda registrada en CloudWatch Logs.
- Funciona aunque la instancia esté en subnet privada sin IP pública (el
  agente SSM se conecta de salida al endpoint regional).

### Dónde está definido

IAM profile en `glpi_scaling.tf` — `iam_instance_profile { name = "LabInstanceProfile" }`
dentro del Launch Template (líneas 242-244).

---

# 15. Estado y backend de Terraform

---

El state de Terraform vive en S3 con lock en DynamoDB. Esto permite trabajo en
equipo (los locks evitan apply simultáneos) y supervivencia a la pérdida del
disco local.

| Recurso | Nombre |
| --- | --- |
| Bucket S3 (state) | `dracs-tfstate-<account_id>` (versioned + AES256 + public-block) |
| Bucket S3 (backups app) | `dracs-backups-<account_id>` |
| Tabla DynamoDB (lock) | `dracs-tfstate-lock` |

El bootstrap es chicken-and-egg: el bucket y la tabla se crean con un primer
`terraform apply` en state local; luego se descomenta el bloque `backend "s3"`
en `provider.tf` y se hace `terraform init -migrate-state`.

### Dónde está definido

- `backend.tf` — bucket y tabla DynamoDB (63 líneas).
- `backups.tf` — bucket S3 de backups de aplicación con lifecycle a Glacier (56 líneas).
- `provider.tf` — provider AWS + bloque `backend "s3"` comentado.

---

# 16. Flujo completo de una petición

---

```
Usuario en internet
        │  HTTPS → dracs-glpi.duckdns.org
        ▼
DuckDNS → EIP del NLB (50.19.112.122)
        │
        ▼
NLB :443 (TCP, pasa el TLS sin tocarlo)
        │
        ▼
ALB :443 (termina TLS con cert ACM)
        │  HTTP plano internamente
        ▼
Target Group → instancia GLPI (privada, AZ a o b)
        │
        ├─→ Lee/escribe ficheros en EFS (/mnt/efs)
        └─→ Lee/escribe datos en RDS MariaDB

Usuario en VPN (on-prem)
        │  WireGuard tunnel
        ▼
EC2 WireGuard (10.0.1.10) — actúa de router
        │
        ▼
EC2 Nginx (10.0.1.20) — devuelve 301 a https://dracs-glpi.duckdns.org
        │  (desde aquí mismo camino que el usuario de internet)
        ▼
NLB → ALB → GLPI
```

---

# 17. Resumen — por qué cada pieza existe

---

| Componente | Por qué |
| --- | --- |
| Dos AZs | Alta disponibilidad: si una cae, la otra sigue |
| Subnets privadas | GLPI, RDS y EFS no son accesibles desde internet |
| NAT Gateway | Las privadas pueden salir a internet para apt/SSM/ACM |
| Único NAT en una AZ | Compromiso coste/resiliencia (32 $/mes por NAT) |
| NLB + EIP fija | IP estática para DuckDNS (el ALB no la tiene) |
| ALB | Termina TLS, balancea entre AZs, hace health checks |
| ASG | Instancias efímeras, reemplazo automático y escalado |
| Launch Template + AMI Packer | Tiempo de arranque <2 min |
| EFS | Ficheros compartidos entre instancias del ASG |
| RDS | BD fuera del compute — sobrevive a reemplazos |
| Política CPU 60 % | Escalado automático sin tener que tocar nada |
| SSM | Acceso administrativo sin SSH |
| WireGuard | Túnel site-to-site con on-prem |
| Nginx | Redirector HTTP para usuarios de VPN |
| DuckDNS | DNS dinámico gratuito sin registrar dominio |
| ACM + certbot | HTTPS con cert válido de Let's Encrypt |
| Backend S3 + DynamoDB | State remoto con locks |

---

# 18. Glosario de archivos del proyecto

---

```
.
├── provider.tf          → Provider AWS (~> 6.0) + backend S3 (comentado hasta bootstrap)
├── backend.tf           → Bucket S3 (tfstate) + tabla DynamoDB (lock)
├── variables.tf         → Variables (región, key pair, AMIs, asg_desired, secretos)
├── network.tf           → VPC, 4 subnets, IGW, NAT, route tables, rutas on-prem
├── security.tf          → 6 Security Groups
├── instances.tf         → EC2 WireGuard + EC2 Nginx (con su EIP)
├── glpi_scaling.tf      → EFS, RDS, ALB, NLB, Launch Template, ASG, política CPU
├── backups.tf           → Bucket S3 de backups de aplicación
├── outputs.tf           → Outputs (IPs, DNS, endpoints, IDs)
├── packer/
│   └── glpi.pkr.hcl     → Plantilla Packer para AMI de GLPI pre-instalado
└── user_data/
    ├── wireguard.sh.tpl → Instala WireGuard + IP forwarding + iptables
    ├── nginx.sh.tpl     → Nginx con un único 301 al dominio público
    └── glpi_asg.sh.tpl  → Bootstrap idempotente de instancias GLPI (EFS, BD, Apache)
```

---

# 19. Documentación relacionada

---

- `README.md` — visión general del repo y guía de despliegue
- `CONTEXTO.md` — estado actual de IPs, IDs y sprints
- `docs/aws/AWS.md` — visión general AWS y decisiones de diseño
- `docs/aws/AWS-RED.md` — VPC, subnets y rutas en profundidad
- `docs/aws/AWS-VPN.md` — gateway WireGuard y proxy Nginx
- `docs/aws/AWS-BALANCEO.md` — NLB, ALB, target groups y cert TLS
- `docs/aws/AWS-GLPI.md` — ASG, Launch Template, RDS y EFS en detalle
- `docs/aws/AWS-SEGURIDAD.md` — Security Groups, IAM, KMS y secretos
- `docs/aws/AWS-TERRAFORM.md` — estructura IaC, variables y state remoto
- `docs/aws/AWS-RUNBOOK.md` — procedimientos operativos y troubleshooting
- `docs/aws/AWS-COSTES.md` — estimación de coste mensual
- `docs/aws/AWS-SIMPLE.md` — arquitectura previa monolítica (Sprint 2)
