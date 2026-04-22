#!/bin/bash

# WireGuard VPN Server Configuration Script
# ==========================================
# Configura automáticamente un servidor WireGuard con peers predefinidos
# Interfaz: wg0
# IP del servidor: 10.8.0.1/24
# Peer OPNSense: 10.8.0.2/24
#
# Este script se ejecuta como root automáticamente en el user_data de la instancia
# Si necesita ser ejecutado manualmente:
#   sudo bash /path/to/wireguard.sh

set -e

echo "=== WireGuard VPN Server Setup ==="

# Actualizar paquetes
echo "[*] Actualizando paquetes..."
apt-get update -y > /dev/null 2>&1
apt-get upgrade -y > /dev/null 2>&1
apt-get install -y wireguard wireguard-tools iptables-persistent > /dev/null 2>&1

echo "[✓] Paquetes instalados"

# Habilitar IP forwarding
echo "[*] Habilitando IP forwarding..."
sysctl -w net.ipv4.ip_forward=1 > /dev/null
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf; then
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sysctl -p > /dev/null 2>&1

echo "[✓] IP forwarding habilitado"

# Crear directorio de configuración WireGuard
echo "[*] Preparando /etc/wireguard..."
mkdir -p /etc/wireguard/
chmod 700 /etc/wireguard/

# Generar keys del servidor si no existen
cd /etc/wireguard/

if [ ! -f privatekey ]; then
  echo "[*] Generando keys del servidor..."
  wg genkey | tee privatekey | wg pubkey > publickey
  chmod 600 privatekey
  chmod 644 publickey
  echo "[✓] Keys generadas"
else
  echo "[*] Keys ya existen, usando existentes"
fi

PRIVATE_KEY=$(cat privatekey)
PUBLIC_KEY=$(cat publickey)

echo "[*] Servidor WireGuard:"
echo "    Public Key: $PUBLIC_KEY"

# Crear archivo de configuración
echo "[*] Generando configuración wg0.conf..."

cat > /etc/wireguard/wg0.conf << 'WGCONFIG'
[Interface]
# IP del servidor WireGuard en la VPN
Address = 10.8.0.1/24
# Puerto que escucha WireGuard
ListenPort = 51820
# Private key del servidor (será reemplazado por el script)
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
# IP asignada a este peer (en la VPN)
AllowedIPs = 10.8.0.2/32
# Public key del peer (OPNSense genera esto)
PublicKey = IakGqi12LzA3dlAwRGGjBm5OVaGCFdwdaucrAHb6K2Y=
# Pre-shared key para mayor seguridad
PreSharedKey = f/ugcMua6IJzQkhLynGnIJSuCSbKZIRDNDyp6QH6JU8=
# Keep-alive para mantener túnel activo (importante si hay NAT)
PersistentKeepalive = 25
WGCONFIG

# Reemplazar placeholder con private key real
sed -i "s|WIREGUARD_PRIVATE_KEY_PLACEHOLDER|$PRIVATE_KEY|g" /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/wg0.conf

echo "[✓] Configuración creada: /etc/wireguard/wg0.conf"

# Bajar interfaz si existe (evita conflictos)
echo "[*] Preparando interfaz..."
wg-quick down wg0 2>/dev/null || true
sleep 1

# Activar interfaz WireGuard
echo "[*] Activando interfaz WireGuard..."
wg-quick up wg0

echo "[✓] WireGuard activo"

# Habilitar inicio automático con systemd
echo "[*] Habilitando inicio automático..."
systemctl enable wg-quick@wg0.service > /dev/null 2>&1
systemctl daemon-reload

echo "[✓] Autostart habilitado"

# Mostrar estado
echo ""
echo "=== ESTADO DE WIREGUARD ==="
echo "Interface: wg0"
echo "IP: 10.8.0.1/24"
echo "Puerto: 51820/UDP"
echo "Public Key: $PUBLIC_KEY"
echo ""
echo "Peers configurados:"
wg show wg0 | grep -A 5 "peer:" || echo "Esperando conexión de peers..."
echo ""
echo "Interfaces de red:"
ip addr show wg0
echo ""
echo "=== SETUP COMPLETADO ==="
echo "WireGuard está activo y configurado para autostart en futuros reinicios."
echo ""
echo "Para verificar el estado en el futuro:"
echo "  sudo wg show wg0"
echo "  sudo systemctl status wg-quick@wg0.service"
echo "  ip addr show wg0"
echo ""