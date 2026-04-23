#!/bin/bash
set -e

AWS_PRIVATE_KEY="CCkfF3+aY3x9izEv5ixQYUg+GaNsAX3fBl6IvJNHaVI="
OPNSENSE_PUBLIC_KEY="IakGqi12LzA3dlAwRGGjBm5OVaGCFdwdaucrAHb6K2Y="
WG_PRESHARED_KEY="f/ugcMua6IJzQkhLynGnIJSuCSbKZIRDNDyp6QH6JU8="
OPNSENSE_ALLOWED_IPS="10.8.0.1/32,192.168.1.0/24,192.168.10.0/24,192.168.20.0/24"
WAN_IF="eth0"
WAZUH_MANAGER="192.168.10.30"
ZABBIX_SERVER="192.168.10.20"

apt-get update -y > /dev/null 2>&1
apt-get install -y wireguard wireguard-tools iptables-persistent curl wget gpg > /dev/null 2>&1

# ── WireGuard ─────────────────────────────────────────────────────────────────
sysctl -w net.ipv4.ip_forward=1 > /dev/null
grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -p > /dev/null 2>&1

mkdir -p /etc/wireguard/
chmod 700 /etc/wireguard/
printf '%s\n' "$AWS_PRIVATE_KEY" > /etc/wireguard/privatekey
chmod 600 /etc/wireguard/privatekey
PUBLIC_KEY=$(printf '%s' "$AWS_PRIVATE_KEY" | wg pubkey)
printf '%s\n' "$PUBLIC_KEY" > /etc/wireguard/publickey

cat > /etc/wireguard/wg0.conf << WGCONFIG
[Interface]
Address = 10.8.0.2/24
ListenPort = 51820
PrivateKey = ${AWS_PRIVATE_KEY}

PostUp   = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -A FORWARD -o wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o ${WAN_IF} -j MASQUERADE
PreDown  = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -D FORWARD -o wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o ${WAN_IF} -j MASQUERADE

[Peer]
PublicKey        = ${OPNSENSE_PUBLIC_KEY}
PreSharedKey     = ${WG_PRESHARED_KEY}
AllowedIPs       = ${OPNSENSE_ALLOWED_IPS}
PersistentKeepalive = 25
WGCONFIG

chmod 600 /etc/wireguard/wg0.conf
wg-quick down wg0 2>/dev/null || true
wg-quick up wg0
systemctl enable wg-quick@wg0.service > /dev/null 2>&1

# ── Zabbix Agent 2 ────────────────────────────────────────────────────────────
wget -q https://repo.zabbix.com/zabbix/7.0/ubuntu/pool/main/z/zabbix-release/zabbix-release_latest+ubuntu24.04_all.deb -O /tmp/zabbix-release.deb
dpkg -i /tmp/zabbix-release.deb > /dev/null 2>&1
apt-get update -y > /dev/null 2>&1
apt-get install -y zabbix-agent2 > /dev/null 2>&1

HOSTNAME=$(hostname)
cat > /etc/zabbix/zabbix_agent2.conf << ZBXCONF
Server=${ZABBIX_SERVER}
ServerActive=${ZABBIX_SERVER}
Hostname=${HOSTNAME}
LogFile=/var/log/zabbix/zabbix_agent2.log
LogFileSize=10
PidFile=/run/zabbix/zabbix_agent2.pid
SocketDir=/run/zabbix
ZBXCONF

systemctl enable zabbix-agent2
systemctl start zabbix-agent2

# ── Wazuh Agent ───────────────────────────────────────────────────────────────
# El agente se registra contra el manager on-prem a través del túnel WireGuard.
# Reintentará la conexión hasta que el túnel esté activo.
curl -s https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg
echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" \
  > /etc/apt/sources.list.d/wazuh.list
apt-get update -y > /dev/null 2>&1
WAZUH_MANAGER="${WAZUH_MANAGER}" apt-get install -y wazuh-agent > /dev/null 2>&1

sed -i "s|<address>.*</address>|<address>${WAZUH_MANAGER}</address>|" /var/ossec/etc/ossec.conf
sed -i "s|<protocol>.*</protocol>|<protocol>tcp</protocol>|" /var/ossec/etc/ossec.conf

systemctl daemon-reload
systemctl enable wazuh-agent
systemctl start wazuh-agent
