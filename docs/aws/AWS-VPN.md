# VPN y proxy interno

La conectividad con on-prem se monta sobre dos EC2 colocadas en la subnet pública-a. La primera (`ec2-wireguard-dracs`) actúa de gateway VPN site-to-site y reenvía paquetes entre la VPC y OPNsense. La segunda (`ec2-nginx-dracs`) hace de reverse proxy para que los usuarios de on-prem puedan llegar a GLPI con una URL interna fija sin depender del DNS dinámico del ALB.

# 1. EC2 WireGuard — Gateway VPN

---

Es el extremo AWS del túnel WireGuard. Vive en la subnet pública con IP privada fija (`10.0.1.10`) y una EIP propia para que OPNsense pueda apuntar el peer a una dirección estable.

| Atributo | Valor |
| --- | --- |
| Name | `ec2-wireguard-dracs` |
| Tipo | `t3.micro` |
| AMI | `var.wireguard_ami_id` (custom de la cuenta anterior) o Ubuntu 24.04 LTS si vacía |
| IP privada | `10.0.1.10` |
| EIP | `34.204.119.208` (al cambiar de cuenta, hay que actualizar el Endpoint en OPNsense) |
| `source_dest_check` | `false` (imprescindible para que actúe como router) |

![](aws-wireguard-ec2.png){width=900px}
<!-- captura: AWS Console → EC2 → Instances → ec2-wireguard-dracs → Details -->

# 2. user_data del WireGuard

---

El `user_data` se ejecuta en cada arranque inicial de la instancia y deja todo configurado sin intervención manual:

1. Instala el paquete `wireguard`.
2. Habilita IP forwarding persistente en `/etc/sysctl.d/99-wireguard-forwarding.conf` (sin esto la EC2 no enrutaría los paquetes que reciba con destino fuera de sí misma).
3. Escribe `/etc/wireguard/wg0.conf` con las claves inyectadas desde `terraform.tfvars` mediante `templatefile()`.
4. Levanta el servicio (`systemctl enable --now wg-quick@wg0`).

Las claves son **sensitive** y no se commitean. Se inyectan así:

```hcl
user_data = templatefile("user_data/wireguard.sh.tpl", {
  aws_private_key     = var.wg_aws_private_key
  opnsense_public_key = var.wg_opnsense_public_key
  preshared_key       = var.wg_preshared_key
})
```

El fichero `wg0.conf` resultante queda con esta forma:

```ini
[Interface]
Address    = 10.8.0.2/24
ListenPort = 51820
PrivateKey = <wg_aws_private_key>
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; \
           iptables -A FORWARD -o wg0 -j ACCEPT; \
           iptables -t nat -A POSTROUTING -o $ETH ! -d 10.0.0.0/8 -j MASQUERADE
PreDown  = (las inversas)

[Peer]
PublicKey           = <wg_opnsense_public_key>
PresharedKey        = <wg_preshared_key>
AllowedIPs          = 10.8.0.1/32, 192.168.1.0/24, 192.168.10.0/24, 192.168.20.0/24
PersistentKeepalive = 25
```

> **Nota sobre el MASQUERADE:** la regla NATea sólo el tráfico que sale por la interfaz Ethernet (`ens5`) hacia destinos que **no** sean de la red interna (`10.0.0.0/8`). Esto permite que tráfico desde 10.8.0.x hacia internet llegue NATeado, pero el tráfico entre VPC y on-prem no se NATea (se enruta tal cual), preservando IPs origen. Sin esta excepción, el DC vería todas las conexiones como provenientes del WG EC2 y no del ASG.

> **Nota sobre la interfaz:** en Ubuntu 24.04 la interfaz Ethernet por defecto se llama `ens5`, no `eth0`. El script detecta dinámicamente el nombre con `ip route show default | awk '{print $5}'` y lo usa para el MASQUERADE.

# 3. EC2 Nginx — Reverse Proxy interno

---

Esta EC2 sirve como pasarela HTTPS interna para los usuarios que llegan desde on-prem. Aunque desde la VPN podrían acceder al ALB directamente, Nginx aísla el DNS interno del externo y permite controlar/loggear el tráfico interno por separado.

| Atributo | Valor |
| --- | --- |
| Name | `ec2-nginx-dracs` |
| Tipo | `t3.micro` |
| AMI | `var.nginx_ami_id` (custom) o Ubuntu 24.04 LTS |
| IP privada | `10.0.1.20` |
| EIP | `34.205.176.217` |

# 4. user_data del Nginx

---

El `user_data` se inyecta con `templatefile()` para que Terraform ponga ahí el DNS del ALB en tiempo de despliegue. Si el ALB se recrea, hay que re-aplicar Terraform y reemplazar la instancia Nginx para que coja el nuevo DNS.

```hcl
user_data = templatefile("user_data/nginx.sh.tpl", {
  alb_dns = aws_lb.alb.dns_name
})
```

El script:

1. Instala `nginx` y `openssl`.
2. Genera un certificado autofirmado (`/etc/nginx/ssl/dracs.crt`) si no existe, válido 10 años, CN `dracs.local`.
3. Escribe `/etc/nginx/sites-available/glpi` con dos `server`:
   - Puerto 80 → `return 301 https://$host$request_uri;`
   - Puerto 443 → `proxy_pass http://<alb_dns>` con headers `Host`, `X-Real-IP`, `X-Forwarded-For`, `X-Forwarded-Proto`.
4. Habilita el sitio, deshabilita el default, valida y reinicia Nginx.

Acceso desde on-prem: `https://10.0.1.20/` (o el alias DNS interno configurado en el AD). El certificado autofirmado dispara el warning de navegador la primera vez, pero al ser tráfico interno se asume ese coste.

> **Nota:** el cert autofirmado se usa **solo** dentro de la VPN. El tráfico desde internet llega por el NLB/ALB, donde el cert es el público de Let's Encrypt (ver `AWS-BALANCEO.md`).

# 5. Documentación relacionada

---

* **AWS.md** — visión general y decisiones de diseño
* **AWS-RED.md** — VPC, subnets y rutas que dependen de la ENI del WG EC2
* **AWS-BALANCEO.md** — ALB al que Nginx hace `proxy_pass`
* **AWS-SEGURIDAD.md** — Security Groups de WireGuard y Nginx
* `G2-A-53` (OPNsense) — el otro extremo del túnel WireGuard
