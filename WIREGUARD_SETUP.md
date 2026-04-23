# WireGuard Site-to-Site VPN: AWS ↔ On-Prem

## 📋 Resumen arquitectura

```
On-Prem (OPNsense)                    Internet                     AWS (Ubuntu)
─────────────────────────────────────────────────────────────────────────────
192.168.1.0/24 ┐                                                  10.0.1.0/24 ┐
192.168.10.0/24├─► OPNsense WireGuard ◄──WireGuard Tunnel──► WireGuard Instance
192.168.20.0/24┘    10.8.0.1/32                               10.8.0.2/24
                    (client)                                  (server)
                                                              13.219.172.135:51820
```

## 🔧 Configuración en AWS

### 1. Instancia EC2 WireGuard

**Especificaciones:**
```hcl
resource "aws_instance" "wireguard" {
  ami                    = "ubuntu-24.04"
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.public.id
  private_ip             = "10.0.1.10"
  source_dest_check      = false          # ← CRÍTICO: permite NAT/túnel
  vpc_security_group_ids = [aws_security_group.wireguard.id]
  user_data              = file("user_data/wireguard.sh")
}
```

**`source_dest_check = false`**: Permite que la instancia actúe como router. Sin esto, AWS descarta paquetes que no vienen/van de su IP privada.

### 2. Security Group para WireGuard

```hcl
resource "aws_security_group" "wireguard" {
  name = "wireguard-dracs"
  
  # Tráfico VPN desde cualquier origen
  ingress {
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  # SSH solo desde clientes VPN (10.8.0.0/24)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.8.0.0/24"]    # Rango de clientes WG
  }
  
  # Salida: todo
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
```

### 3. Elastic IP (EIP)

```hcl
resource "aws_eip" "wireguard" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.igw]
}

resource "aws_eip_association" "wireguard" {
  instance_id   = aws_instance.wireguard.id
  allocation_id = aws_eip.wireguard.id
}
```

**¿Por qué una EIP?** Las IPs públicas de AWS pueden cambiar con reboot. La EIP es persistente → los clientes VPN siempre conectan a la misma dirección.

### 4. Rutas para llegar a on-prem

```hcl
# En route_table pública
resource "aws_route" "to_onprem_mgmt" {
  route_table_id         = aws_route_table.publica.id
  destination_cidr_block = "192.168.1.0/24"              # Proxmox mgmt
  network_interface_id   = aws_instance.wireguard.primary_network_interface_id
}

resource "aws_route" "to_onprem_servers" {
  route_table_id         = aws_route_table.publica.id
  destination_cidr_block = "192.168.10.0/24"             # VLAN 10
  network_interface_id   = aws_instance.wireguard.primary_network_interface_id
}

resource "aws_route" "to_onprem_clients" {
  route_table_id         = aws_route_table.publica.id
  destination_cidr_block = "192.168.20.0/24"             # VLAN 20
  network_interface_id   = aws_instance.wireguard.primary_network_interface_id
}
```

**Efecto**: El tráfico de AWS instances hacia `192.168.x.x` se envía a la ENI (network interface) de WireGuard, que lo encapsula en el túnel.

## 📝 Configuración en la instancia EC2

### Script user_data (`wireguard.sh`)

