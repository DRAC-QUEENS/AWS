# AWS DRACS Hybrid Infrastructure

Infraestructura de AWS para el proyecto DRACS Hybrid, con arquitectura segmentada de red privada/pública, VPN mediante WireGuard, proxy inverso con Nginx y gestor de inventario GLPI.

## 🏗️ Arquitectura

```
┌─────────────────────────────────────────────────────────────┐
│                      AWS VPC (10.0.0.0/16)                  │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌──────────────────────┐         ┌─────────────────────┐   │
│  │  PUBLIC SUBNET       │         │  PRIVATE SUBNET     │   │
│  │  (10.0.1.0/24)       │         │  (10.0.2.0/24)      │   │
│  │                      │         │                     │   │
│  │  ┌────────────────┐  │         │  ┌───────────────┐  │   │
│  │  │   WireGuard    │  │         │  │     GLPI      │  │   │
│  │  │ EC2 (VPN Gate) │  │         │  │   EC2 (BD)    │  │   │
│  │  │ 10.0.1.10      │  │         │  │  10.0.2.10    │  │   │
│  │  │ EIP: Dynamic   │  │         │  │ (Private)     │  │   │
│  │  │ Port: 51820/UDP│  │         │  │               │  │   │
│  │  └────────────────┘  │         │  └───────────────┘  │   │
│  │                      │         │                     │   │
│  │  ┌────────────────┐  │         │                     │   │
│  │  │    Nginx       │  │         │                     │   │
│  │  │  EC2 (Proxy)   │  │         │                     │   │
│  │  │ 10.0.1.20      │  │         │                     │   │
│  │  │ EIP: Dynamic   │  │         │                     │   │
│  │  │ Ports: 80/443  │  │         │                     │   │
│  │  └────────────────┘  │         │                     │   │
│  │      │                │         │                     │   │
│  │      └────────────────────────→│ (proxy_pass)        │   │
│  └──────────────────────┘         └─────────────────────┘   │
│           │                               │                  │
│      NAT ↕ Gateway                       │                  │
│    (0.0.0.0 outbound)                    │                  │
│           │                               │                  │
│  Internet Gateway (0.0.0.0 inbound)      │                  │
└─────────────────────────────────────────────────────────────┘
         │                             │
    Entrada pública             Acceso privado
   (WG + Nginx)                (VPN o Nginx)
```

## 📋 Componentes

### **WireGuard (VPN Gateway)**
- **Descripción**: Servidor VPN para acceso seguro remoto a la infraestructura
- **Tipo**: EC2 t3.micro (Ubuntu 24.04 LTS)
- **Red**: Subnet pública, IP privada fija (10.0.1.10)
- **IP Elástica**: Sí (persistente entre reinicios)
- **Puertos**: 51820/UDP (VPN)
- **SSH**: Abierto desde cualquier IP (⚠️ considerar restringir en producción)
- **Tunelización**: Desactiva source check para permitir tráfico de otros clientes
- **Rol**: Único punto de entrada para tráfico remoto seguro

### **Nginx (Reverse Proxy)**
- **Descripción**: Proxy inverso y balanceador de carga para aplicaciones
- **Tipo**: EC2 t3.micro (Ubuntu 24.04 LTS)
- **Red**: Subnet pública, IP privada fija (10.0.1.20)
- **IP Elástica**: Sí (para DNS/CNAME estables)
- **Puertos**: 80/TCP (HTTP), 443/TCP (HTTPS)
- **Backend**: GLPI en subnet privada (10.0.2.10)
- **SSH**: Abierto desde cualquier IP
- **Función**: Expone GLPI de forma segura hacia internet/usuarios autenticados

### **GLPI (Inventory Management)**
- **Descripción**: Sistema de gestión de inventario de TI
- **Tipo**: EC2 t3.micro (Ubuntu 24.04 LTS)
- **Red**: Subnet privada, IP privada fija (10.0.2.10)
- **IP Pública**: No (acceso solo a través de NAT Gateway o Nginx)
- **Acceso HTTP/HTTPS**: Solo desde Nginx (10.0.1.20)
- **Acceso SSH**: Open (considerar restringir a VPN en producción)
- **Almacenamiento**: EBS gp3 (raíz)
- **Rol**: Aplicación crítica, datos no deben ser accesibles directamente

