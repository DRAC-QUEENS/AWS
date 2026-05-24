# Evolución del certificado TLS: de HTTP-01 monolítico a DNS-01 + ACM

Este doc cuenta cómo ha cambiado el certificado TLS de DRACS a lo largo del proyecto, qué obligó a cada cambio y qué quedó como vestigio. Es el "porqué" detrás de la receta técnica que vive en `G2-A-67` / `AWS-BALANCEO.md` §4 y del bloque certbot del `user_data` del ASG.

## 0. Contexto

A inicios de Sprint 2 (Sprint 1 no tocó AWS) se desplegó una **única EC2** sirviendo GLPI + Apache + MariaDB local. El cert TLS se emitía y servía desde esa misma máquina con certbot HTTP-01, como en cualquier instalación clásica. Ya dentro del mismo Sprint 2 se refactorizó la arquitectura para introducir un ALB con terminación TLS multi-AZ + ASG, y el modelo de cert dejó de funcionar de un día para otro. Esto es lo que pasó y por qué la solución actual tiene la forma que tiene.

## 1. Fase 1 — HTTP-01 monolítico (Sprint 2, prototipo inicial)

**Lo que había:**

- Una EC2 t3.small con Apache + GLPI + MariaDB en local.
- El cert Let's Encrypt vivía en `/etc/letsencrypt/live/dracs-glpi.duckdns.org/` del disco local.
- Apache cargaba el cert directamente para servir HTTPS en :443.
- Renovación automática vía el cron de certbot que viene con el paquete (`/etc/cron.d/certbot`).
- El challenge era **HTTP-01**: certbot dejaba un fichero en `/.well-known/acme-challenge/<token>` y Let's Encrypt lo recuperaba por HTTP plano en el puerto 80.

Esta configuración inicial está documentada en `G2-A-45` ("9. GLPI y Nginx: Instalación y configuración"), sección "2. Certificado Gratuito en Nginx".

**Limitación inherente:** instancia ≡ cert. Si destruías la EC2 o se quedaba inservible, perdías el cert. No era un problema mientras la infra fuera monolítica con una única máquina pet.

## 2. Fase 2 — TLS termination en ALB → forzado a DNS-01 (Sprint 2, refactor)

**El cambio de infra:** el refactor de Sprint 2 (commit `4ac4b9f` — "add ALB+ASG+RDS+EFS for GLPI") introdujo:

- Un **ALB** que termina TLS en :443 y reenvía HTTP plano a los backends.
- Un **ASG** de instancias GLPI en subnets privadas que solo sirven HTTP en :80.
- Listener :80 del ALB con redirect 301 a :443 para no exponer texto plano.

**Por qué HTTP-01 dejó de ser viable:**

- HTTP-01 requiere que el endpoint público sirva `/.well-known/acme-challenge/<token>` en HTTP plano.
- Con el listener :80 del ALB haciendo `301 → :443`, el challenge muere de redirect antes de que Let's Encrypt pueda leerlo.
- Reconfigurar el listener cada 60-90 días para permitir el challenge (y deshacerlo después) era inviable operativamente.

**Pivote a DNS-01:**

- Plugin `certbot-dns-duckdns` (instalado en venv porque Ubuntu 24.04 bloquea pip system-wide).
- Token DuckDNS en `/etc/certbot/duckdns.ini` (chmod 600).project_dracs_overview
- Certbot crea un registro TXT `_acme-challenge.dracs-glpi.duckdns.org` con el token; Let's Encrypt lo lee por DNS.
- No expone nada en HTTP. No interfiere con el ALB.

**Comando de emisión** (resumido; detalle en `G2-A-67` / `AWS-BALANCEO.md` §4):

```bash
/opt/cb/bin/certbot certonly --non-interactive --agree-tos \
  --email joelsansi4@gmail.com \
  --authenticator dns-duckdns \
  --dns-duckdns-credentials /etc/certbot/duckdns.ini \
  --dns-duckdns-propagation-seconds 60 \
  -d dracs-glpi.duckdns.org \
  --cert-name dracs-glpi
```

**Import a ACM** — el cert ya no vive en la EC2 (no sirve TLS), tiene que vivir en **ACM** para que el ALB lo consuma:

```bash
aws acm import-certificate --region us-east-1 \
  --certificate     fileb:///etc/letsencrypt/live/dracs-glpi/cert.pem \
  --private-key     fileb:///etc/letsencrypt/live/dracs-glpi/privkey.pem \
  --certificate-chain fileb:///etc/letsencrypt/live/dracs-glpi/chain.pem
```

**Consumo desde Terraform:**

```hcl
data "aws_acm_certificate" "glpi" {
  domain      = "dracs-glpi.duckdns.org"
  most_recent = true
  statuses    = ["ISSUED"]
  key_types   = ["EC_prime256v1", "EC_secp384r1"]
}

resource "aws_lb_listener" "alb_https" {
  certificate_arn = data.aws_acm_certificate.glpi.arn
  # ...
}
```