```bash
#!/bin/bash

# Variables fijas (generadas de antemano)
AWS_PRIVATE_KEY="CCkfF3+aY3x9izEv5ixQYUg+GaNsAX3fBl6IvJNHaVI="
OPNSENSE_PUBLIC_KEY="IakGqi12LzA3dlAwRGGjBm5OVaGCFdwdaucrAHb6K2Y="
WG_PRESHARED_KEY="f/ugcMua6IJzQkhLynGnIJSuCSbKZIRDNDyp6QH6JU8="
OPNSENSE_ALLOWED_IPS="10.8.0.1/32,192.168.1.0/24,192.168.10.0/24,192.168.20.0/24"

# 1. Instalar WireGuard
apt-get update
apt-get install -y wireguard wireguard-tools iptables-persistent

# 2. Habilitar IP forwarding (para actuar de router)
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# 3. Crear directorio y keys
mkdir -p /etc/wireguard/
chmod 700 /etc/wireguard/
printf '%s\n' "$AWS_PRIVATE_KEY" > /etc/wireguard/privatekey
chmod 600 /etc/wireguard/privatekey

# 4. Generar public key a partir de private
PUBLIC_KEY=$(printf '%s' "$AWS_PRIVATE_KEY" | wg pubkey)

# 5. Crear configuración wg0.conf
cat > /etc/wireguard/wg0.conf << 'WGCONFIG'
[Interface]
Address = 10.8.0.2/24              # IP dentro del túnel
ListenPort = 51820                 # Puerto VPN
PrivateKey = [AWS_PRIVATE_KEY]

# Reglas iptables para masquerading (NAT)
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; \
           iptables -A FORWARD -o wg0 -j ACCEPT; \
           iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PreDown  = iptables -D FORWARD -i wg0 -j ACCEPT; \
           iptables -D FORWARD -o wg0 -j ACCEPT; \
           iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
PublicKey        = [OPNSENSE_PUBLIC_KEY]
PreSharedKey     = [WG_PRESHARED_KEY]
AllowedIPs       = 10.8.0.1/32,192.168.1.0/24,192.168.10.0/24,192.168.20.0/24
PersistentKeepalive = 25           # Mantiene conexión activa
WGCONFIG

# 6. Habilitar interfaz
wg-quick up wg0
systemctl enable wg-quick@wg0.service
```

### Desglose de configuración

| Parámetro | Valor | Propósito |
|-----------|-------|----------|
| `Address` | `10.8.0.2/24` | IP de AWS dentro del túnel WireGuard |
| `ListenPort` | `51820` | Puerto UDP para conexiones entrantes (OPNsense) |
| `PrivateKey` | Fija (hardcoded) | Permite que public key sea siempre la misma |
| `PostUp` | iptables NAT | Tráfico entre wg0 ↔ eth0 pasa por NAT |
| `[Peer]` | OPNsense | Configuración del cliente VPN remoto |

## 🔑 Generación de claves

### Paso 1: Crear par de claves privada/pública

```bash
# Generar private key (cualquier máquina con wg-tools)
wg genkey > aws_private.key
chmod 600 aws_private.key

# Extraer public key
cat aws_private.key | wg pubkey > aws_public.key
```

**Resultado:**
```
aws_private.key: CCkfF3+aY3x9izEv5ixQYUg+GaNsAX3fBl6IvJNHaVI=
aws_public.key:  y8LCqXLHCqqGG38Oon4JN4xS/OtcHLS9Un7OS8E7y0Q=
```

### Paso 2: Pre-shared key (opcional pero recomendado)

```bash
wg genpsk > preshared.key
# Resultado: f/ugcMua6IJzQkhLynGnIJSuCSbKZIRDNDyp6QH6JU8=
```

**¿Para qué?** Capas de seguridad adicional. Incluso si alguien obtiene la public key, no puede conectar sin el PSK.

## 🔌 Configuración en OPNsense (cliente)

### En OPNsense Web UI

**Rutas:** System > Routing > WireGuard

1. Crear tunnel WireGuard:
   - **Name:** AWS
   - **Private Key:** [generado en OPNsense]
   - **Public Key:** IakGqi12LzA3dlAwRGGjBm5OVaGCFdwdaucrAHb6K2Y=
   - **Address:** 10.8.0.1/32
   - **Port:** 51820 (o diferente si lo deseas)

2. Añadir peer (AWS):
   - **Public Key:** y8LCqXLHCqqGG38Oon4JN4xS/OtcHLS9Un7OS8E7y0Q=
   - **Pre-Shared Key:** f/ugcMua6IJzQkhLynGnIJSuCSbKZIRDNDyp6QH6JU8=
   - **Endpoint:** 13.219.172.135:51820
   - **Allowed IPs:** 10.8.0.2/32, 10.0.0.0/16 (AWS VPC)
   - **Persistent Keepalive:** 25

## ✅ Verificación

### En AWS (SSH a 13.219.172.135)

**⚠️ NOTA:** SSH está restringido a 10.8.0.0/24 (clientes VPN). Para SSH desde WSL, necesitas:

**Opción A:** Abrir SSH temporalmente (desarrollo)
```hcl
# En security.tf, cambiar:
ingress {
  from_port   = 22
  to_port     = 22
  protocol    = "tcp"
  cidr_blocks = ["0.0.0.0/0"]   # Abierto (¡PELIGRO en producción!)
}
# Luego: terraform apply -target=aws_security_group.wireguard
```

