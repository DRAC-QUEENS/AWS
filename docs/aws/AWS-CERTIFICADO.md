# Certificado TLS — DRACS

Documento único sobre el certificado TLS de DRACS: arquitectura, emisión inicial, renovación cada 90 días, persistencia en EFS, y la historia de cómo se llegó aquí.

---

## 1. Resumen rápido

| Atributo | Valor |
|----------|-------|
| **Dominio** | `dracs-glpi.duckdns.org` |
| **Emisor** | Let's Encrypt (gratuito) |
| **Tipo de clave** | ECDSA (`EC_prime256v1` por defecto de certbot) |
| **Challenge** | DNS-01 vía plugin `certbot-dns-duckdns` |
| **Almacenamiento** | AWS Certificate Manager (ACM), región `us-east-1` |
| **Consumidor** | Listener HTTPS:443 del ALB |
| **Duración** | 90 días (Let's Encrypt) |
| **Renovación** | Manual, vía SSM a una instancia del ASG |
| **Persistencia** | EFS `/mnt/efs/letsencrypt/` (sobrevive a reemplazos del ASG) |

---

## 2. Arquitectura actual

```
Internet ──HTTPS:443──▶ NLB ──▶ ALB ──┐
                                      │ TLS termina aquí
                                      │ certificate_arn = data.aws_acm_certificate.glpi.arn
                                      ▼
                               ┌──────────────┐
                               │     ACM      │
                               └──────┬───────┘
                                      │ aws acm import-certificate (al renovar)
                                      ▼
              [emisión / renovación manual vía SSM]
              EC2 del ASG ──▶ certbot DNS-01 ──▶ DuckDNS TXT _acme-challenge
                  ▲             │
                  │             ▼
                  │       /etc/letsencrypt/
                  │             │
                  └──cp -a──── EFS /mnt/efs/letsencrypt/
                  ↑                       │
                  └─ user_data restaura ──┘ en cada arranque del ASG
```

**Quién hace qué:**
- **ALB**: termina TLS en `:443`. Lee el cert de ACM vía data source.
- **ACM**: almacena el cert. Es el único consumidor del PEM por parte de AWS.
- **Instancias del ASG**: NO sirven TLS. Apache escucha solo `:80` HTTP plano. Las instancias son donde corre certbot durante emisión/renovación (vía SSM), pero el TLS real lo hace el ALB.
- **EFS**: persiste `/etc/letsencrypt/` entre reemplazos del ASG (account key de Let's Encrypt, contadores de renovación, PEMs).
- **DuckDNS**: provee el registro DNS y permite que certbot escriba TXT records vía API token.

**Consumo desde Terraform** (`glpi_scaling.tf`):

```hcl
data "aws_acm_certificate" "glpi" {
  domain      = "dracs-glpi.duckdns.org"
  most_recent = true
  statuses    = ["ISSUED"]
  # certbot emite ECDSA por defecto; el filtro por defecto del data source es RSA
  key_types = ["EC_prime256v1", "EC_secp384r1"]
}

resource "aws_lb_listener" "alb_https" {
  ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn = data.aws_acm_certificate.glpi.arn
  # ...
}
```

> **Por qué `key_types`:** sin este parámetro el data source filtra por RSA por defecto y no encuentra el cert ECDSA, así que `terraform plan` falla con "no matching certificates found". Si en algún momento se cambiase a RSA habría que añadir `RSA_2048`.

> **Por qué `most_recent = true`:** así, tras una renovación que reimporta a ACM, el siguiente `terraform apply` recoge automáticamente la nueva versión sin tocar la configuración del listener.

---

## 3. Emisión inicial

**Se hace una sola vez**, durante el bootstrap del proyecto. Para renovaciones periódicas ver §4.

Por qué DNS-01 y no HTTP-01:
- HTTP-01 requeriría servir `/.well-known/acme-challenge/<token>` por HTTP plano. El ALB hace 301 → HTTPS en `:80`, lo que rompería el challenge sin reconfigurar el listener cada vez.
- DNS-01 solo necesita un token de DuckDNS para crear el TXT `_acme-challenge.dracs-glpi.duckdns.org`. No expone nada en HTTP, no interfiere con el ALB.

```bash
# 1. SSM a una instancia del ASG
GLPI=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names asg-glpi-dracs \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
aws ssm start-session --target "$GLPI" --region us-east-1

# 2. Plugin certbot-dns-duckdns en un venv (Ubuntu 24.04 bloquea pip system-wide)
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-venv
sudo python3 -m venv /opt/cb
sudo /opt/cb/bin/pip install certbot certbot-dns-duckdns

# 3. Credenciales DuckDNS
echo "dns_duckdns_token = <TOKEN>" | sudo tee /etc/certbot/duckdns.ini
sudo chmod 600 /etc/certbot/duckdns.ini

# 4. Emitir el cert (ECDSA por defecto)
sudo /opt/cb/bin/certbot certonly --non-interactive --agree-tos \
  --email joelsansi4@gmail.com \
  --authenticator dns-duckdns \
  --dns-duckdns-credentials /etc/certbot/duckdns.ini \
  --dns-duckdns-propagation-seconds 60 \
  -d dracs-glpi.duckdns.org \
  --cert-name dracs-glpi

# 5. Importar a ACM (primera vez, sin --certificate-arn, crea un cert nuevo)
sudo aws acm import-certificate --region us-east-1 \
  --certificate     fileb:///etc/letsencrypt/live/dracs-glpi/cert.pem \
  --private-key     fileb:///etc/letsencrypt/live/dracs-glpi/privkey.pem \
  --certificate-chain fileb:///etc/letsencrypt/live/dracs-glpi/chain.pem \
  --tags Key=Name,Value=dracs-glpi-cert

# 6. Persistir el estado de certbot en EFS para que sobreviva al ASG
sudo cp -a /etc/letsencrypt/. /mnt/efs/letsencrypt/

# 7. terraform apply para que el listener HTTPS pille el cert recién importado
exit  # sale de la sesión SSM
terraform apply
```

Apunta el ARN devuelto por `aws acm import-certificate` — lo necesitarás en §4 para reimportar sobre él en las renovaciones.

---

## 4. Renovación cada 90 días

**Procedimiento manual.** Se hace cada ~80 días (antes de expirar). Diferencia clave vs emisión: aquí **reimportamos sobre el ARN existente** para no acumular certificados huérfanos en ACM.

```bash
# 1. SSM a una instancia del ASG (el user_data ya restauró /etc/letsencrypt desde EFS)
GLPI=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names asg-glpi-dracs \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
aws ssm start-session --target "$GLPI" --region us-east-1

# 2. Verificar que el estado de certbot está restaurado
ls /etc/letsencrypt/live/dracs-glpi/
# Esperado: cert.pem  chain.pem  fullchain.pem  privkey.pem  README

# 3. Renovar (certbot usa el estado existente y vuelve a tirar DNS-01)
sudo /opt/cb/bin/certbot renew --cert-name dracs-glpi

# 4. Localizar el ARN del cert existente en ACM
ACM_ARN=$(aws acm list-certificates --region us-east-1 \
  --query "CertificateSummaryList[?DomainName=='dracs-glpi.duckdns.org'].CertificateArn | [0]" \
  --output text)
echo "$ACM_ARN"

# 5. Reimportar SOBRE el ARN existente (--certificate-arn evita crear un cert nuevo)
sudo aws acm import-certificate --region us-east-1 \
  --certificate-arn "$ACM_ARN" \
  --certificate     fileb:///etc/letsencrypt/live/dracs-glpi/cert.pem \
  --private-key     fileb:///etc/letsencrypt/live/dracs-glpi/privkey.pem \
  --certificate-chain fileb:///etc/letsencrypt/live/dracs-glpi/chain.pem

# 6. Persistir el nuevo estado en EFS
sudo cp -a /etc/letsencrypt/. /mnt/efs/letsencrypt/
```

El `data "aws_acm_certificate"` con `most_recent = true` recoge el cert renovado automáticamente. **No hace falta un `terraform apply`** porque el ARN no cambia; AWS rota internamente el contenido del cert en el ALB.

> **Si por error usaste `aws acm import-certificate` sin `--certificate-arn`** y se creó un cert nuevo, bórralo después con `aws acm delete-certificate --certificate-arn <arn-nuevo>` para no dejar huérfanos.

---

## 5. Persistencia del estado de certbot en EFS

**Por qué:** las instancias del ASG son ganado, no mascotas. Si no persistes `/etc/letsencrypt/`:
- Cada renovación obligaría a registrar una **cuenta nueva** en Let's Encrypt (cuenta contra rate limits).
- Perderías los contadores de renovación; certbot podría intentar emitir uno completo en vez de renovar.

**Implementación** (commit `30ef220`):

1. **Tras emitir o renovar**, copia manual a EFS:
   ```bash
   sudo cp -a /etc/letsencrypt/. /mnt/efs/letsencrypt/
   ```

2. **El `user_data` del ASG** (`user_data/glpi_asg.sh.tpl`) restaura el directorio al arrancar la instancia:
   ```bash
   apt-get install -y certbot python3-certbot-dns-duckdns 2>/dev/null || true
   if [ -d /mnt/efs/letsencrypt/live ]; then
     cp -a /mnt/efs/letsencrypt/. /etc/letsencrypt/
   fi
   ```

**Matiz importante:** la instancia del ASG **NO sirve TLS**. El VirtualHost de Apache que escribe el `user_data` es solo `<VirtualHost *:80>` HTTP plano. El TLS termina en el ALB usando el cert de ACM. La razón de tener certbot dentro de la instancia es **solo para la renovación** vía SSM.

---

## 6. Historia: cómo se llegó aquí

### Fase 1 — HTTP-01 monolítico (Sprint 2, prototipo)

- Una EC2 t3.small con Apache + GLPI + MariaDB en local.
- Cert Let's Encrypt en `/etc/letsencrypt/live/dracs-glpi.duckdns.org/` del disco local.
- Apache cargaba el cert directamente para servir HTTPS en `:443`.
- Challenge HTTP-01: certbot dejaba un fichero en `/.well-known/acme-challenge/` y Let's Encrypt lo leía por HTTP plano.
- Renovación automática vía cron de certbot (`/etc/cron.d/certbot`).

**Limitación inherente:** instancia ≡ cert. Si destruías la EC2, perdías el cert. No era problema mientras la infra fuera monolítica.

Documentado en `G2-A-45` ("9. GLPI y Nginx").

### Fase 2 — TLS termination en ALB → forzado a DNS-01 (Sprint 2, refactor)

El refactor de Sprint 2 (commit `4ac4b9f`) introdujo ALB con terminación TLS multi-AZ + ASG. **HTTP-01 dejó de ser viable**:
- Listener `:80` del ALB hace 301 → `:443`, lo que rompe el challenge HTTP-01.
- Reconfigurar el listener cada 60-90 días para permitir el challenge era inviable.

**Pivote a DNS-01** con plugin `certbot-dns-duckdns`, e import del PEM a ACM (porque el ALB ya no puede leer del disco de una EC2).

### Fase 3 — Persistencia de certbot en EFS (Sprint 3)

Con ASG, las instancias son efímeras. El estado de certbot se perdía en cada reemplazo. Solución (commit `30ef220`): copiar `/etc/letsencrypt/` a EFS tras cada renovación y restaurarlo en `user_data`.

---

## 7. Pendientes y limitaciones conocidas

- **Renovación 100% manual.** Para automatizarla habría que: cron dentro del ASG (problemático porque las instancias rotan) **o** Lambda con plugin `dns-duckdns` (requiere IAM role custom, bloqueado por AWS Academy).
- **El `cp -a` a EFS post-renovación es manual.** Olvidarlo significa que la próxima instancia del ASG arranca sin el cert actualizado y `certbot renew` registra cuenta nueva.
- **Sin alerta de expiración.** No hay CloudWatch alarm que avise cuando el cert se acerca a 90 días. Calendario manual.

---

## 8. Referencias

- **Arquitectura ALB/NLB:** [AWS-BALANCEO.md](AWS-BALANCEO.md) — listener HTTPS:443 consume este cert
- **Runbook operativo:** [AWS-RUNBOOK.md](AWS-RUNBOOK.md) §5 → enlaza a este doc
- **`user_data/glpi_asg.sh.tpl`:** bloque que restaura `/etc/letsencrypt` desde EFS
- **`glpi_scaling.tf`:** `data "aws_acm_certificate" "glpi"` y `aws_lb_listener.alb_https`
- **Commits clave:**
  - `4ac4b9f` — refactor que introduce ALB y rompe HTTP-01
  - `30ef220` — persistencia de certbot en EFS
