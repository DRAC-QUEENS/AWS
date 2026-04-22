# Data Sources: Recuperan información dinámica de AWS
# ===================================================

# Obtiene todas las Availability Zones disponibles en la región
# Se usa para seleccionar una AZ específica (la primera: local.az)
data "aws_availability_zones" "available" {}

# Busca la última AMI de Ubuntu 24.04 LTS (Noble) publicada por Canonical
# Propietario: 099720109477 es el ID de cuenta de Canonical (proveedor oficial)
# Garantiza que siempre tengas la versión más reciente de Ubuntu
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical official account

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"] # Hardware Virtual Machine (requiere virtualization CPU features)
  }
}

# Local Values: Calcula valores que se usan múltiples veces
# =========================================================

locals {
  # Tags comunes aplicados a todos los recursos (merge con tags específicos)
  # Facilita identificación, billing chargeback, compliance audits
  tags = {
    Project = var.project_name
  }

  # Primera availability zone disponible (para instancias en una AZ única)
  # TODO: Para HA, distribuir instancias entre múltiples AZs
  az = data.aws_availability_zones.available.names[0]
}

# VPC: Virtual Private Cloud
# ============================
# Aislamiento de red privada. Todos los recursos reside aquí.
#
# CIDR 10.0.0.0/16 ofrece 65,536 direcciones IP (suficiente para lab)
# Segmentado en dos subnets:
#   - Public (10.0.1.0/24):  WireGuard + Nginx (acceso internet)
#   - Private (10.0.2.0/24): GLPI (sin acceso directo internet)

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true      # Resuelve nombres internos (ej: ec2-XX-XX-XX-XX.compute-1.amazonaws.com)
  enable_dns_hostnames = true      # Asigna hostnames DNS a instancias

  tags = merge(local.tags, {
    Name = "vpc-dracs"
  })
}

# Internet Gateway (IGW)
# ======================
# Punto de conexión a internet para la VPC
# Permite tráfico bidireccional entre instancias públicas e internet
# Requisito: Route table must route 0.0.0.0/0 → igw

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.tags, {
    Name = "igw-dracs"
  })
}

# Public Subnet (10.0.1.0/24)
# ============================
# Contiene instancias con acceso directo a internet
# - WireGuard (VPN server) - IP privada 10.0.1.10
# - Nginx (proxy inverso) - IP privada 10.0.1.20
#
# map_public_ip_on_launch = true: Asigna IP pública automáticamente a new instances
# (aunque usamos EIPs explícitas, para flexibilidad)

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"      # 256 IPs (2-254 usables)
  availability_zone       = local.az
  map_public_ip_on_launch = true               # Instancias obtienen IP pública

  tags = merge(local.tags, {
    Name = "subnet-public-dracs"
    Tier = "public"
  })
}

# Private Subnet (10.0.2.0/24)
# =============================
# Contiene instancias SIN acceso directo a internet
# - GLPI (application server + DB) - IP privada 10.0.2.10
#
# Outbound internet accede mediante NAT Gateway (no recibe tráfico inbound)
# Máxima seguridad: No es expuesta directamente a internet

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"     # 256 IPs (2-254 usables)
  availability_zone = local.az
  # map_public_ip_on_launch = false (implicit default)

  tags = merge(local.tags, {
    Name = "subnet-private-dracs"
    Tier = "private"
  })
}

# Elastic IP para NAT Gateway
# ============================
# EIP necesaria para NAT Gateway (static outbound IP)
# Instancias privadas usan esta IP para conexiones salientes:
#   GLPI → updates.ubuntu.com: Originada de esta EIP en IGW
#
# Sin NAT: GLPI no tendría ruta para internet (ruta privada → nowhere)
# Con NAT: GLPI puede descargar updates, conectar servicios cloud, etc.

resource "aws_eip" "nat_eip" {
  domain = "vpc"  # VPC elastic IPs (vs EC2-Classic deprecated)

  tags = merge(local.tags, {
    Name = "nat-eip-dracs"
  })

  # depends_on implícito en aws_nat_gateway, pero explícito es buena práctica
}

# NAT Gateway
# ===========
# Traduce tráfico de subnet privada hacia internet
#
# Flujo:
#   GLPI (10.0.2.10) → NAT Gateway (10.0.1.X) → IGW → Internet
#
# Response:
#   Internet → IGW → NAT Gateway → GLPI
#
# Ventaja: GLPI parece venir de NAT IP pública, no expone IP privada
# Costo: ~$32/mes (por hora) + transferencia datos
# Alternativa: NAT instance (más barato pero menos resiliente)

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public.id  # NAT debe estar en subnet pública

  tags = merge(local.tags, {
    Name = "nat-dracs"
  })

  # Espera a que IGW esté creado (dependencia explícita)
  # Previene race conditions en Terraform apply
  depends_on = [aws_internet_gateway.igw]
}

# Public Route Table
# ==================
# Define cómo enruta tráfico dentro/fuera de public subnet
#
# Ruta: 0.0.0.0/0 (todo tráfico destino desconocido) → IGW
#   "Si no sé dónde va, mándalo a internet"
#
# Resultado: Public subnet tiene acceso internet directo ✅

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"      # Cualquier destino no coincida otra ruta
    gateway_id = aws_internet_gateway.igw.id  # Envía a IGW
  }

  tags = merge(local.tags, {
    Name = "rt-public-dracs"
  })
}

# Route Table Association: Public
# ================================
# Asocia public route table a public subnet
# Sin esto, la ruta table existe pero no aplica a ningún subnet

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public_rt.id
}

# Private Route Table
# ===================
# Define cómo enruta tráfico dentro/fuera de private subnet
#
# Ruta: 0.0.0.0/0 (todo tráfico destino desconocido) → NAT Gateway
#   "Si no sé dónde va, mándalo por NAT (que sí tiene acceso internet)"
#
# Resultado: Private subnet tiene acceso internet indirecto (outbound solo) ✅

resource "aws_route_table" "private_rt" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"              # Cualquier destino no coincida otra ruta
    nat_gateway_id = aws_nat_gateway.nat.id   # Envía a NAT Gateway
  }

  tags = merge(local.tags, {
    Name = "rt-private-dracs"
  })
}

# Route Table Association: Private
# =================================
# Asocia private route table a private subnet
# Sin esto, la ruta table existe pero no aplica a ningún subnet

resource "aws_route_table_association" "private_assoc" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private_rt.id
}