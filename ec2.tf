resource "aws_instance" "wireguard" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.wireguard_sg.id]
  private_ip                  = "10.0.1.10"
  associate_public_ip_address = true
  source_dest_check           = false
  user_data                   = file("${path.module}/user_data/wireguard.sh")

  tags = merge(local.tags, {
    Name = "ec2-wireguard-dracs"
  })
}

resource "aws_eip" "wireguard_eip" {
  instance = aws_instance.wireguard.id
  domain   = "vpc"

  tags = merge(local.tags, {
    Name = "eip-wireguard-dracs"
  })
}

resource "aws_instance" "nginx" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  key_name                    = var.key_name
  subnet_id                   = aws_subnet.public.id
  vpc_security_group_ids      = [aws_security_group.nginx_sg.id]
  private_ip                  = "10.0.1.20"
  associate_public_ip_address = true
  user_data                   = file("${path.module}/user_data/nginx.sh")

  tags = merge(local.tags, {
    Name = "ec2-nginx-dracs"
  })
}

resource "aws_instance" "glpi" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = var.key_name
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.glpi_sg.id]
  private_ip             = "10.0.2.10"
  user_data              = file("${path.module}/user_data/glpi.sh")

  tags = merge(local.tags, {
    Name = "ec2-glpi-dracs"
  })
}