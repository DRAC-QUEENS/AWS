# ---------- SECURITY GROUPS ----------

resource "aws_security_group" "wireguard" {
  name   = "wireguard-dracs"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "VPN WireGuard"
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "SSH solo desde el tunel VPN"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.8.0.0/24"]
  }
  ingress {
    description = "Trafico interno VPC (forwarding desde subnets privadas)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/16"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "sg-wireguard-dracs" }
}

resource "aws_security_group" "nginx" {
  name   = "nginx-dracs"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "SSH solo desde el tunel VPN"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.8.0.0/24"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "sg-nginx-dracs" }
}

# ALB: recibe trafico desde internet (NLB incluido) y desde Nginx (trafico WireGuard)
resource "aws_security_group" "alb" {
  name   = "alb-glpi-dracs"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "HTTP desde internet y NLB"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description     = "HTTP desde Nginx (trafico interno via WireGuard)"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.nginx.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "sg-alb-dracs" }
}

# GLPI ASG: solo recibe HTTP desde el ALB (el resto de acceso via VPN)
resource "aws_security_group" "glpi" {
  name   = "glpi-dracs"
  vpc_id = aws_vpc.main.id

  ingress {
    description     = "HTTP desde ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  ingress {
    description = "Acceso admin desde VPN y on-prem"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.8.0.0/24", "192.168.1.0/24", "192.168.10.0/24", "192.168.20.0/24"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "sg-glpi-dracs" }
}

# RDS: solo accesible desde las instancias GLPI del ASG
resource "aws_security_group" "rds" {
  name   = "rds-glpi-dracs"
  vpc_id = aws_vpc.main.id

  ingress {
    description     = "MariaDB desde instancias GLPI"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.glpi.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "sg-rds-dracs" }
}

# EFS: solo accesible desde las instancias GLPI del ASG
resource "aws_security_group" "efs" {
  name   = "efs-glpi-dracs"
  vpc_id = aws_vpc.main.id

  ingress {
    description     = "NFS desde instancias GLPI"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.glpi.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "sg-efs-dracs" }
}
