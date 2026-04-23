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
    description = "SSH abierto temporalmente (desarrollo)"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
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

resource "aws_security_group" "glpi" {
  name   = "glpi-dracs"
  vpc_id = aws_vpc.main.id

  ingress {
    description     = "HTTP desde Nginx"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.nginx.id]
  }
  ingress {
    description = "Acceso desde la VPN y on-prem"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.8.0.0/24", "192.168.10.0/24"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "sg-glpi-dracs" }
}
