# Problemas encontrados en la infraestructura

Este documento recoge todos los problemas que se han observado y
resuelto en la infraestructura del proyecto a lo largo de su vida. Para
cada uno se describe el síntoma, la causa raíz, el fix aplicado y los
ficheros afectados. Sirve como referencia rápida para futuras
auditorías, como apoyo para la presentación, y como recordatorio de
decisiones que pueden parecer arbitrarias cuando se lee el código sin
contexto.

El criterio de ordenación es por capa (de abajo arriba), no
cronológico.

## Resumen rápido

| ID    | Título                                                     | Capa             | Estado            |
|-------|------------------------------------------------------------|------------------|-------------------|
| P-01  | Rutas on-prem desaparecían tras cada `terraform apply`     | Terraform / red  | Resuelto definitivo |
| P-02  | SG `nginx-dracs` no admitía tráfico desde redes on-prem    | Security Group   | Resuelto          |
| P-03  | LDAP no conectaba con el Domain Controller                  | Firewall on-prem | Resuelto          |
| P-04  | `chown -R` sobre EFS colgaba el arranque del ASG            | user_data + EFS  | Resuelto          |
| P-05  | Apache devolvía 404 si el navegador iba a `/glpi`           | Apache rewrite   | Resuelto          |
| P-06  | CSS de GLPI roto (assets en `/public/...` 404)              | Apache vhost     | Resuelto          |
| P-07  | Nginx propagaba dobles barras (`//`) al `Location`         | Nginx config     | Resuelto          |
| P-08  | `AlarmLow` de Target Tracking siempre en `ALARM`            | ASG / CloudWatch | Esperado (no es un bug) |

---

## P-01 — Rutas on-prem desaparecían tras cada `terraform apply`

**Síntoma.** Después de cualquier `terraform apply` (incluso applies con
`-target` que tocaban recursos no relacionados), las rutas
`192.168.1.0/24`, `192.168.10.0/24`, `192.168.20.0/24 → ENI del WG` se
borraban de las dos route tables (`rt-publica-dracs` y `rt-privada-dracs`).
Como consecuencia, la conectividad entre on-prem y la VPC se perdía:
el WG seguía recibiendo paquetes pero las respuestas se enrutaban al
NAT Gateway y se perdían.

**Causa raíz.** Anti-patrón documentado del provider AWS de Terraform.
En `network.tf` los recursos `aws_route_table.publica` y
`aws_route_table.privada` declaraban una ruta `0.0.0.0/0` inline en un
bloque `route { ... }`, y al mismo tiempo existían recursos separados
`aws_route.onprem_public` y `aws_route.onprem_private` que añadían las
rutas hacia las CIDRs on-prem. Cuando se mezclan bloques `route` inline
con recursos `aws_route` separados sobre la misma route table,
Terraform considera todo lo que no esté declarado inline como drift y
lo elimina en cada apply. Las rutas on-prem se borraban una y otra vez,
y `aws_route` las volvía a crear sólo si formaban parte del plan
explícito de ese apply.

**Fix.** Añadir `lifecycle { ignore_changes = [route] }` a los dos
recursos `aws_route_table`. Con eso, Terraform sólo crea las rutas
inline en el momento de crear la route table y nunca más las
reconcilia; los recursos `aws_route` separados pueden añadir o
modificar rutas sin que el route table las trate como drift. Cero
churn en la migración: existing routes y new routes coexisten.

**Verificación.** Tras el fix, `terraform plan` devuelve
`No changes. Your infrastructure matches the configuration.`,
algo que no se daba en ninguna de las sesiones anteriores. Las rutas
on-prem ya no se pierden en applies sucesivos.

**Ficheros afectados:** `network.tf` líneas 77-104.

---

## P-02 — SG `nginx-dracs` no admitía tráfico desde redes on-prem

**Síntoma.** Tras restaurar las rutas on-prem (P-01), un SSH directo
desde la red de oficina (192.168.10.50) hacia Nginx (10.0.1.20) seguía
sin funcionar. El WG (10.0.1.10) sí respondía. Ping/TCP timeout.

