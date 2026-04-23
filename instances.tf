# ---------- EC2 INSTANCES ----------

resource "aws_instance" "wireguard" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  key_name               = var.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.wireguard.id]
  private_ip             = "10.0.1.10"
  source_dest_check      = false
  user_data              = file("user_data/wireguard.sh")

  root_block_device {
    volume_size = 20
    encrypted   = true
  }

  tags = { Name = "ec2-wireguard-dracs" }
}

resource "aws_instance" "nginx" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  key_name               = var.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.nginx.id]
  private_ip             = "10.0.1.20"
  user_data              = file("user_data/nginx.sh")

  root_block_device {
    volume_size = 20
    encrypted   = true
  }

  tags = { Name = "ec2-nginx-dracs" }
}

resource "aws_instance" "glpi" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.small"
  key_name               = var.key_name
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.glpi.id]
  private_ip             = "10.0.2.10"
  user_data              = file("user_data/glpi.sh")

  root_block_device {
    volume_size = 30
    encrypted   = true
  }

  tags = { Name = "ec2-glpi-dracs" }
}

# ---------- ELASTIC IPs ----------

resource "aws_eip" "wireguard" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.igw]
  tags       = { Name = "eip-wireguard-dracs" }
}

resource "aws_eip_association" "wireguard" {
  instance_id   = aws_instance.wireguard.id
  allocation_id = aws_eip.wireguard.id
}

resource "aws_eip" "nginx" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.igw]
  tags       = { Name = "eip-nginx-dracs" }
}

resource "aws_eip_association" "nginx" {
  instance_id   = aws_instance.nginx.id
  allocation_id = aws_eip.nginx.id
}
