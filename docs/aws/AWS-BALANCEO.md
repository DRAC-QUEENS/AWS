# Balanceadores y TLS

El frente de GLPI desde internet es la combinación NLB + ALB. El NLB existe únicamente para tener una IP fija (la EIP) a la que apuntar DuckDNS; toda la lógica HTTP, la terminación TLS y los health checks viven en el ALB. El certificado se emite con certbot vía DNS-01 contra DuckDNS y se importa en ACM.

# 1. Network Load Balancer (NLB)

---

El ALB tiene DNS pero sus IPs pueden cambiar, lo que choca con DuckDNS que necesita una IP estable. El NLB sí permite EIP fija, así que actúa de portero en capa 4 y reenvía a ciegas al ALB.

| Atributo | Valor |
| --- | --- |
| Name | `nlb-glpi-dracs` |
| Tipo | Network Load Balancer (capa 4) |
| Scheme | internet-facing |
| EIP | `35.175.33.121` (DuckDNS apunta aquí) |
| AZ | us-east-1a (un único mapping; la EIP solo puede ir a una AZ) |
| Listeners | `TCP:80`, `TCP:443` |

Cada listener forwardea a un target group de tipo `alb`:

| Listener | Target group | Destino |
| --- | --- | --- |
| `TCP:80` | `nlb-to-alb-dracs` | ALB:80 |
| `TCP:443` | `nlb-to-alb-443-dracs` | ALB:443 |

Los target groups con `target_type = "alb"` son una integración nativa que permite usar el ALB como target del NLB sin tener que listar IPs (que cambiarían con el tiempo).
r
> **Nota:** el NLB no tiene Security Group propio (no es soportado en NLBs de tipo classic). El filtrado lo hace el SG del ALB.

# 2. Application Load Balancer (ALB)

---

El ALB es internet-facing en las dos AZs (publica-a y publica-b) y termina el TLS.

| Atributo | Valor |
| --- | --- |
| Name | `alb-glpi-dracs` |
| Tipo | Application Load Balancer (capa 7) |
| Scheme | internet-facing |
| Subnets | publica-a + publica-b (multi-AZ) |
| Security Group | `alb-glpi-dracs` |
| DNS | `alb-glpi-dracs-1397970751.us-east-1.elb.amazonaws.com` (cambia al recrear el ALB; recupera con `aws elbv2 describe-load-balancers --names alb-glpi-dracs --query 'LoadBalancers[0].DNSName' --output text`) |
| Listeners | HTTP:80 (redirect 301 a HTTPS), HTTPS:443 (cert ACM) |

![](aws-alb.png){width=900px}
<!-- captura: AWS Console → EC2 → Load Balancers → alb-glpi-dracs → Listeners -->

**Listener HTTP:80** — no sirve contenido. Tiene una sola acción de redirect 301 a HTTPS:

```hcl
default_action {
  type = "redirect"
  redirect {
    port        = "443"
    protocol    = "HTTPS"
    status_code = "HTTP_301"
  }
}
```

**Listener HTTPS:443** — termina el TLS y reenvía al target group de GLPI:

```hcl
ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-2021-06"
certificate_arn = data.aws_acm_certificate.glpi.arn

default_action {
  type             = "forward"
  target_group_arn = aws_lb_target_group.glpi.arn
}
```

# 3. Target groups y health checks

---

| Target group | Protocolo:Puerto | Type | Targets | Health check |
| --- | --- | --- | --- | --- |
| `tg-glpi-dracs` | HTTP:80 | instance | instancias del ASG (registradas dinámicamente) | path `/`, matcher `200-302`, intervalo 30s, healthy 2 / unhealthy 3 |
| `nlb-to-alb-dracs` | TCP:80 | alb | ALB:80 | HTTP `/`, matcher `200-302` |
| `nlb-to-alb-443-dracs` | TCP:443 | alb | ALB:443 | HTTPS `/`, matcher `200-302` |

> **Nota sobre el path:** se usa `/` como path de health check, no `/glpi/`, porque el Apache de las instancias del ASG está configurado con `DocumentRoot=/var/www/html/glpi` y sirve GLPI en la raíz. Ver `G2-A-66` / `AWS-GLPI.md` para el detalle de por qué.

El `target_group_attachment` del NLB al ALB depende explícitamente de que exista el listener correspondiente del ALB:

```hcl
resource "aws_lb_target_group_attachment" "nlb_to_alb_443" {
  target_group_arn = aws_lb_target_group.nlb_to_alb_443.arn
  target_id        = aws_lb.alb.arn
  port             = 443
  depends_on       = [aws_lb_listener.alb_https]
}
```

Sin este `depends_on` el primer `terraform apply` falla con un error de validación porque el ALB todavía no tiene listener 443 cuando se intenta registrar el attachment.

# 4. Certificado TLS

---

El ALB termina TLS en `:443` con un certificado Let's Encrypt para `dracs-glpi.duckdns.org`, emitido vía DNS-01 (plugin `certbot-dns-duckdns`) e importado a ACM. El listener lo consume vía `data "aws_acm_certificate"` con `most_recent = true`.

**Documentación completa**: [AWS-CERTIFICADO.md](AWS-CERTIFICADO.md) — arquitectura, emisión inicial, renovación cada 90 días, persistencia en EFS e historia.

# 5. Flujo del tráfico

---

**Desde internet:**

```
1. Usuario → https://dracs-glpi.duckdns.org/
2. DuckDNS resuelve → 35.175.33.121 (EIP NLB)
3. NLB:TCP:443 → ALB:443
4. ALB descifra TLS con el cert ACM
5. ALB → target group tg-glpi-dracs → instancia del ASG en HTTP:80
6. GLPI procesa, lee/escribe RDS+EFS, responde
7. Respuesta vuelve cifrada al usuario
```

**Desde on-prem:**

```
1. Usuario interno → http://10.0.1.20/ (Nginx)
2. Nginx devuelve 301 → https://dracs-glpi.duckdns.org/<path>
3. A partir de aquí, mismo flujo que el del tráfico público (DuckDNS → NLB → ALB → ASG)
```

> **Nota:** Nginx ya no termina TLS ni hace `proxy_pass`. Todos los usuarios — internos y externos — consumen el cert público del ALB.

# 6. Documentación relacionada

---

* **G2-A-59 — AWS.md** — visión general
* **G2-A-65 — AWS-RED.md** — subnets en las que viven NLB y ALB
* **G2-A-66 — AWS-GLPI.md** — target group del ASG y health check path
* **G2-A-61 — AWS-SEGURIDAD.md** — Security Group del ALB (80/443 desde 0.0.0.0/0 y desde Nginx SG)
* **AWS-CERTIFICADO.md** — todo sobre el certificado TLS: arquitectura, emisión, renovación 90d, persistencia EFS, historia
* **G2-A-64 — AWS-RUNBOOK.md** — runbook operativo general
