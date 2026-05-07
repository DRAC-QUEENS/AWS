#!/bin/bash
set -e

# =============================================================================
# WireGuard VPN Gateway Setup for AWS
# =============================================================================
# Configura una instancia EC2 como servidor WireGuard para site-to-site VPN.
# On-prem (OPNsense) se conecta como cliente a esta instancia.
#
# Configuracion:
#   - Interfaz: wg0 (10.8.0.2/24)
#   - Puerto: 51820/UDP
#   - Peer remoto: OPNsense (10.8.0.1/32, 192.168.1.0/24, 192.168.10.0/24, 192.168.20.0/24)
#
# Las claves se inyectan via Terraform templatefile() desde variables sensitive
# (var.wg_aws_private_key, var.wg_opnsense_public_key, var.wg_preshared_key).
# =============================================================================

echo "[$(date)] === WireGuard Gateway Setup Started ==="

# Paso 1: Instalar paquetes
echo "[$(date)] Instalando WireGuard..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard wireguard-tools iptables-persistent
echo "[OK] WireGuard instalado"

# Paso 2: Habilitar IP forwarding (necesario para actuar como router)
echo "[$(date)] Habilitando IP forwarding..."
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-wireguard-forwarding.conf
sysctl -p /etc/sysctl.d/99-wireguard-forwarding.conf
echo "[OK] IP forwarding activo"

# Paso 3: Crear config de WireGuard
echo "[$(date)] Creando configuracion WireGuard..."
mkdir -p /etc/wireguard/
chmod 700 /etc/wireguard/

# Detectar la interfaz de red principal (ens5 en Ubuntu 24.04 en AWS)
ETH=$(ip route | grep default | awk '{print $5}' | head -1)
echo "[OK] Interfaz de red detectada: $ETH"

cat > /etc/wireguard/wg0.conf << EOF
[Interface]
Address = 10.8.0.2/24
ListenPort = 51820
PrivateKey = ${aws_private_key}

PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $ETH ! -d 10.0.0.0/8 -j MASQUERADE
PreDown  = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $ETH ! -d 10.0.0.0/8 -j MASQUERADE

[Peer]
PublicKey = ${opnsense_public_key}
PreSharedKey = ${preshared_key}
AllowedIPs = 10.8.0.1/32,192.168.1.0/24,192.168.10.0/24,192.168.20.0/24
PersistentKeepalive = 25
EOF

chmod 600 /etc/wireguard/wg0.conf
echo "[OK] Configuracion WireGuard creada"

# Paso 4: Iniciar WireGuard (idempotente: bajar antes de subir por si ya estaba)
echo "[$(date)] Iniciando WireGuard..."
wg-quick down wg0 2>/dev/null || true
wg-quick up wg0
systemctl enable wg-quick@wg0.service
echo "[OK] WireGuard iniciado y habilitado en boot"

echo "[$(date)] === FIN ==="
