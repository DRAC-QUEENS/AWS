# Cómo funciona la infraestructura DRACS

> Prerequisitos asumidos: sabes qué es una VPC, subnets, IGW y NAT Gateway.

---

## El mapa completo

Antes de entrar en detalle, el flujo de tráfico de principio a fin:

```
INTERNET
  └─ NLB  (IP fija 50.19.112.122 ← DuckDNS: dracs-glpi.duckdns.org)
       └─ ALB  (distribuye, termina TLS)
            └─ ASG: instancias GLPI  (subnet privada, sin IP pública)
                 ├─ RDS MariaDB      (base de datos compartida)
                 └─ EFS              (ficheros compartidos)

ON-PREM (Proxmox / OPNsense)
  └─ WireGuard VPN ──→ EC2 WireGuard (10.0.1.10)
                            └─ Nginx (10.0.1.20) ──301──→ https://dracs-glpi.duckdns.org
```

Dos caminos hacia GLPI: **internet** y **on-prem**. Los dos acaban llegando al ALB (el de on-prem via redirección a la URL pública).

---

## Bloque 1 — NLB: el portero de la IP fija

### El problema que resuelve

El ALB (que verás en el siguiente bloque) tiene un nombre DNS que AWS gestiona, algo como:
```
alb-glpi-dracs-949041849.us-east-1.elb.amazonaws.com
```
Ese DNS puede cambiar de IPs cuando AWS lo decida. Si pones ese nombre en DuckDNS y las IPs cambian, el dominio deja de funcionar.

DuckDNS necesita una **IP fija**. El NLB sí permite asociarle una Elastic IP (EIP), que nunca cambia. Así que DuckDNS apunta a la EIP del NLB, y el NLB reenvía el tráfico al ALB.

### Qué hace exactamente

El NLB opera en **capa 4 (TCP/UDP)**. Eso significa que no entiende de HTTP, URLs, cabeceras ni cookies. Solo ve paquetes TCP y los reenvía al destino configurado.

En esta infraestructura tiene dos listeners:
- **Puerto 80 TCP** → reenvía al ALB en puerto 80
- **Puerto 443 TCP** → reenvía al ALB en puerto 443

No abre el TLS, no modifica nada. Pasa los paquetes tal cual al ALB.

```
Usuario                NLB               ALB
  │                     │                 │
  │──── TCP:443 ────────►│                 │
  │                     │──── TCP:443 ────►│
  │                     │                 │  (aquí termina el TLS)
```

**Analogía:** el NLB es el portero del edificio. No lee lo que llevas, solo dice "pasa al mostrador del fondo".

---

## Bloque 2 — ALB: el que de verdad distribuye

### Qué lo diferencia del NLB

El ALB opera en **capa 7 (HTTP/HTTPS)**. Entiende el protocolo HTTP: ve las URLs, las cabeceras, las cookies. Eso le permite tomar decisiones inteligentes sobre a dónde enviar cada petición.

### Qué hace en esta infraestructura

**Termina el TLS.** El certificado de `dracs-glpi.duckdns.org` vive aquí, en el ALB. Cuando el usuario se conecta por HTTPS, el ALB descifra el tráfico, lo procesa, y habla con las instancias GLPI en HTTP plano (puerto 80). El usuario ve HTTPS, el backend trabaja en HTTP.

```
Usuario ──HTTPS──► ALB ──HTTP──► instancia GLPI
         (cifrado)      (dentro de la VPC, ya descifrado)
```

**Tiene dos listeners (puntos de escucha):**
- Puerto 80 → redirige automáticamente a HTTPS (301)
- Puerto 443 → descifra TLS y reenvía al target group

**Target group:** es la lista de instancias GLPI que el ALB conoce. El ALB les hace health checks periódicos (GET / → espera respuesta 200 o 302). Si una instancia no responde bien, el ALB la saca de la rotación y deja de mandarle tráfico hasta que se recupere.

**Analogía:** el ALB es el recepcionista que lee lo que traes, decide qué ventanilla te atiende, y si una ventanilla está cerrada, te manda a otra.

---

## Bloque 3 — ASG + Launch Template: las instancias GLPI que escalan

### Launch Template: la receta

El Launch Template es el molde con el que se fabrica cada instancia GLPI. Define:
- Qué imagen usar (AMI Packer `ami-0f69b2f6a15d477e3`, o Ubuntu 24.04 LTS si no hay AMI configurada)
- Qué tipo de instancia (`t3.small`)
- Qué key pair para SSH (`dracs2`)
- Qué Security Group aplicar
- Qué IAM profile (da acceso a SSM Session Manager)
- El `user_data`: el script que se ejecuta al arrancar la instancia

