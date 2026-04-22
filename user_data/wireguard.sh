#!/bin/bash

# WireGuard VPN Server Configuration Script
# ==========================================
# Configura automáticamente un servidor WireGuard con peers predefinidos
# Interfaz: wg0
# IP del servidor: 10.8.0.1/24
# Peer OPNSense: 10.8.0.2/24

set -e

echo "=== WireGuard VPN Server Setup ==="

# Actualizar paquetes
echo "[*] Actualizando paquetes..."
apt update -y
apt upgrade -y
apt install -y wireguard wireguard-tools curl net-tools resolvconf

# Habilitar IP forwarding
echo "[*] Habilitando IP forwarding..."
sysctl -w net.ipv4.ip_forward=1
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sysctl -p > /dev/null

# Crear directorio de configuración WireGuard
echo "[*] Preparando configuración WireGuard..."
mkdir -p /etc/wireguard/
chmod 700 /etc/wireguard/
cd /etc/wireguard/

# Generar keys del servidor si no existen
if [ ! -f privatekey ]; then
  echo "[*] Generando keys del servidor..."
  wg genkey | tee privatekey | wg pubkey > publickey
  chmod 600 privatekey
  chmod 644 publickey
fi

PRIVATE_KEY=$(cat privatekey)
PUBLIC_KEY=$(cat publickey)

echo "[*] Servidor WireGuard:"
echo "    Public Key: $PUBLIC_KEY"

# Configuración del servidor WireGuard
# ====================================
# Parámetros:
#   - Interface: wg0
#   - IP del servidor: 10.8.0.1/24
#   - Puerto Listen: 51820/UDP (abierto en Security Group)
#   - Peer OPNSense:
#       - IP: 10.8.0.2/24
#       - PublicKey: IakGqi12LzA3dlAwRGGjBm5OVaGCFdwdaucrAHb6K2Y=
#       - PreSharedKey: f/ugcMua6IJzQkhLynGnIJSuCSbKZIRDNDyp6QH6JU8=

cat > wg0.conf << 'EOF'
[Interface]
# IP del servidor WireGuard en la VPN
Address = 10.8.0.1/24
# Puerto que escucha WireGuard
ListenPort = 51820
# Private key del servidor (mantenido secreto)
PrivateKey = WIREGUARD_PRIVATE_KEY_PLACEHOLDER
# Post-up: Configurar NAT/forwarding al activar interfaz
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
# Pre-down: Limpiar reglas iptables al desactivar
PreDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

# ============================================================
# PEER 1: OPNSense
# ============================================================
# Peer que conecta desde OPNSense (remote site)
[Peer]
# Nombre descriptivo (solo para documentación)
# Comment = OPNSense-Firewall

# IP asignada a este peer (en la VPN)
AllowedIPs = 10.8.0.2/32
# Public key del peer (OPNSense genera esto)
PublicKey = IakGqi12LzA3dlAwRGGjBm5OVaGCFdwdaucrAHb6K2Y=
# Pre-shared key para mayor seguridad (opsional pero recomendado)
PreSharedKey = f/ugcMua6IJzQkhLynGnIJSuCSbKZIRDNDyp6QH6JU8=
# Keep-alive para mantener túnel activo (importante si hay NAT)
PersistentKeepalive = 25
EOF

# Reemplazar placeholder con private key real
sed -i "s|WIREGUARD_PRIVATE_KEY_PLACEHOLDER|$PRIVATE_KEY|g" wg0.conf
chmod 600 wg0.conf

echo "[*] Configuración WireGuard creada: /etc/wireguard/wg0.conf"

# Activar interfaz WireGuard
echo "[*] Activando interfaz WireGuard..."
ip link add dev wg0 type wireguard || true
ip addr add 10.8.0.1/24 dev wg0 || true
ip link set up dev wg0 || true

# Cargar configuración con wg-quick (más sencillo y portable)
wg-quick down wg0 2>/dev/null || true
sleep 1
wg-quick up wg0

# Habilitar inicio automático con systemd
echo "[*] Habilitando inicio automático..."
systemctl enable wg-quick@wg0.service
systemctl restart wg-quick@wg0.service

# Mostrar estado
echo "[*] Estado de WireGuard:"
wg show wg0

echo ""
echo "=== Configuración completada ==="
echo "Interface: wg0"
echo "IP Servidor: 10.8.0.1/24"
echo "Puerto: 51820/UDP"
echo "Peers configurados: 1 (OPNSense)"
echo ""
echo "Para verificar el estado:"
echo "  sudo wg show"
echo "  sudo ip addr show wg0"
echo ""
echo "URL de administración WireGuard (si aplica):"
echo "  ssh ubuntu@<wireguard_eip> 'sudo wg show'"
echo ""