**Causa raíz.** `sg-nginx-dracs` sólo permitía SSH (22) y HTTP (80)
desde `10.8.0.0/24` (la subnet del túnel WireGuard, donde viven las
interfaces `wg0`). Cuando una petición sale desde 192.168.10.50,
atraviesa el túnel, llega al WG y se reenvía por `eth0`. La regla
`MASQUERADE ! -d 10.0.0.0/8` del WG no aplica a destinos dentro de la
VPC, por lo que el paquete llega a Nginx con `src=192.168.10.50`.
Nginx lo descarta porque su SG no incluye `192.168.0.0/16` ni ninguno
de los CIDRs on-prem. Bug latente desde que se introdujo el WG en
Sprint 2: el SG del ALB sí tenía los CIDRs on-prem, pero el de Nginx
se quedó con sólo el del túnel. Pasó desapercibido porque el flujo
habitual era HTTP iniciado por el ALB (no por un cliente on-prem
directamente).

**Fix.** Ampliar `cidr_blocks` del ingress de `sg-nginx-dracs` para
incluir los tres CIDRs on-prem: `10.8.0.0/24`, `192.168.1.0/24`,
`192.168.10.0/24`, `192.168.20.0/24`. Aplicado a los dos ingress
(80 y 22).

**Ficheros afectados:** `security.tf` líneas 42-55.

---

## P-03 — LDAP no conectaba con el Domain Controller

**Síntoma.** Desde GLPI en AWS, el test de conexión LDAP al DC on-prem
(`192.168.10.5:389`) devolvía "Connection refused" o timeout. Desde la
EC2, un `telnet 192.168.10.5 389` sí conectaba — situación
contradictoria.

**Causa raíz.** El Windows Firewall del DC tenía la regla
"Active Directory Domain Services (LDAP-In)" limitada en Scope a la
red on-prem local (192.168.x.x). El tráfico que llegaba desde la
subnet AWS (`10.0.3.0/24`) caía fuera del scope y se descartaba. El
`telnet` engañaba porque pasaba por otra regla con scope más amplio
("File and Printer Sharing", que también tenía 389 habilitado).

**Fix.** En el DC, añadir `10.0.0.0/16` (o las subnets privadas
concretas) al Scope → Remote IP de la regla LDAP-In. Sin reiniciar
nada.

**Lección.** `telnet` no garantiza la conectividad por puerto a un
servicio concreto: un firewall puede aceptar el puerto bajo un servicio
y rechazarlo bajo otro. Verificar con el protocolo real.

**Ficheros afectados:** ninguno en este repo. Configuración en el DC.

---

## P-04 — `chown -R` sobre EFS colgaba el arranque del ASG

**Síntoma.** El endpoint público devolvía `502 Bad Gateway` sostenido.
Las instancias del ASG arrancaban, no pasaban el health check del ALB,
se marcaban `Unhealthy` y el ASG las terminaba. Las nuevas caían en el
mismo problema. Bucle infinito de reemplazos, cero targets healthy.

**Causa raíz.** El `user_data` ejecutaba
`chown -R www-data:www-data /mnt/efs/files /mnt/efs/plugins` después
de montar EFS. El directorio `/mnt/efs/files/_sessions/` había
acumulado **85 424 ficheros** de sesión PHP (335 MB sólo en entradas
de directorio). El `chown -R` recursivo sobre NFS hace miles de RPCs
`SETATTR` secuenciales y se bloqueaba en estado `D` (uninterruptible
RPC) durante horas. Con `set -e` activo, el script nunca alcanzaba el
paso de `systemctl restart apache2`. Apache no arrancaba, el ALB lo
marcaba unhealthy y el ASG lo terminaba.

**Fix permanente** (en `user_data/glpi_asg.sh.tpl`):

```bash
# 1. chown no-recursivo sobre los tops (idempotente, instantáneo)
chown www-data:www-data /mnt/efs/files /mnt/efs/plugins

# 2. chown recursivo SÓLO sobre lo que no esté ya en www-data,
#    excluyendo los directorios ephemeral que pueden tener decenas
#    de miles de ficheros (no necesitan recorrido recursivo)
find /mnt/efs/files /mnt/efs/plugins \
  -type d \( -name "_sessions" -o -name "_cache" -o -name "_tmp" \
             -o -name "_log" -o -name "_dumps" -o -name "_cron" \) -prune \
  -o -not -user www-data -exec chown www-data:www-data {} +

# 3. Limpieza preventiva de sesiones PHP viejas (>1 día)
timeout 60 find /mnt/efs/files/_sessions -maxdepth 1 -type f -mtime +1 -delete \
  2>/dev/null || true
```

