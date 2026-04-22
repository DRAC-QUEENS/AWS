# Security Groups: Firewalls de instancias
# =========================================
# Controlan tráfico inbound/outbound a nivel de instancia
# Los security groups se pueden referenciar entre sí para segmentación

# WireGuard Security Group
# ========================
# Permite:
#   - Tráfico VPN (51820/UDP) desde internet
#   - SSH (22/TCP) desde cualquier IP (⚠️ abierto en desarrollo)
#   - TODO: SSH restringir a bastion o VPN en producción
#   - TODO: Implementar fail2ban o rate limiting

resource "aws_security_group" "wireguard_sg" {
  name        = "wireguard-dracs"
  description = "Acceso a WireGuard y SSH"
  vpc_id      = aws_vpc.main.id

  # Inbound: WireGuard VPN
  # ===== =================
  # Puerto 51820/UDP es estándar WireGuard
  # Acepta desde cualquier IP (0.0.0.0/0) para permitir conexiones globales
  ingress {
    description = "WireGuard VPN"
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Inbound: SSH
  # ============
  # Puerto 22/TCP para administración remota
  # Abierto desde 0.0.0.0/0 para flexibilidad en desarrollo
  #
  # ⚠️ SEGURIDAD: En producción, restringir a:
  #    - IPs específicas (office, bastion, etc.)
  #    - Security group de bastion host
  #    - AWS Systems Manager Session Manager (sin SSH)
  ingress {
    description = "SSH abierto"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Outbound: Todo
  # ==============
  # Permite cualquier tráfico saliente (WireGuard necesita resolver DNS, etc.)
  # Protección: Las instancias NO pueden iniciar conexiones entrantes por esto
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"          # -1 = todos los protocolos
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "sg-wireguard-dracs"
  })
}

# Nginx Security Group
# ====================
# Permite:
#   - HTTP (80/TCP) desde internet
#   - HTTPS (443/TCP) desde internet
#   - SSH (22/TCP) desde cualquier IP (⚠️ abierto en desarrollo)
# Bloquea:
#   - Todo lo demás inbound
#   - Backend GLPI no debe ser accesible directamente (proxy solo)

resource "aws_security_group" "nginx_sg" {
  name        = "nginx-dracs"
  description = "Acceso HTTP/HTTPS y SSH a Nginx"
  vpc_id      = aws_vpc.main.id

  # Inbound: HTTP
  # =============
  # Puerto 80/TCP, accesible desde cualquier IP
  # Nginx redirige a HTTPS en producción
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Inbound: HTTPS
  # ==============
  # Puerto 443/TCP, accesible desde cualquier IP
  # Comunicación encriptada TLS
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Inbound: SSH
  # ============
  # Puerto 22/TCP para administración
  # Abierto desde 0.0.0.0/0 en desarrollo
  ingress {
    description = "SSH abierto"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Outbound: Todo
  # ==============
  # Permite Nginx conectarse a GLPI backend (10.0.2.10)
  # Y resolver DNS, actualizar paquetes, etc.
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "sg-nginx-dracs"
  })
}

# GLPI Security Group
# ===================
# Permisiva en entrada PERO:
#   - HTTP/HTTPS solo desde Nginx (10.0.1.20)
#   - Todo desde VPN (10.8.0.0/24 es rango WireGuard default)
#   - SSH abierto (⚠️ TODO: restringir a VPN)
#
# Aislamiento: GLPI no se expone directamente a internet
#   - Sin IPs públicas
#   - Solo accesible via Nginx proxy o VPN tunnel

resource "aws_security_group" "glpi_sg" {
  name        = "glpi-dracs"
  description = "Acceso a GLPI desde Nginx y VPN"
  vpc_id      = aws_vpc.main.id

  # Inbound: HTTP desde Nginx
  # ==========================
  # Puerto 80/TCP, SOLO de Nginx (sg-nginx)
  # Usa SG referencing: si Nginx SG cambia, esto se actualiza automáticamente
  ingress {
    description     = "HTTP desde Nginx"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.nginx_sg.id]
  }

  # Inbound: HTTPS desde Nginx
  # ===========================
  # Puerto 443/TCP, SOLO de Nginx (sg-nginx)
  ingress {
    description     = "HTTPS desde Nginx"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.nginx_sg.id]
  }

  # Inbound: Todo desde VPN
  # =======================
  # CIDR 10.8.0.0/24 es rango de clientes WireGuard (configurable)
  # Permite:
  #   - Acceso administrativo directo vía SSH desde clientes VPN
  #   - Debugging sin pasar por proxy
  #   - Acceso BD local, APIs internas, etc.
  ingress {
    description = "Acceso desde VPN"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"          # Todos los protocolos
    cidr_blocks = ["10.8.0.0/24"]  # Rango de clientes WireGuard
  }

  # Inbound: SSH
  # ============
  # Puerto 22/TCP desde 0.0.0.0/0
  # ⚠️ TODO: Cambiar a solo desde VPN (10.8.0.0/24)
  #     Temporal mientras se configura VPN activa
  ingress {
    description = "SSH abierto temporal"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Outbound: Todo
  # ==============
  # Permite GLPI:
  #   - Resolver DNS (53/UDP, 53/TCP)
  #   - Conectar servicios externos (APIs, webhooks)
  #   - Descargar updates de paquetes
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "sg-glpi-dracs"
  })
}