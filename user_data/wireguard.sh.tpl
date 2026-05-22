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
# MTU 1420 estandar WireGuard sobre internet. El default heredado del ens5
# (jumbo 9001 -> wg0=8921) anuncia un MSS demasiado grande y provoca perdida
# silenciosa de paquetes TCP en el path hasta OPNsense.
MTU = 1420

# PostUp/PreDown:
#  - FORWARD ACCEPT para wg0 (necesario para que el WG actue como router VPC<->on-prem)
#  - MASQUERADE en \$ETH solo para destinos fuera de 10.0.0.0/8 (NAT a internet legacy)
#  - SNAT del trafico GLPI->wg0 a 10.8.0.2: evita que las IPs dinamicas del ASG GLPI
#    aparezcan en on-prem; el firewall del DC y los AllowedIPs de OPNsense solo
#    tienen que aceptar 10.8.0.0/24, no toda la VPC. CRITICO: solo SNAT a las
#    subnets privadas del ASG (10.0.2.0/24, 10.0.4.0/24). NO incluir 10.0.0.0/16
#    porque romperia las respuestas del nginx (10.0.1.20) a pings desde on-prem
#    (el on-prem espera respuesta de 10.0.1.20, no de 10.8.0.2).
#  - MSS clamping en FORWARD wg0: ajusta el MSS de los SYN al PMTU real del tunnel,
#    evitando que sesiones TCP iniciadas desde la VPC se queden colgadas al primer
#    paquete grande (sintoma: nc -zw5 timeouts intermitentes).
PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; \
           iptables -A FORWARD -o wg0 -j ACCEPT; \
           iptables -t nat -A POSTROUTING -o $ETH ! -d 10.0.0.0/8 -j MASQUERADE; \
           iptables -t nat -A POSTROUTING -o wg0 -s 10.0.2.0/24 -j MASQUERADE; \
           iptables -t nat -A POSTROUTING -o wg0 -s 10.0.4.0/24 -j MASQUERADE; \
           iptables -t mangle -A FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu; \
           iptables -t mangle -A FORWARD -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
PreDown  = iptables -D FORWARD -i wg0 -j ACCEPT; \
           iptables -D FORWARD -o wg0 -j ACCEPT; \
           iptables -t nat -D POSTROUTING -o $ETH ! -d 10.0.0.0/8 -j MASQUERADE; \
           iptables -t nat -D POSTROUTING -o wg0 -s 10.0.2.0/24 -j MASQUERADE; \
           iptables -t nat -D POSTROUTING -o wg0 -s 10.0.4.0/24 -j MASQUERADE; \
           iptables -t mangle -D FORWARD -o wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu; \
           iptables -t mangle -D FORWARD -i wg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

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