> **Nota sobre `key_types`:** certbot emite cert ECDSA (`EC_prime256v1`) por defecto. El filtro por defecto del `data source` es RSA, así que sin este parámetro el data source no encuentra el cert y `terraform plan` falla.

## 3. Fase 3 — Persistencia del estado de certbot en EFS (Sprint 3)

**Problema nuevo:** con ASG, las instancias son ganado, no mascotas. Cada vez que el ASG reemplaza una instancia (por health check, scale-in, AMI nueva), arranca con disco vacío. El estado de certbot (`/etc/letsencrypt`, account key, contadores de renovación, los PEMs emitidos) se perdía.

**Solución** (commit `30ef220` — "restore certbot cert from EFS on startup"):

- Tras emitir o renovar el cert, copia manual del directorio a EFS:
  ```bash
  cp -a /etc/letsencrypt/. /mnt/efs/letsencrypt/
  ```
- El `user_data` del ASG instala certbot y restaura el directorio en cada arranque:
  ```bash
  apt-get install -y certbot python3-certbot-dns-duckdns 2>/dev/null || true
  if [ -d /mnt/efs/letsencrypt/live ]; then
    cp -a /mnt/efs/letsencrypt/. /etc/letsencrypt/
  fi
  ```

**Matiz no obvio (pero importante):** la instancia del ASG **NO sirve TLS**. El VirtualHost de Apache que escribe el `user_data` es solo `<VirtualHost *:80>` HTTP plano. La TLS termina en el ALB usando el cert de ACM. Entonces, ¿por qué persistir certbot en EFS?

Porque la **renovación** se hace SSM-eando dentro de una instancia GLPI. Para que `certbot renew` funcione necesita su estado anterior (account key registrada con Let's Encrypt, configuración del cert con `--cert-name dracs-glpi`, contadores de renovación). Sin la persistencia en EFS, cada renovación obligaría a registrar una cuenta nueva en Let's Encrypt, lo que cuenta contra los rate limits.

## 4. Procedimiento de renovación (manual, hoy)

```bash
# 1. SSM a una instancia del ASG
TARGET=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names asg-glpi-dracs \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
aws ssm start-session --target "$TARGET" --region us-east-1

# 2. Dentro de la instancia: restaurar estado certbot desde EFS (el user_data ya lo hizo)
ls /etc/letsencrypt/live/dracs-glpi/

# 3. Renovar
sudo /opt/cb/bin/certbot renew --cert-name dracs-glpi

# 4. Re-importar el cert renovado a ACM
sudo aws acm import-certificate --region us-east-1 \
  --certificate-arn arn:aws:acm:us-east-1:563771271989:certificate/<arn-existente> \
  --certificate     fileb:///etc/letsencrypt/live/dracs-glpi/cert.pem \
  --private-key     fileb:///etc/letsencrypt/live/dracs-glpi/privkey.pem \
  --certificate-chain fileb:///etc/letsencrypt/live/dracs-glpi/chain.pem

# 5. Persistir el nuevo estado en EFS para la próxima instancia
sudo cp -a /etc/letsencrypt/. /mnt/efs/letsencrypt/
```

El `data "aws_acm_certificate"` con `most_recent = true` recoge el cert renovado automáticamente en el siguiente `terraform apply`, sin tocar la configuración del listener.

## 5. Diagrama "antes vs después"

**Fase 1 (Sprint 2, prototipo monolítico):**

```
Internet ──HTTPS:443──▶ EC2 monolítica
                        ├─ Apache TLS desde /etc/letsencrypt/
                        ├─ GLPI + MariaDB local
                        └─ certbot HTTP-01 vía :80
                           (cron renueva, cert vive en disco)
```

**Fases 2 + 3 (refactor Sprint 2 + Sprint 3):**

```
Internet ──HTTPS:443──▶ NLB ──▶ ALB ──┐
                                      │ TLS termina aquí
                                      │ certificate_arn = data.aws_acm_certificate.glpi.arn
                                      ▼
                               ┌──────────────┐
                               │     ACM      │
                               └──────┬───────┘
                                      │ aws acm import-certificate
                                      ▼
              [renovación manual vía SSM]
              EC2 del ASG ──▶ certbot DNS-01 ──▶ DuckDNS TXT _acme-challenge
                  ▲             │
                  │             ▼
                  │       /etc/letsencrypt/
                  │             │
                  └──cp -a──── EFS /mnt/efs/letsencrypt/
                  ↑                       │
                  └─ user_data restaura ──┘ en cada arranque del ASG
```

## 6. Referencias

- `G2-A-45` ("9. GLPI y Nginx") — instalación monolítica de Fase 1.
- `G2-A-67` ("6.1 Balanceo") / `AWS-BALANCEO.md` §4 — procedimiento técnico DNS-01 + ACM.
- `G2-A-64` ("Runbook") / `AWS-RUNBOOK.md` — renovación operativa.
- Commit `4ac4b9f` — refactor que introduce ALB y rompe HTTP-01.
- Commit `30ef220` — fix que añade persistencia de certbot en EFS.