## 🔒 Seguridad

### Security Groups

#### **wireguard-dracs**
```
Inbound:
  ✅ 51820/UDP   → 0.0.0.0/0     (WireGuard VPN)
  ✅ 22/TCP      → 0.0.0.0/0     (SSH)
Outbound:
  ✅ Todo (-)
```

#### **nginx-dracs**
```
Inbound:
  ✅ 80/TCP      → 0.0.0.0/0     (HTTP)
  ✅ 443/TCP     → 0.0.0.0/0     (HTTPS)
  ✅ 22/TCP      → 0.0.0.0/0     (SSH)
Outbound:
  ✅ Todo (-)
```

#### **glpi-dracs**
```
Inbound:
  ✅ 80/TCP      → sg-nginx      (HTTP desde Nginx)
  ✅ 443/TCP     → sg-nginx      (HTTPS desde Nginx)
  ✅ 0-65535     → 10.8.0.0/24   (Todo desde VPN WireGuard)
  ✅ 22/TCP      → 0.0.0.0/0     (SSH - abierto)
Outbound:
  ✅ Todo (-)
```

### Network Segmentation

- **Public Subnet (10.0.1.0/24)**: WireGuard + Nginx (acceso internet directo)
- **Private Subnet (10.0.2.0/24)**: GLPI (outbound solo por NAT Gateway)
- **NAT Gateway**: Punto único de egreso para subnet privada

## 🪧 Elastic IPs (EIPs)

| Recurso | EIP | Uso |
|---------|-----|-----|
| WireGuard | ✅ Dynamic (generada) | Acceso VPN estable desde internet |
| Nginx | ✅ Dynamic (generada) | Acceso HTTP/HTTPS estable |
| NAT Gateway | ✅ Dynamic (generada) | Outbound IP fija para subnet privada |

**Importante**: Las EIPs evitan cambios de dirección pública ante reinicios. Para producción, considera registrar las EIPs en Route53 o DNS corporativo.

## 🚀 Despliegue

### Requisitos previos
- AWS Account activa con credenciales configuradas
- Terraform >= 1.5.0
- Key pair EC2 creado (por defecto: `dracs-keypair`)
- AWS CLI configurado (opcional pero recomendado)

### Variables disponibles

```bash
# Región AWS (default: us-east-1)
aws_region = "us-east-1"

# Tipo de instancia (default: t3.micro - libre en laboratorio)
instance_type = "t3.micro"

# Key pair para SSH (default: dracs-keypair)
key_name = "dracs-keypair"

# Nombre del proyecto (default: dracs-hybrid)
project_name = "dracs-hybrid"
```

### Pasos de despliegue

```bash
# 1. Navegar al directorio
cd /home/jsa5214/AWS

# 2. Inicializar Terraform (descargar providers)
terraform init

# 3. Ver plan de cambios (recomendado antes de apply)
terraform plan

# 4. Aplicar configuración
terraform apply

# 5. Ver outputs con IPs y datos importantes
terraform output
```

## 📤 Outputs

Tras `terraform apply`, obtendrás:

```bash
vpc_id                  → ID de la VPC
public_subnet_id        → ID de subnet pública
private_subnet_id       → ID de subnet privada
wireguard_private_ip    → IP privada de WireGuard (10.0.1.10)
wireguard_eip           → IP Elástica pública de WireGuard
nginx_private_ip        → IP privada de Nginx (10.0.1.20)
nginx_eip               → IP Elástica pública de Nginx
glpi_private_ip         → IP privada de GLPI (10.0.2.10)
```

## 🔧 Configuración Post-Despliegue

### WireGuard
1. SSH a WireGuard: `ssh -i key.pem ubuntu@<wireguard_eip>`
2. Script de setup ejecutado automáticamente: `/home/jsa5214/AWS/user_data/wireguard.sh`
3. Generar configuración de cliente WireGuard
4. Distribuir `.conf` a clientes