**Limpieza única para desatascar el ASG.** Suspender procesos del ASG
(`ReplaceUnhealthy`, `HealthCheck`, `Terminate`) para evitar que mate
la instancia mid-cleanup, luego borrar los 85 k ficheros con
`xargs -P 8` paralelizado por SSM. Finalmente, `terraform apply` para
que el LT recoja el `user_data` nuevo y `start-instance-refresh` con
`MinHealthyPercentage=0`.

**Lección.** Nunca hacer `chown -R` sobre directorios NFS sin saber el
orden de magnitud de su contenido. Operaciones recursivas sobre
`_sessions`/`_cache` de GLPI son bombas latentes. `set -e` no protege
contra procesos atascados en estado `D`.

**Ficheros afectados:** `user_data/glpi_asg.sh.tpl`.

---

## P-05 — Apache devolvía 404 si el navegador iba a `/glpi`

**Síntoma.** Algunos navegadores con caché del path antiguo
(`https://dracs-glpi.duckdns.org/glpi`) recibían un 404 con `Apache/2.4.58
(Ubuntu) Server at dracs-glpi.duckdns.org Port 80`. El path raíz `/`
funcionaba bien.

**Causa raíz.** Dos componentes combinados:

1. `glpi_configs.url_base` apuntaba a `.../glpi` desde el Sprint 2,
   cuando GLPI se instaló dentro de la subcarpeta `/glpi`. GLPI añade
   esa ruta a sus redirecciones internas.
2. `DocumentRoot` ahora es `/var/www/html/glpi`. Si una petición trae
   `/glpi/index.php`, Apache busca `/var/www/html/glpi/glpi/index.php`
   → no existe → 404.

**Fix en Apache** (en el VirtualHost del `user_data`):

```apache
RewriteEngine On
RewriteRule ^/glpi/?(.*)$ /$1 [R=301,L]
```

La regex captura `/glpi`, `/glpi/`, `/glpi/index.php`, etc., y los
reescribe sin el prefijo. La barra opcional (`/?`) y la sustitución
`/$1` evitan el bug de doble barra que tenía una versión anterior con
`^/glpi(/.*)?$`.

**Fix en BD:**

```sql
UPDATE glpi_configs SET value = 'https://dracs-glpi.duckdns.org'
WHERE name = 'url_base';
```

**Lección.** Probar la RewriteRule con `/`, `/glpi`, `/glpi/` y
`/glpi/index.php`. El trailing slash es el caso favorito de los bugs
de regex de Apache.

**Ficheros afectados:** `user_data/glpi_asg.sh.tpl` (Paso 7).

---

## P-06 — CSS de GLPI roto (assets en `/public/...` 404)

**Síntoma.** GLPI se cargaba sin estilos: texto plano, sin layout, sin
iconos. En DevTools → Network los recursos `.css` y `.js` devolvían
404, con URLs del tipo `https://.../public/css/glpi.css`.

**Causa raíz.** GLPI 10.x soporta dos modos de despliegue: legacy
(`DocumentRoot /var/www/html/glpi`) y public (`DocumentRoot
/var/www/html/glpi/public`). El proyecto está en modo legacy, así que
los assets viven en `/var/www/html/glpi/css/`, no en
`/var/www/html/glpi/public/css/`. Cuando alguna ruta interna intentaba
cargar `/public/css/...`, Apache devolvía 404.

**Fix.** Forzar `glpi_configs.url_base` sin sufijo `/public` (mismo
update que P-05) y mantener `DocumentRoot /var/www/html/glpi` en el
VirtualHost. La `RewriteRule` de P-05 también ayuda a redirigir
peticiones legacy a `/glpi/...`.

