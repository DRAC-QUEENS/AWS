# ---------- EC2 INSTANCES ----------

resource "aws_instance" "wireguard" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  key_name               = var.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.wireguard.id]
  private_ip             = "10.0.1.10"
  source_dest_check      = false

  # Inyecta las claves WireGuard (sensitive vars) en el script de bootstrap
  user_data = templatefile("user_data/wireguard.sh.tpl", {
    aws_private_key     = var.wg_aws_private_key
    opnsense_public_key = var.wg_opnsense_public_key
    preshared_key       = var.wg_preshared_key
  })

  root_block_device {
    volume_size = 30
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

  user_data = templatefile("user_data/nginx.sh.tpl", {
    glpi_url = var.glpi_public_url
  })

  root_block_device {
    volume_size = 30
    encrypted   = true
  }

  tags = { Name = "ec2-nginx-dracs" }
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
