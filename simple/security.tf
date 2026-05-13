# ---------- SECURITY GROUPS ----------

resource "aws_security_group" "wireguard" {
  name   = "wireguard-simple-dracs"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "VPN WireGuard desde internet"
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
    description = "Trafico interno VPC (forwarding)"
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
  tags = { Name = "sg-wireguard-simple-dracs" }
}

resource "aws_security_group" "nginx" {
  name   = "nginx-simple-dracs"
  vpc_id = aws_vpc.main.id

  ingress {
    description = "HTTP desde internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTPS desde internet"
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
  tags = { Name = "sg-nginx-simple-dracs" }
}

resource "aws_security_group" "glpi" {
  name   = "glpi-simple-dracs"
  vpc_id = aws_vpc.main.id

  ingress {
    description     = "HTTP solo desde Nginx"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.nginx.id]
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
  tags = { Name = "sg-glpi-simple-dracs" }
}
