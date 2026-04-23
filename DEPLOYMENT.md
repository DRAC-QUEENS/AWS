# Despliegue Hybrid AWS + Proxmox DRACS

## Estado actual (2026-04-23)

### AWS Infrastructure
Desplegada con Terraform simplificado (5 archivos modulares).

#### Instancias EC2
| Nombre | Tipo | Subnet | IP Privada | EIP | Estado |
|--------|------|--------|-----------|-----|--------|
| WireGuard | t3.micro | Pública | 10.0.1.10 | 13.219.172.135 | ✓ Running |
| Nginx | t3.micro | Pública | 10.0.1.20 | 35.170.101.153 | ✓ Running |
| GLPI | t3.small | Privada | 10.0.2.10 | — | ✓ Running |

#### Configuración de red
- **VPC**: 10.0.0.0/16
- **Subnets**: 
  - Pública: 10.0.1.0/24 (IGW, público)
  - Privada: 10.0.2.0/24 (NAT, solo salida)
- **Rutas on-prem** (vía WireGuard instance):
  - 192.168.1.0/24 (Proxmox management)
  - 192.168.10.0/24 (VLAN 10 - servidores)
  - 192.168.20.0/24 (VLAN 20 - clientes)

### On-Prem (Proxmox Cluster "Dracs")
- **Nodo1**: VM 100 OPNsense (firewall), VM 101 WinServer2022
- **Nodo2**: VM 201 Linux-Wazuh (192.168.10.30), VM 202 Ansible-Linux
- **Nodo3**: VM 300 Win11-Cliente, LXC 301 Zabbix-Linux (192.168.10.20), VM 302 PBS

### Conectividad Híbrida
**WireGuard VPN** (site-to-site):
- **AWS side**: 10.8.0.2/24 en instancia WireGuard (13.219.172.135:51820)
- **On-prem side**: 10.8.0.1/32 en OPNsense (configurado ✓)
- **Pre-shared key**: f/ugcMua6IJzQkhLynGnIJSuCSbKZIRDNDyp6QH6JU8=
- **AWS public key**: y8LCqXLHCqqGG38Oon4JN4xS/OtcHLS9Un7OS8E7y0Q=
- **OPNsense public key**: IakGqi12LzA3dlAwRGGjBm5OVaGCFdwdaucrAHb6K2Y=

## Próximos pasos

### 1. Verificar túnel WireGuard
```bash
ssh -i ~/.ssh/dracs-keypair.pem ubuntu@13.219.172.135
# En la instancia:
wg show wg0
ip addr show wg0
ping 192.168.10.20  # Zabbix
ping 192.168.10.30  # Wazuh
```

### 2. Verificar instalación de Agentes (3-5 min después de boot)
- **AWS instances**: Zabbix Agent 2 + Wazuh Agent (installed vía user_data)
- **On-prem VMs**: Pendiente → Instalar vía Ansible

### 3. Monitorización
- Zabbix server: 192.168.10.20 (LXC 301)
- Wazuh manager: 192.168.10.30 (VM 201)

### 4. Aplicación GLPI
- **Nginx proxy**: 35.170.101.153:443 → 10.0.2.10:80
- **Credenciales GLPI**: admin/Password1 (default, cambiar en producción)
- **Base de datos**: MariaDB local en GLPI instance

## Notas
- NAT Gateway cuesta ~$32/mes (actualmente activo para GLPI outbound)
- EBS encryption habilitado en todas las instancias
- SSH restringido a túnel VPN (10.8.0.0/24) excepto WireGuard (endpoint)
- GLPI usa SSL autofirmado (sin HTTPS válido)