**Opción B:** SSH desde on-prem a través del túnel VPN (una vez activo)
```bash
# Desde máquina on-prem conectada al túnel
ssh ubuntu@10.8.0.2
```

**Opción C:** Usar EC2 Instance Connect (AWS Web Console)
- Ir a EC2 Dashboard → Select instance → Connect → EC2 Instance Connect

### Comandos de verificación (una vez con SSH acceso)

```bash
# Ver interfaz WireGuard activa
ip addr show wg0
# Output: inet 10.8.0.2/24 scope global wg0

# Ver estado de la conexión
wg show wg0
# Output: interface: wg0
#         public key: y8LCqXLHCqqGG38Oon4JN4xS/OtcHLS9Un7OS8E7y0Q=
#         private key: (hidden)
#         listening port: 51820
#
#         peer: IakGqi12LzA3dlAwRGGjBm5OVaGCFdwdaucrAHb6K2Y=
#         endpoint: 192.168.1.X:XXXXX
#         allowed ips: 10.8.0.1/32, 192.168.1.0/24, 192.168.10.0/24, 192.168.20.0/24
#         latest handshake: 2 minutes, 15 seconds ago
#         transfer: 123.45 KiB received, 456.78 KiB sent

# Probar conectividad a on-prem
ping 192.168.10.20    # Zabbix
ping 192.168.1.11     # Proxmox nodo1

# Ver rutas
ip route | grep 192.168
```

### En OPNsense (vía web)

```
Status > Routing > WireGuard
└─ Debería mostrar:
   - Tunnel "AWS" UP
   - Peer con "Latest Handshake" reciente
   - Transfer: datos siendo enviados/recibidos
```

## 🚀 Resumen: Cómo funciona el túnel

```
1. APLICACIÓN EN AWS (ej: GLPI)
   └─ Quiere alcanzar 192.168.10.30 (Wazuh)
   └─ Consulta route table → "192.168.10.0/24 → wireguard instance"

2. AWS WIREGUARD INSTANCE
   └─ Recibe paquete destino 192.168.10.30
   └─ Lo encapsula: [IP header original] → [WireGuard header]
   └─ Envía UDP:51820 hacia OPNsense@192.168.1.X
   └─ Aplicar iptables NAT (10.8.0.2 como source)

3. OPNsense (internet)
   └─ Recibe UDP:51820 desde 13.219.172.135
   └─ Desencapsula con private key de OPNsense
   └─ Obtiene paquete original destino 192.168.10.30
   └─ Lo enruta localmente a 192.168.10.30 vía VLAN10

4. RESPUESTA (inversa)
   └─ 192.168.10.30 → responde al sender 10.8.0.2
   └─ OPNsense encapsula → envía UDP:51820 hacia AWS (13.219.172.135)
   └─ AWS desencapsula, iptables deshace NAT
   └─ Entrega respuesta a aplicación GLPI
```

## 📌 Puntos clave

| Aspecto | Razón |
|--------|-------|
| `source_dest_check = false` | Permite que WireGuard actúe de router/NAT |
| `EIP` | Endpoint VPN permanente (importante para clientes) |
| Rutas en route tables | AWS instances encuentran camino a on-prem |
| `PersistentKeepalive = 25` | OPNsense envía keepalive cada 25s (mantiene NAT abierto) |
| iptables MASQUERADE | Tráfico origen 10.8.0.x se ve como 10.8.0.2 (previene routing asimétrico) |
| Private key fija | Public key derivada es siempre la misma |

## 🔧 Troubleshooting

```bash
# Ver logs de WireGuard
journalctl -u wg-quick@wg0 -f

# Comprobar iptables
iptables -L -n -v | grep FORWARD
iptables -t nat -L -n -v | grep POSTROUTING

# Revisar IP forwarding
sysctl net.ipv4.ip_forward    # Debe ser = 1

# Test de conectividad (desde AWS)
ping -c 1 192.168.10.20
mtr -r 192.168.10.20          # Traceroute
```

---

**Este setup convierte la instancia WireGuard en un "gateway VPN" que permite a TODO el VPC (10.0.0.0/16) alcanzar las redes on-prem, sin que cada instancia necesite configurar WireGuard individualmente.**
