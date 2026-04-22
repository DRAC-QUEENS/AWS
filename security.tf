resource "aws_security_group" "wireguard_sg" {
  name        = "wireguard-dracs"
  description = "Acceso a WireGuard y SSH"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "WireGuard VPN"
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH abierto"
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

  tags = merge(local.tags, {
    Name = "sg-wireguard-dracs"
  })
}

resource "aws_security_group" "nginx_sg" {
  name        = "nginx-dracs"
  description = "Acceso HTTP/HTTPS y SSH a Nginx"
  vpc_id      = aws_vpc.main.id

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
    description = "SSH abierto"
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

  tags = merge(local.tags, {
    Name = "sg-nginx-dracs"
  })
}

resource "aws_security_group" "glpi_sg" {
  name        = "glpi-dracs"
  description = "Acceso a GLPI desde Nginx y VPN"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "HTTP desde Nginx"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.nginx_sg.id]
  }

  ingress {
    description     = "HTTPS desde Nginx"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.nginx_sg.id]
  }

  ingress {
    description = "Acceso desde VPN"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.8.0.0/24"]
  }

  ingress {
    description = "SSH abierto temporal"
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

  tags = merge(local.tags, {
    Name = "sg-glpi-dracs"
  })
}