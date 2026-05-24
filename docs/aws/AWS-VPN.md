# VPN y proxy interno

La conectividad con on-prem se monta sobre dos EC2 colocadas en la subnet pública-a. La primera (`ec2-wireguard-dracs`) actúa de gateway VPN site-to-site y reenvía paquetes entre la VPC y OPNsense. La segunda (`ec2-nginx-dracs`) hace de reverse proxy para que los usuarios de on-prem puedan llegar a GLPI con una URL interna fija sin depender del DNS dinámico del ALB.

# 1. EC2 WireGuard — Gateway VPN

---

Es el extremo AWS del túnel WireGuard. Vive en la subnet pública con IP privada fija (`10.0.1.10`) y una EIP propia para que OPNsense pueda apuntar el peer a una dirección estable.

| Atributo | Valor |
| --- | --- |
| Name | `ec2-wireguard-dracs` |
| Tipo | `t3.micro` |
| AMI | `data.aws_ami.ubuntu.id` (Ubuntu 24.04 LTS latest) |
| IP privada | `10.0.1.10` |
| EIP | `23.22.183.211` (al cambiar de cuenta, hay que actualizar el Endpoint en OPNsense) |
| `source_dest_check` | `false` (imprescindible para que actúe como router) |
| `lifecycle` | `ignore_changes = [ami, user_data]` (instancia "pet": no se reemplaza por cambios de AMI ni de user_data) |

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

# 3. EC2 Nginx — Redirector HTTP interno

---

Tras la simplificación de Sprint 2 Nginx ya no termina TLS ni hace `proxy_pass`. Su único trabajo es devolver un `301 Redirect` al dominio público para los usuarios que entran por la VPN. El certificado público del ALB (Let's Encrypt) sirve a todos los usuarios, incluido el tráfico interno, evitando el warning de navegador del cert autofirmado que existía antes.

| Atributo | Valor |
| --- | --- |
| Name | `ec2-nginx-dracs` |
| Tipo | `t3.micro` |
| AMI | `data.aws_ami.ubuntu.id` (Ubuntu 24.04 LTS latest) |
| IP privada | `10.0.1.20` |
| EIP | Ninguna (solo accesible desde el túnel WireGuard) |
| `lifecycle` | `ignore_changes = [ami, user_data]` |

# 4. user_data del Nginx

---

El `user_data` se inyecta con `templatefile()` para que Terraform ponga ahí la URL pública en tiempo de despliegue:

```hcl
user_data = templatefile("user_data/nginx.sh.tpl", {
  glpi_url = var.glpi_public_url
})
```

El script (`user_data/nginx.sh.tpl`) instala Nginx y escribe un único bloque `server`:

```nginx
server {
    listen 80;
    server_name _;
    # $uri (normalizado, merge_slashes on) en vez de $request_uri para que
    # un cliente con "//" en el path no propague esos slashes al Location.
    return 301 ${glpi_url}$uri$is_args$args;
}
```

`${glpi_url}` lo sustituye Terraform por el valor de `var.glpi_public_url` (por defecto `https://dracs-glpi.duckdns.org`). Cualquier petición HTTP que llegue al puerto 80 de Nginx se redirige al dominio público, donde el ALB termina TLS con el cert válido de Let's Encrypt. La variable `$uri` (no `$request_uri`) garantiza que `merge_slashes on` colapse cualquier `//` antes de construir el `Location`.

Acceso desde on-prem: `http://10.0.1.20/` (cualquier path). El navegador recibirá un 301 hacia `https://dracs-glpi.duckdns.org/<path>` y a partir de ahí el flujo es el mismo que el del tráfico público.

> **Nota:** Nginx solo escucha en HTTP:80, no en 443. No genera ni utiliza certificados. La simplificación elimina la complejidad de gestionar un cert autofirmado y el warning de navegador asociado.

# 5. Documentación relacionada

---

* **G2-A-59 — AWS.md** — visión general y decisiones de diseño
* **G2-A-65 — AWS-RED.md** — VPC, subnets y rutas que dependen de la ENI del WG EC2
* **G2-A-67 — AWS-BALANCEO.md** — ALB al que Nginx hace `proxy_pass`
* **G2-A-61 — AWS-SEGURIDAD.md** — Security Groups de WireGuard y Nginx
* `G2-A-53` (OPNsense) — el otro extremo del túnel WireGuard
