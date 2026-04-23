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
  tags                    = { Name = "subnet-publica-dracs" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = data.aws_availability_zones.azs.names[0]
  tags              = { Name = "subnet-privada-dracs" }
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
}

resource "aws_route_table" "privada" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "rt-privada-dracs" }
}

# ---------- ROUTE TABLE ASSOCIATIONS ----------

resource "aws_route_table_association" "publica" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.publica.id
}

resource "aws_route_table_association" "privada" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.privada.id
}

# ---------- ROUTES A REDES ON-PREM (via WireGuard) ----------

resource "aws_route" "to_onprem_mgmt_public" {
  route_table_id         = aws_route_table.publica.id
  destination_cidr_block = "192.168.1.0/24"
  network_interface_id   = aws_instance.wireguard.primary_network_interface_id
}

resource "aws_route" "to_onprem_servers_public" {
  route_table_id         = aws_route_table.publica.id
  destination_cidr_block = "192.168.10.0/24"
  network_interface_id   = aws_instance.wireguard.primary_network_interface_id
}

resource "aws_route" "to_onprem_clients_public" {
  route_table_id         = aws_route_table.publica.id
  destination_cidr_block = "192.168.20.0/24"
  network_interface_id   = aws_instance.wireguard.primary_network_interface_id
}

resource "aws_route" "to_onprem_mgmt_private" {
  route_table_id         = aws_route_table.privada.id
  destination_cidr_block = "192.168.1.0/24"
  network_interface_id   = aws_instance.wireguard.primary_network_interface_id
}

resource "aws_route" "to_onprem_servers_private" {
  route_table_id         = aws_route_table.privada.id
  destination_cidr_block = "192.168.10.0/24"
  network_interface_id   = aws_instance.wireguard.primary_network_interface_id
}

resource "aws_route" "to_onprem_clients_private" {
  route_table_id         = aws_route_table.privada.id
  destination_cidr_block = "192.168.20.0/24"
  network_interface_id   = aws_instance.wireguard.primary_network_interface_id
}
