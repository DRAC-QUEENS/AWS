# Infraestructura previa "simple"

Antes de llegar a la arquitectura actual (ALB, ASG, RDS, EFS, multi-AZ) se desplegó una versión mucho más sencilla que vivía toda en una sola AZ y una sola subnet. El código está en el folder `simple/` del repo y se mantiene operativo como entorno de validación rápida. Este documento recoge cómo era esa versión, por qué se empezó así y qué motivó la evolución hacia la versión profesional.

# 1. Por qué empezamos aquí

---

La premisa del Sprint 2 era tener GLPI accesible desde la red on-prem y desde internet **lo antes posible** para poder validar los flujos importantes: que la VPN funcionase, que la autenticación contra el AD pasase por el túnel, y que el sistema de ticketing fuese usable desde un cliente Windows del dominio. Una arquitectura cloud-native completa (ASG, RDS, EFS) habría retrasado esa validación.

Por eso se optó por una versión monolítica:

* Una sola AZ — menos coste, menos partes móviles, suficiente para una demo.
* Tres EC2 colocadas en la misma subnet pública — sin balanceadores, sin NAT Gateway, sin subnets privadas.
* GLPI **todo-en-uno** dentro de una sola instancia (Apache + PHP + MariaDB local + ficheros locales).
* TLS sólo autofirmado en el Nginx (suficiente para usuarios internos y para pruebas).

Al ir bien de tiempo en el Sprint 3, se decidió subir el listón y rehacer la parte de GLPI con un stack más profesional (alta disponibilidad, datos persistentes fuera del compute, TLS público). El código `simple/` se conservó tal cual como referencia y entorno de pruebas alternativo.

# 2. Visión general

---

```
                          INTERNET
                              │
                    ┌─────────┴──────────┐
                    │ EIP Nginx (DuckDNS)│
                    └─────────┬──────────┘
                              │ HTTPS:443
  PUBLIC 10.0.1.0/24          │
  ┌──────────────────────────────────────┐
  │  WireGuard EC2  │  Nginx (proxy)    │
  │  10.0.1.10 EIP  │  10.0.1.20 EIP   │
  │                 │                   │
  │   NAT Gateway ──┘                   │
  └──────────┬──────────────────────────┘
             │ HTTP:80 (privado)
  PRIVATE 10.0.2.0/24
  ┌──────────┴──────────┐
  │  GLPI todo-en-uno   │  10.0.2.30
  │   Apache + PHP      │
  │   MariaDB local     │
  │   ficheros locales  │
  └─────────────────────┘

      ↕ Túnel WireGuard (EIP WG EC2)
      OPNsense on-prem
```

WireGuard y Nginx viven en `subnet-publica-dracs` (10.0.1.0/24) con EIP propia. El GLPI está en `subnet-privada-dracs` (10.0.2.0/24), sin acceso directo desde internet — solo accesible desde el Nginx (proxy) y desde la VPN. El NAT Gateway permite que la instancia privada salga a internet para descargar paquetes en el arranque.

![](aws-simple-arquitectura.png){width=900px}
<!-- captura del diagrama o de Resource Map de la VPC vpc-simple-dracs -->

# 3. Componentes

---

## 3.1 Red

| Recurso | Valor |
| --- | --- |
| VPC | `vpc-simple-dracs` (10.0.0.0/16) |
| Subnet pública | `subnet-publica-dracs` (10.0.1.0/24, us-east-1a) |
| Subnet privada | `subnet-privada-dracs` (10.0.2.0/24, us-east-1a) |
| Internet Gateway | `igw-simple-dracs` |
| NAT Gateway | `nat-simple-dracs` en subnet pública, EIP propia |
| Route table pública | `rt-publica-simple-dracs` → `0.0.0.0/0` vía IGW |
| Route table privada | `rt-privada-simple-dracs` → `0.0.0.0/0` vía NAT |
| Rutas on-prem | `192.168.1.0/24`, `192.168.10.0/24`, `192.168.20.0/24` → ENI del WG EC2 (via `for_each`) |

El GLPI está en la subnet privada para que no sea accesible directamente desde internet. El NAT Gateway le permite salir a internet en el arranque (descarga de paquetes APT y el tarball de GLPI) sin exponerlo con una IP pública.

## 3.2 Instancias EC2

| Instancia | IP privada | Tipo | EIP | Función |
| --- | --- | --- | --- | --- |
| `ec2-wireguard-simple-dracs` | 10.0.1.10 | t3.micro | Sí | Gateway VPN site-to-site con OPNsense |
| `ec2-nginx-simple-dracs` | 10.0.1.20 | t3.micro | Sí (DuckDNS apunta aquí) | Reverse proxy HTTPS hacia el GLPI |
| `ec2-glpi-simple-dracs` | 10.0.2.30 (privada) | t3.small | No | Apache + PHP + MariaDB + GLPI 10.0.18, todo local |

El `user_data` del Nginx recibe la IP privada del GLPI directamente desde Terraform:

```hcl
user_data = templatefile("user_data/nginx.sh.tpl", {
  glpi_ip = aws_instance.glpi.private_ip
})
```

Y hace `proxy_pass http://10.0.1.30` — sin DNS dinámicos, sin balanceador.

## 3.3 Security Groups

