# WireGuard Boot Status

## ⏱️ Timeline

```
17:37:00  - Terraform apply completado
17:37:30  - Instancia EC2 comienza boot
17:38:00  - SSH disponible (Python, apt, etc. instalándose)
17:38:15  - Cloud-init ejecutando user_data/wireguard.sh
17:48:13  - WireGuard aún inicializando...
```

## 📝 Fases del user_data script

El archivo `user_data/wireguard.sh` ejecuta en orden:

```bash
1️⃣  apt-get update               (~10 sec)
2️⃣  apt-get install wireguard    (~30 sec)
3️⃣  Crear config /etc/wireguard  (~5 sec)
4️⃣  wg-quick up wg0              (~5 sec) ← AQUÍ ESTAMOS
5️⃣  systemctl enable             (~2 sec)
6️⃣  Instalar Zabbix Agent        (~15 sec)
7️⃣  Instalar Wazuh Agent         (~20 sec)
```

**ETA Total:** ~2 minutos

## 🔧 Verificación manual

Una vez que `wg-quick up wg0` complete:

```bash
# Interfaz activa
ip addr show wg0
# inet 10.8.0.2/24 scope global wg0

# Estado peer
wg show wg0
# peer: IakGqi12LzA3dlAwRGGjBm5OVaGCFdwdaucrAHb6K2Y=
# endpoint: [OPNsense IP]:51820
# latest handshake: XXXX

# Rutas
ip route | grep 192.168
# 192.168.1.0/24 via 10.0.1.10 dev eth0
# 192.168.10.0/24 via 10.0.1.10 dev eth0
# 192.168.20.0/24 via 10.0.1.10 dev eth0

# Ping test
ping 192.168.10.20  # Zabbix
ping 192.168.1.11   # Proxmox nodo1
```

## ⚠️ Si algo falla

```bash
# Ver logs
journalctl -u wg-quick@wg0 -f
tail -100 /var/log/cloud-init-output.log

# Manual retry
wg-quick up wg0

# Revisar config
cat /etc/wireguard/wg0.conf
```

## 🔑 Keys en uso

```
AWS Private Key:     CCkfF3+aY3x9izEv5ixQYUg+GaNsAX3fBl6IvJNHaVI=
AWS Public Key:      y8LCqXLHCqqGG38Oon4JN4xS/OtcHLS9Un7OS8E7y0Q=

OPNsense Public Key: IakGqi12LzA3dlAwRGGjBm5OVaGCFdwdaucrAHb6K2Y=
PSK:                 f/ugcMua6IJzQkhLynGnIJSuCSbKZIRDNDyp6QH6JU8=

Endpoint AWS:        13.219.172.135:51820
Endpoint OPNsense:   192.168.1.X:XXXXX (dinámico)
```

## 📋 Checklist de verificación

- [ ] `wg show wg0` muestra peer con "latest handshake" reciente
- [ ] `ping 192.168.10.20` responde desde AWS
- [ ] OPNsense muestra "UP" en WireGuard tunnel
- [ ] Transfer muestra datos enviados/recibidos

