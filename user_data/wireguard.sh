#!/bin/bash

# =============================================================================
# WireGuard VPN Gateway Setup for AWS
# =============================================================================
# Configura una instancia EC2 como servidor WireGuard para site-to-site VPN.
# On-prem (OPNsense) se conecta como cliente a esta instancia.
#
# Configuración:
#   - Interfaz: wg0 (10.8.0.2/24)
#   - Puerto: 51820/UDP
#   - Peer remoto: OPNsense (10.8.0.1/32, 192.168.1.0/24, 192.168.10.0/24, 192.168.20.0/24)
# =============================================================================

echo "[$(date)] === WireGuard Gateway Setup Started ==="

# Variables de configuración
AWS_PRIVATE_KEY="CCkfF3+aY3x9izEv5ixQYUg+GaNsAX3fBl6IvJNHaVI="
OPNSENSE_PUBLIC_KEY="IakGqi12LzA3dlAwRGGjBm5OVaGCFdwdaucrAHb6K2Y="
WG_PRESHARED_KEY="f/ugcMua6IJzQkhLynGnIJSuCSbKZIRDNDyp6QH6JU8="
OPNSENSE_ALLOWED_IPS="10.8.0.1/32,192.168.1.0/24,192.168.10.0/24,192.168.20.0/24"

# Paso 1: Instalar paquetes
echo "[$(date)] Instalando WireGuard..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard wireguard-tools iptables-persistent
echo "[✓] WireGuard instalado"

# Paso 2: Habilitar IP forwarding (necesario para actuar como router)
echo "[$(date)] Habilitando IP forwarding..."
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard-forwarding.conf
sysctl -p /etc/sysctl.d/99-wireguard-forwarding.conf
echo "[✓] IP forwarding activo: $(cat /proc/sys/net/ipv4/ip_forward)"

# Paso 3: Crear config de WireGuard
echo "[$(date)] Creando configuración WireGuard..."
mkdir -p /etc/wireguard/
chmod 700 /etc/wireguard/

# Detectar la interfaz de red principal (ens5 en Ubuntu 24.04 en AWS)
ETH=$(ip route | grep default | awk '{print $5}' | head -1)
echo "[✓] Interfaz de red detectada: ${ETH}"

cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = 10.8.0.2/24
ListenPort = 51820
PrivateKey = ${AWS_PRIVATE_KEY}

PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${ETH} ! -d 10.0.0.0/8 -j MASQUERADE
PreDown  = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${ETH} ! -d 10.0.0.0/8 -j MASQUERADE

[Peer]
PublicKey = ${OPNSENSE_PUBLIC_KEY}
PreSharedKey = ${WG_PRESHARED_KEY}
AllowedIPs = ${OPNSENSE_ALLOWED_IPS}
PersistentKeepalive = 25
EOF

chmod 600 /etc/wireguard/wg0.conf
echo "[✓] Configuración WireGuard creada"

# Paso 4: Iniciar WireGuard
echo "[$(date)] Iniciando WireGuard..."
wg-quick up wg0
systemctl enable wg-quick@wg0.service
echo "[✓] WireGuard iniciado y habilitado en boot"

# Verificación
echo "[$(date)] === Verificación final ==="
echo "Interface wg0:"
ip addr show wg0 | grep "inet 10.8"
echo "Rutas:"
ip route | grep 192.168
echo "Servicio:"
ip link show wg0 | grep -o "state [A-Z]*"
echo "[✓] WireGuard Setup Completed"

echo "[$(date)] === FIN ==="