**La AMI Packer** contiene Apache, PHP 8.3 y GLPI 10.0.18 ya instalados y el VirtualHost de Apache configurado. El tiempo de arranque baja de ~8-10 minutos (descarga + instalación en caliente) a ~2 minutos (solo configuración runtime).

El `user_data` se ejecuta en cada arranque y hace únicamente lo que requiere el entorno de runtime:
1. Monta el EFS en `/mnt/efs` y crea los subdirectorios que GLPI necesita (`_sessions`, `_plugins`, etc.)
2. Crea symlinks: `glpi/files → /mnt/efs/files` y `glpi/plugins → /mnt/efs/plugins`
3. Si Apache o GLPI no están (AMI sin Packer), los instala y descarga
4. Escribe `config_db.php` apuntando al endpoint RDS
5. Restaura la `glpicrypt.key` desde EFS (si existe)
6. Inicializa la BD con `db:install` si está vacía (con flock en EFS para evitar race condition entre instancias)
7. Arranca Apache

El resultado: una instancia GLPI completamente funcional, conectada a la BD y al almacenamiento compartido, sin intervención manual.

### ASG: el mecanismo de escala

El Auto Scaling Group usa el Launch Template para crear y destruir instancias automáticamente. Está configurado con:
- `min = 0` — se puede apagar del todo (útil durante mantenimiento)
- `max = 3` — nunca más de 3 instancias
- `desired = 2` — en producción se mantiene 1 instancia por AZ (alta disponibilidad real)

Las instancias viven en las **subnets privadas** (`10.0.2.x` y `10.0.4.x`). Sin IP pública, sin acceso directo desde internet. El único que puede hablarles es el ALB (y la VPN).

Cuando el ASG lanza una instancia nueva, **la registra automáticamente en el target group del ALB**. El ALB empieza a mandarle tráfico en cuanto supera el health check.

Si una instancia muere o falla el health check, el ASG la termina y lanza una nueva con la misma receta.

```
ASG detecta que hay 0 instancias (o una muerta)
  └─ Lanza nueva instancia desde Launch Template
       └─ user_data se ejecuta → instancia configurada
            └─ Se registra en target group del ALB
                 └─ ALB empieza a mandarle tráfico
```

---

## Bloque 4 — RDS: la base de datos fuera de las instancias

### Por qué no está dentro de la instancia GLPI

En la arquitectura antigua (la de `simple/`), MariaDB corría dentro de la misma EC2 que GLPI. Funcionaba, pero tenía un problema: si la instancia muere y el ASG lanza otra, **los datos de la BD se pierden** (el disco de la EC2 es efímero con ASG).

RDS es una base de datos MariaDB gestionada por AWS, separada de las instancias GLPI. Sus ventajas:
- **Persistente:** los datos sobreviven aunque mueran todas las instancias del ASG
- **Backups automáticos:** retención de 7 días configurada
- **Gestionada:** AWS parchea el motor, gestiona el almacenamiento

Las 3 instancias del ASG (si escala a 3) apuntan todas al mismo endpoint RDS:
```
rds-glpi-dracs.capsrvyl1db1.us-east-1.rds.amazonaws.com:3306
```

El SG de RDS solo permite conexiones en puerto 3306 **desde el SG de GLPI**. Ni tú desde internet, ni Nginx, ni WireGuard pueden conectarse directamente a la BD.

---

## Bloque 5 — EFS: los ficheros compartidos entre instancias

### El problema que resuelve

GLPI guarda cosas en disco: ficheros adjuntos que suben los usuarios, logs, datos de sesión, cachés. Con una sola instancia no hay problema. Con ASG y varias instancias, sí:

```
Usuario sube un adjunto → instancia A lo guarda en su disco local
Usuario descarga el adjunto → petición va a instancia B → B no tiene el fichero → error
```

**EFS** (Elastic File System) es un sistema de ficheros NFS compartido. Todas las instancias lo montan en el mismo directorio y ven los mismos ficheros en tiempo real.

```
Instancia A ─┐
Instancia B ─┼──► EFS (nfs compartido) ── /var/www/html/glpi/files
Instancia C ─┘
```

### Cómo está desplegado

El EFS tiene **mount targets** (puntos de montaje) en dos AZs:
- `10.0.2.189` → subnet privada-a (us-east-1a)
- `10.0.4.123` → subnet privada-b (us-east-1b)

Cada instancia monta el mount target de su misma AZ (más eficiente y más barato). Si falla una AZ completa, las instancias de la otra AZ siguen teniendo acceso a sus ficheros.

### También guarda la clave de cifrado

GLPI cifra la configuración sensible (contraseñas LDAP, de correo, etc.) con una clave llamada `glpicrypt.key`. Esa clave vive en EFS (`files/_meta/config/glpicrypt.key`). Cada vez que el ASG lanza una instancia nueva, el `user_data` la copia al directorio de configuración de GLPI. Sin ella, GLPI no puede descifrar la contraseña del DC y la autenticación LDAP falla.

