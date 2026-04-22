#!/bin/bash

# WireGuard VPN Server Configuration Script
# ==========================================
# Configura automáticamente un servidor WireGuard con peer OPNsense
# Interfaz: wg0
# AWS:       10.8.0.2/24
# OPNsense:  10.8.0.1/32
#
# IMPORTANTE:
# La public key SIEMPRE depende de la private key.
# Si quieres mantener la misma public key tras reinstalar AWS,
# debes reutilizar la misma private key.

set -e

echo "=== WireGuard VPN Server Setup ==="

# -------------------------------------------------------------------
# VARIABLES HARDCODEADAS
# -------------------------------------------------------------------

# Private key fija del nodo AWS
AWS_PRIVATE_KEY="CCkfF3+aY3x9izEv5ixQYUg+GaNsAX3fBl6IvJNHaVI="

# Public key del peer OPNsense
OPNSENSE_PUBLIC_KEY="IakGqi12LzA3dlAwRGGjBm5OVaGCFdwdaucrAHb6K2Y="

# Pre-shared key compartida
WG_PRESHARED_KEY="f/ugcMua6IJzQkhLynGnIJSuCSbKZIRDNDyp6QH6JU8="

# Redes detrás de OPNsense a las que AWS podrá llegar por el túnel
OPNSENSE_ALLOWED_IPS="10.8.0.1/32,192.168.1.0/24,192.168.10.0/24,192.168.20.0/24"

# Interfaz de salida a Internet en AWS
WAN_IF="eth0"

# -------------------------------------------------------------------

echo "[*] Actualizando paquetes..."
apt-get update -y > /dev/null 2>&1
apt-get upgrade -y > /dev/null 2>&1
apt-get install -y wireguard wireguard-tools iptables-persistent > /dev/null 2>&1
echo "[✓] Paquetes instalados"

echo "[*] Habilitando IP forwarding..."
sysctl -w net.ipv4.ip_forward=1 > /dev/null
if ! grep -q "^net.ipv4.ip_forward=1$" /etc/sysctl.conf; then
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sysctl -p > /dev/null 2>&1
echo "[✓] IP forwarding habilitado"

echo "[*] Preparando /etc/wireguard..."
mkdir -p /etc/wireguard/
chmod 700 /etc/wireguard/
cd /etc/wireguard/

echo "[*] Escribiendo private key fija del servidor AWS..."
printf '%s\n' "$AWS_PRIVATE_KEY" > privatekey
chmod 600 privatekey

PUBLIC_KEY=$(printf '%s' "$AWS_PRIVATE_KEY" | wg pubkey)
printf '%s\n' "$PUBLIC_KEY" > publickey
chmod 644 publickey

echo "[✓] Keys preparadas"
echo "[*] Servidor WireGuard:"
echo "    Public Key: $PUBLIC_KEY"

echo "[*] Generando configuración wg0.conf..."

cat > /etc/wireguard/wg0.conf << WGCONFIG
[Interface]
Address = 10.8.0.2/24
ListenPort = 51820
PrivateKey = ${AWS_PRIVATE_KEY}

PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${WAN_IF} -j MASQUERADE
PreDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${WAN_IF} -j MASQUERADE

[Peer]
PublicKey = ${OPNSENSE_PUBLIC_KEY}
PreSharedKey = ${WG_PRESHARED_KEY}
AllowedIPs = ${OPNSENSE_ALLOWED_IPS}
PersistentKeepalive = 25
WGCONFIG

chmod 600 /etc/wireguard/wg0.conf

echo "[✓] Configuración creada: /etc/wireguard/wg0.conf"

echo "[*] Preparando interfaz..."
wg-quick down wg0 2>/dev/null || true
sleep 1

echo "[*] Activando interfaz WireGuard..."
wg-quick up wg0
echo "[✓] WireGuard activo"

echo "[*] Habilitando inicio automático..."
systemctl daemon-reload
systemctl enable wg-quick@wg0.service > /dev/null 2>&1
echo "[✓] Autostart habilitado"

echo ""
echo "=== ESTADO DE WIREGUARD ==="
echo "Interface: wg0"
echo "IP AWS: 10.8.0.2/24"
echo "Peer OPNsense: 10.8.0.1/32"
echo "Red remota OPNsense: 192.168.1.0/24"
echo "Puerto: 51820/UDP"
echo "Public Key AWS: $PUBLIC_KEY"
echo ""
echo "Peers configurados:"
wg show wg0 | grep -A 5 "peer:" || echo "Esperando conexión de peers..."
echo ""
echo "Interfaces de red:"
ip addr show wg0
echo ""
echo "=== SETUP COMPLETADO ==="
echo "Para verificar:"
echo "  sudo wg show wg0"
echo "  sudo systemctl status wg-quick@wg0.service"
echo "  ip route"
echo ""