### Nginx
1. SSH a Nginx: `ssh -i key.pem ubuntu@<nginx_eip>`
2. Script de setup ejecutado: `/home/jsa5214/AWS/user_data/nginx.sh`
3. Configurar reverse proxy hacia GLPI privado
4. SSL certificates para HTTPS

### GLPI
1. Acceder solo vía SSH desde bastion o VPN
2. Script de setup ejecutado: `/home/jsa5214/AWS/user_data/glpi.sh`
3. Configuración de base de datos
4. Acceso público únicamente a través de Nginx proxy

## ⚠️ Consideraciones Importantes

### Seguridad
- **SSH abierto a 0.0.0.0/0**: Actualmente habilitado para flexibilidad de desarrollo. Considerar restringir a IPs/VPN en producción.
- **GLPI en privada**: Datos seguros, pero VPN recomendada para acceso administrativo directo.
- **Credenciales**: Nunca hardcodear, usar AWS Secrets Manager para credenciales de aplicación.

### Escalabilidad
- **Instancias t3.micro**: Tipos económicos, no recomendados para producción heavy.
- **Zona simple AZ**: Sin alta disponibilidad. Expandir a múltiples AZs si es crítico.
- **Almacenamiento**: Usar EBS snapshots para backup.

### Costos
- **NAT Gateway**: Cargos por hora + transferencia de datos
- **EIPs**: Sin costos si están asociadas a instancias, pero cobran si están libres
- **t3.micro**: Dentro del free tier de AWS (primer año)

## 📊 Monitoreo Recomendado (WIP)

- [ ] VPC Flow Logs (análisis de tráfico)
- [ ] CloudWatch Alarms (alertas de CPU, red)
- [ ] CloudTrail (auditoría de cambios)
- [ ] Route53 Privado (DNS interno)
- [ ] EBS Snapshots automáticos (backup GLPI)

## 📚 Archivos del Proyecto

```
.
├── provider.tf          → Configuración del provider AWS
├── network.tf           → VPC, subnets, NAT Gateway, rutas
├── security.tf          → Security Groups
├── ec2.tf               → Instancias EC2 y EIPs
├── variables.tf         → Variables configurables
├── outputs.tf           → Outputs para consultar post-deploy
├── README.md            → Este archivo
└── user_data/
    ├── wireguard.sh     → Script de configuración WireGuard
    ├── nginx.sh         → Script de configuración Nginx
    └── glpi.sh          → Script de configuración GLPI
```

## 🐛 Troubleshooting

### "No puedo acceder a GLPI desde Nginx"
1. Verificar security group de GLPI permite tráfico desde Nginx SG
2. Comprobar que GLPI está escuchando en puerto correcto
3. Ver logs: `journalctl -u glpi` en GLPI

### "WireGuard no conecta"
1. Verificar puerto 51820/UDP abierto: `sudo iptables -L`
2. Revisar configuración en `/etc/wireguard/`
3. Check firewall AWS en security group

### "Nginx resuelve mal a GLPI"
1. Por ahora IP hardcodeada. Implementar Route53 Privado para DNS interno.
2. Verificar `/etc/nginx/conf.d/` con la IP correcta

## 🎯 Roadmap

- [ ] Backend Terraform remoto (S3 + DynamoDB)
- [ ] Migrar IPs a variables parametrizadas
- [ ] VPC Flow Logs para observabilidad
- [ ] Route53 Privado para DNS interno
- [ ] EBS Snapshots automáticos (GLPI)
- [ ] Multi-AZ para Alta Disponibilidad
- [ ] CloudWatch Monitoring y Alarms
- [ ] IAM Roles para instancias

## 📞 Soporte

Para preguntas o issues del proyecto, revisar:
- AWS Console → VPC para topology
- CloudTrail para auditoría
- Systems Manager Session Manager para acceso sin SSH

---

**Última actualización**: abril 2026  
**Versión Terraform**: >= 1.5.0  
**AWS Provider**: ~> 6.0