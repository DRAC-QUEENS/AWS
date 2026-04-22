# EC2 Instances y Elastic IPs (EIPs)
# ==================================
# Define las máquinas virtuales y sus direcciones IP públicas persistentes

# ============================================================================
# WIREGUARD: VPN Gateway
# ============================================================================
# Servidor VPN que permite acceso seguro remoto a la infraestructura
# Funcionamiento:
#   1. Clientes VPN extermos se conectan a puerto 51820/UDP
#   2. WireGuard asigna IPs virtuales (10.8.0.x/24)
#   3. Tráfico entre clientes y VPC se encripta
#
# source_dest_check = false: Permite que actúe como túnel para otros clientes
#   (por defecto AWS rechaza paquetes donde src/dst IP ≠ la instancia)

resource "aws_instance" "wireguard" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = aws_subnet.public.id            # En subnet pública para acceso Internet
  vpc_security_group_ids      = [aws_security_group.wireguard_sg.id]
  private_ip                  = "10.0.1.10"                     # IP fija dentro VPC
  associate_public_ip_address = true                            # AWS asigna IP pública nat (reemplazada por EIP)
  source_dest_check           = false                           # Necesario para VPN gateway
  user_data                   = file("${path.module}/user_data/wireguard.sh")  # Script de setup

  tags = merge(local.tags, {
    Name = "ec2-wireguard-dracs"
  })
}

# Elastic IP para WireGuard
# ==========================
# IP pública PERSISTENTE y RESERVADA para WireGuard
# Beneficios:
#   - Misma IP ante reinicios (importante para DNS dinámico)
#   - No cobrada si está asociada a una instancia
#   - Puedes cambiar de instancia sin cambiar la IP pública en clientes VPN
# Asociación: Se vincula a la instancia usando aws_eip_association

resource "aws_eip" "wireguard_eip" {
  domain = "vpc"

  tags = merge(local.tags, {
    Name = "eip-wireguard-dracs"
  })

  # Espera a que el IGW exista antes de crear EIP
  # Previene race conditions en Terraform apply
  depends_on = [aws_internet_gateway.igw]
}

# Asociación de EIP a WireGuard
# =============================
# Vincula la EIP a la instancia WireGuard
# Separar creación (EIP) de asociación permite:
#   - Detach/reattach sin perder la EIP
#   - Reutilizar EIPs entre instancias sin destruir
#   - Cambios menos destructivos en updates

resource "aws_eip_association" "wireguard_eip_assoc" {
  instance_id   = aws_instance.wireguard.id
  allocation_id = aws_eip.wireguard_eip.id
}

# ============================================================================
# NGINX: Reverse Proxy / Load Balancer
# ============================================================================
# Servidor proxy inverso que:
#   1. Recibe tráfico HTTP/HTTPS de usuarios
#   2. Proxying a GLPI en subnet privada (10.0.2.10)
#   3. Aísla GLPI de internet (solo acceso vía proxy)
#   4. Puede implementar:
#      - Rate limiting / DDoS protection
#      - WAF (Web Application Firewall)
#      - SSL/TLS termination
#      - Compression, caching, etc.

resource "aws_instance" "nginx" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = aws_subnet.public.id             # En subnet pública para acceso Internet
  vpc_security_group_ids      = [aws_security_group.nginx_sg.id]
  private_ip                  = "10.0.1.20"                      # IP fija dentro VPC
  associate_public_ip_address = false                            # NO asignar IP pública nat (usamos EIP)
  user_data                   = file("${path.module}/user_data/nginx.sh")  # Script de setup

  tags = merge(local.tags, {
    Name = "ec2-nginx-dracs"
  })
}

# Elastic IP para Nginx
# ======================
# IP pública PERSISTENTE para Nginx
# Importante para:
#   - DNS: Registrar CNAME/A record de dominio a esta EIP
#   - Certificados SSL: El DNS debe resolver a esta IP
#   - Clientes: Siempre llegan al mismo endpoint aunque Nginx reinicie

resource "aws_eip" "nginx_eip" {
  domain = "vpc"

  tags = merge(local.tags, {
    Name = "eip-nginx-dracs"
  })

  depends_on = [aws_internet_gateway.igw]
}

# Asociación de EIP a Nginx
# ==========================
# Vincula la EIP a la instancia Nginx

resource "aws_eip_association" "nginx_eip_assoc" {
  instance_id   = aws_instance.nginx.id
  allocation_id = aws_eip.nginx_eip.id
}

# ============================================================================
# GLPI: Application Server (Inventory Management)
# ============================================================================
# Sistema de gestión de inventario de TI
# Características de seguridad:
#   - Reside en subnet PRIVADA (sin acceso directo a internet)
#   - Acceso HTTP/HTTPS solo desde Nginx (proxy filtering)
#   - Acceso SSH desde cualquier IP (⚠️ TODO: restringir a VPN)
#   - Outbound internet mediante NAT Gateway (updates, webhooks, etc.)
#
# Datos críticos: BD GLPI contiene info sensible
#   → Implementar snapshots EBS, backups automáticos, encriptación

resource "aws_instance" "glpi" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = aws_subnet.private.id                # Subnet PRIVADA (importante!)
  vpc_security_group_ids = [aws_security_group.glpi_sg.id]
  private_ip             = "10.0.2.10"                          # IP fija dentro VPC
  user_data              = file("${path.module}/user_data/glpi.sh")  # Script de setup

  tags = merge(local.tags, {
    Name = "ec2-glpi-dracs"
  })

  # GLPI no tiene EIP: No requiere acceso internet directo
  # Conexiones salientes van via NAT Gateway (IP pública dinámica del NAT)
}

# ============================================================================
# VENTAJA DE ARQUITECTURA:
# ============================================================================
# Internet → EIP Nginx → Nginx (proxy) → GLPI privada
#                                           ↑
#                                    No expuesta a internet
#
# Esta arquitectura:
#   ✅ Aísla datos sensibles (GLPI)
#   ✅ Control de acceso en proxy (validación, autenticación, etc.)
#   ✅ Si GLPI comprometida, atacante no accede directo internet
#   ✅ Escalable: Reemplazar GLPI sin cambiar EIP/DNS de usuarios