**Lección.** Decidir modo legacy o public **antes** de configurar el
VirtualHost. Mezclar los dos rompe los assets sin tocar ningún fichero
.css físico.

**Ficheros afectados:** `user_data/glpi_asg.sh.tpl` (Paso 7); BD
(`glpi_configs.url_base`).

---

## P-07 — Nginx propagaba dobles barras (`//`) al `Location`

**Síntoma.** Las redirecciones del Nginx interno acababan con `//`
justo después del FQDN: `https://dracs-glpi.duckdns.org//`,
`.../glpi//foo`. El navegador seguía el redirect y caía en URLs
malformadas.

**Causa raíz.** El redirect usaba
`return 301 ${glpi_url}$request_uri;`. La variable `$request_uri` es
el URI **original** que recibió Nginx, sin normalizar. Si un cliente
mandaba `GET //` (porque tenía un bookmark con `//`, porque el navegador
concatenó mal, etc.), Nginx propagaba ese `//` literal al `Location`.

**Fix.** Sustituir `$request_uri` por `$uri$is_args$args`:

```nginx
return 301 ${glpi_url}$uri$is_args$args;
```

`$uri` es el path **normalizado**: con `merge_slashes on` (el default
de Nginx), las barras consecutivas se colapsan a una sola.
`$is_args$args` preserva la query string que `$uri` no incluye.

**Verificación**, vía `curl -sI` desde dentro de la VPC:

| Request           | `Location` devuelto                              |
|-------------------|---------------------------------------------------|
| `/`               | `https://dracs-glpi.duckdns.org/`                |
| `//`              | `https://dracs-glpi.duckdns.org/`                |
| `///`             | `https://dracs-glpi.duckdns.org/`                |
| `/glpi//foo`      | `https://dracs-glpi.duckdns.org/glpi/foo`        |
| `/a/b/?q=1`       | `https://dracs-glpi.duckdns.org/a/b/?q=1`        |

**Lección operativa.** Cambios sólo en `user_data` de un
`aws_instance` no fuerzan recreación por defecto. Para que el Nginx
recogiera el fix hubo que pedirlo: `terraform apply
-replace=aws_instance.nginx -auto-approve`.

**Ficheros afectados:** `user_data/nginx.sh.tpl`.

---

## P-08 — `AlarmLow` de Target Tracking siempre en `ALARM`

**Síntoma.** Tras configurar la política de autoescalado por CPU,
la alarma `TargetTracking-asg-glpi-dracs-AlarmLow` aparecía
permanentemente en estado `ALARM` en la consola de CloudWatch, incluso
sin carga.

**Causa raíz no es un bug, es comportamiento esperado.** Target
Tracking crea automáticamente dos alarmas:
`AlarmHigh` (dispara con CPU > ~66 %, scale-out) y `AlarmLow` (CPU
< ~30 %, scale-in). En reposo, la CPU media del ASG está cerca del
0 %, así que `AlarmLow` cumple su condición y queda en `ALARM`. Como
`min_size = 2`, el ASG no puede reducir más, pero la alarma sigue
disparada — sólo no consigue su objetivo.

Antes del fix `min_size = 1` (estado original), la alarma sí cumplía
su efecto y bajaba el ASG a 1 instancia, rompiendo el par HA por AZ.
Subir `min_size` a 2 fue el fix correcto.

**Fix.** Subir `min_size` de 1 a 2 en `glpi_scaling.tf`. Mantener
`AlarmLow` en `ALARM` es esperado y seguro; ignorar visualmente en la
consola.

**Ficheros afectados:** `glpi_scaling.tf` línea 264.

---

## Documentación relacionada

- `INFRAESTRUCTURA.md` (raíz del repo) — descripción global de la
  infraestructura con referencias a cada fichero `.tf`.
- `G2-A-64` / `docs/aws/AWS-RUNBOOK.md` — procedimientos operativos recurrentes
  (reemplazo de instancia, renovación de cert, etc.).
- ⚠️ pendiente crear issue YouTrack / `docs/aws/AWS-STRESS-TEST.md` — procedimiento
  manual para validar la política de autoescalado por CPU.
- `terraform output` y `aws … describe-…` — fuente actual de IDs/IPs reales (no hay doc centralizado).