| SG | Ingress | Egress |
| --- | --- | --- |
| `wireguard-simple-dracs` | UDP:51820 desde 0.0.0.0/0; TCP:22 desde 10.8.0.0/24; todo desde 10.0.0.0/16 | Todo |
| `nginx-simple-dracs` | TCP:80/443 desde 0.0.0.0/0; TCP:22 desde 10.8.0.0/24 | Todo |
| `glpi-simple-dracs` | TCP:80 desde `nginx-simple-dracs` SG; todo desde 10.8.0.0/24 + 192.168.x.x | Todo |

Sólo tres SGs frente a los seis de la versión nueva: no hay `alb`, `rds`, ni `efs` porque esos recursos no existen aquí.

## 3.4 user_data del GLPI

Lo significativo de la versión simple es que el `user_data` instala **todo en la misma máquina**:

```bash
apt-get install -y apache2 mariadb-server \
  php php-mysql php-curl php-gd php-intl php-ldap \
  php-mbstring php-xml php-xmlrpc php-zip ...
systemctl enable mariadb
mysql -u root << SQL
  CREATE DATABASE IF NOT EXISTS glpi ...;
  CREATE USER IF NOT EXISTS 'glpi'@'localhost' ...;
SQL
wget https://.../glpi-10.0.18.tgz
tar -xzf ... -C /var/www/html/
php /var/www/html/glpi/bin/console db:install ...
```

El resultado es una EC2 que arranca y deja GLPI accesible en `http://10.0.1.30/` sin depender de ningún otro recurso AWS.

# 4. State remoto

---

Igual que la versión actual, el state se guarda en S3 con SSE + versionado:

| Recurso | Nombre |
| --- | --- |
| Bucket | `dracs-tfstate-<account_id>` (con `prevent_destroy = true`) |

A diferencia del stack actual, **no hay DynamoDB lock** (se asumió que el deploy lo hacía una sola persona durante el sprint y se priorizó simplicidad).

# 5. Limitaciones que motivaron evolucionar

---

* **Datos en disco efímero** — la BD y los uploads viven en el EBS de la EC2 GLPI. Si la instancia muere o se sustituye, se pierden. Hay que hacer snapshot manual antes de cualquier `terraform destroy`.
* **Sin alta disponibilidad** — todo en `us-east-1a`. Una caída de AZ tumba todo el GLPI.
* **Cambios en la EC2 GLPI implican downtime** — actualizar PHP, reinstalar GLPI o moverla obliga a reinicios.
* **TLS sólo autofirmado** — los navegadores externos muestran el warning de "sitio no seguro". Aceptable para uso interno, no para producción.
* **No hay backups gestionados** — sólo snapshots EBS bajo demanda; no hay retención automática.
* **Escalado manual** — un único `t3.small` para todos los usuarios; si crece la carga hay que cambiar el tipo a mano (y reinicio).

# 6. Qué se aprendió y se trasladó a la versión nueva

---

No todo se descartó. Varios patrones de la versión simple se reutilizaron tal cual en la arquitectura actual:

* **Rutas on-prem via ENI del WG** — el `for_each` sobre `local.onprem_cidrs` apuntando a `aws_instance.wireguard.primary_network_interface_id` es idéntico. Sólo cambia que ahora se aplica a dos route tables (publica y privada) en vez de una.
* **EC2 WireGuard tal cual** — mismo tipo, mismo IP, mismas reglas iptables, mismo `source_dest_check=false`. La VPN se replicó sin tocar.
* **EC2 Nginx como proxy** — el rol es el mismo (proxy hacia GLPI). En la versión nueva el `proxy_pass` apunta al ALB en vez de a una IP directa.
* **Estructura de tfvars** — las cuatro variables sensibles (`glpi_db_password`, `wg_aws_private_key`, `wg_opnsense_public_key`, `wg_preshared_key`) se mantienen iguales.
* **Backend S3 con `prevent_destroy`** — mismo patrón, ampliado con DynamoDB para el lock.

> **Nota:** las claves WireGuard se reutilizaron también entre versiones, así que OPNsense no tuvo que regenerar nada — sólo cambiar el Endpoint del peer al EIP de la EC2 WireGuard de la versión nueva.

# 7. Cómo se despliega hoy

---

El código sigue siendo válido y se puede levantar en cualquier momento como entorno de pruebas independiente:

```bash
cd simple/
$EDITOR terraform.tfvars   # rellenar las 4 variables sensibles
terraform init
terraform apply
terraform output           # EIPs y nombre del bucket de tfstate
```

Mantiene su propio `terraform.tfstate` (sufijo `simple-dracs` en los nombres de recursos para no chocar con la versión nueva si se desplegaran ambas en la misma cuenta).

> **Nota:** las dos versiones comparten patrón de naming pero **no comparten state**. No se puede aplicar la versión simple sobre la nueva (ni viceversa) sin destruir antes la otra. En la práctica solo hay una desplegada a la vez.

# 8. Documentación relacionada

---

* **G2-A-59 — AWS.md** — visión general y decisiones de diseño (incluye el porqué de la evolución hacia la versión actual)
* **G2-A-66 — AWS-GLPI.md** — la versión nueva de GLPI (ASG + RDS + EFS) sobre la que se mejoró respecto a esta arquitectura
* **G2-A-60 — AWS-VPN.md** — la parte de WireGuard y Nginx que se mantiene casi igual entre ambas versiones
* **G2-A-63 — AWS-TERRAFORM.md** — estructura del IaC y procedimiento general de despliegue