---

## Bloque 6 — Nginx: el camino on-prem

### Por qué existe Nginx si ya hay ALB

El personal de on-prem (detrás de OPNsense/Proxmox) accede a GLPI por la VPN interna, no por internet. Nginx es el punto de entrada para ese tráfico.

El flujo on-prem es:
```
PC de on-prem (192.168.x.x)
  └─ OPNsense → túnel WireGuard → EC2 WireGuard (10.0.1.10)
                                        └─ Nginx (10.0.1.20)
                                              └─ redirige a https://dracs-glpi.duckdns.org
```

Nginx escucha en `10.0.1.20:80` (IP privada, solo accesible por VPN) y **redirige con un 301** a la URL pública:

```nginx
server {
    listen 80;
    server_name _;
    return 301 https://dracs-glpi.duckdns.org$request_uri;
}
```

El usuario de on-prem entra a `http://10.0.1.20` y el navegador le lleva automáticamente a `https://dracs-glpi.duckdns.org`, que tiene el cert ACM válido. Sin avisos del navegador, sin cert autofirmado.

### Por qué se simplificó (antes era un reverse proxy)

La versión anterior de Nginx hacía `proxy_pass` al ALB con un cert autofirmado en el lado HTTPS. Esto causaba que el navegador normal mostrara aviso de seguridad la primera vez, mientras que en el modo incógnito (caché limpia) funcionaba bien. La raíz era que el navegador cacheaba la decisión de confiar o no confiar en el cert autofirmado.

La solución más limpia: eliminar el cert autofirmado y redirigir al dominio público que ya tiene cert ACM válido. Nginx pasa de proxy a redirector de una sola línea.

---

## Bloque 7 — Los Security Groups: las fronteras entre componentes

Los SGs son cortafuegos que se aplican a nivel de interfaz de red. Cada recurso tiene el suyo, y las reglas controlan exactamente quién puede hablar con quién.

El esquema de permisos sigue el principio de mínimo acceso — cada capa solo acepta tráfico de la capa inmediatamente anterior:

```
Internet
  │
  ▼
NLB ──────────────────────────────── (sin SG, es un recurso de red)
  │
  ▼
ALB  [sg-alb]
  └─ Acepta: 80/443 desde 0.0.0.0/0 (internet)
  │
  ▼
GLPI ASG  [sg-glpi]
  ├─ Acepta: 80 desde sg-alb (solo el ALB puede mandarle HTTP)
  ├─ Acepta: todo desde 10.8.0.0/24 (VPN WireGuard, para admin)
  ├─ Acepta: todo desde 192.168.x.x (on-prem, para admin)
  └─ Acepta: todo desde sg-nginx (proxy-jump SSH)
  │
  ├──────────────────────────────────┐
  ▼                                  ▼
RDS  [sg-rds]                      EFS  [sg-efs]
  └─ Acepta: 3306 desde sg-glpi      └─ Acepta: 2049 desde sg-glpi

Nginx  [sg-nginx]
  └─ Acepta: 80 desde 10.8.0.0/24 (solo desde el túnel WireGuard)
```

**Lo que esto garantiza:**
- Nadie desde internet puede conectarse directamente a GLPI, RDS o EFS
- Solo el ALB puede mandar tráfico HTTP a GLPI
- Solo GLPI puede conectarse a la BD y al almacenamiento
- Nginx solo es accesible desde la VPN (ya no tiene EIP ni tráfico de internet)
- El acceso de administración (SSH, debug) solo es posible desde la VPN o desde on-prem

---

## Resumen: cómo se relaciona todo

Una petición de un usuario de internet al GLPI sigue este camino:

```
1. Usuario escribe https://dracs-glpi.duckdns.org
2. DuckDNS resuelve → 50.19.112.122 (EIP del NLB)
3. NLB recibe TCP:443 → lo pasa al ALB en TCP:443
4. ALB descifra TLS con el cert de ACM
5. ALB elige una instancia GLPI (health check OK)
6. ALB envía HTTP:80 a la instancia GLPI (10.0.4.131)
7. GLPI procesa la petición:
   - Lee/escribe en RDS si necesita datos de BD
   - Lee/escribe en EFS si hay ficheros adjuntos
8. GLPI responde al ALB → ALB responde al NLB → NLB responde al usuario
```

Y una petición desde on-prem:

```
1. Usuario de on-prem abre http://10.0.1.20
2. La petición va por la red on-prem → OPNsense → túnel WireGuard → AWS
3. Llega a Nginx (10.0.1.20)
4. Nginx responde 301 → https://dracs-glpi.duckdns.org
5. El navegador sigue la redirección: va a DuckDNS → NLB → ALB → GLPI
6. A partir de aquí, igual que el camino de internet (pasos 3-8)
```
