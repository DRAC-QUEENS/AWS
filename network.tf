# ---------- DATA SOURCES ----------

data "aws_availability_zones" "azs" {}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

# ---------- VPC ----------

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  tags                 = { Name = "vpc-dracs" }
}

# ---------- SUBNETS ----------

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.azs.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "subnet-publica-a-dracs" }
}

resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.3.0/24"
  availability_zone       = data.aws_availability_zones.azs.names[1]
  map_public_ip_on_launch = true
  tags                    = { Name = "subnet-publica-b-dracs" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = data.aws_availability_zones.azs.names[0]
  tags              = { Name = "subnet-privada-a-dracs" }
}

resource "aws_subnet" "private_b" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.4.0/24"
  availability_zone = data.aws_availability_zones.azs.names[1]
  tags              = { Name = "subnet-privada-b-dracs" }
}

# ---------- INTERNET GATEWAY ----------

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "igw-dracs" }
}

# ---------- NAT GATEWAY ----------

resource "aws_eip" "nat" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.igw]
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags          = { Name = "nat-dracs" }
  depends_on    = [aws_internet_gateway.igw]
}

# ---------- ROUTE TABLES ----------

resource "aws_route_table" "publica" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "rt-publica-dracs" }

  # IMPORTANTE: ignoramos cambios en `route` porque las rutas hacia
  # las redes on-prem se gestionan con recursos `aws_route` separados
  # (`aws_route.onprem_public`). Sin este `ignore_changes`, en cada apply
  # `aws_route_table` veria las rutas on-prem como drift y las borraria
  # (anti-patron documentado de Terraform AWS provider).
  lifecycle {
    ignore_changes = [route]
  }
}

resource "aws_route_table" "privada" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "rt-privada-dracs" }

  # Mismo motivo que en `publica`: las rutas on-prem (`aws_route.onprem_private`)
  # se gestionan por separado y no deben ser tratadas como drift.
  lifecycle {
    ignore_changes = [route]
  }
}

# ---------- ROUTE TABLE ASSOCIATIONS ----------

resource "aws_route_table_association" "publica" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.publica.id
}

resource "aws_route_table_association" "publica_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.publica.id
}

resource "aws_route_table_association" "privada" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.privada.id
}

# private_b comparte NAT Gateway con private_a (mismo AZ cost vs. resiliencia)
resource "aws_route_table_association" "privada_b" {
  subnet_id      = aws_subnet.private_b.id
  route_table_id = aws_route_table.privada.id
}

# ---------- ROUTES A REDES ON-PREM (via WireGuard) ----------
# Las rutas se generan por for_each para cada CIDR on-prem en ambas RTs.

locals {
  onprem_cidrs = ["192.168.1.0/24", "192.168.10.0/24", "192.168.20.0/24"]
}

resource "aws_route" "onprem_public" {
  for_each               = toset(local.onprem_cidrs)
  route_table_id         = aws_route_table.publica.id
  destination_cidr_block = each.value
  network_interface_id   = aws_instance.wireguard.primary_network_interface_id
}

resource "aws_route" "onprem_private" {
  for_each               = toset(local.onprem_cidrs)
  route_table_id         = aws_route_table.privada.id
  destination_cidr_block = each.value
  network_interface_id   = aws_instance.wireguard.primary_network_interface_id
}
