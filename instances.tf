# ---------- EC2 INSTANCES ----------
# AMI por maquina: si se pasa una AMI custom (migracion), se usa esa; si no,
# Ubuntu 24.04 LTS latest. Las instancias del ASG GLPI van con Ubuntu vanilla
# (su user_data instala GLPI contra RDS+EFS), por eso no hay glpi_ami_id aqui.

resource "aws_instance" "wireguard" {
  ami                    = var.wireguard_ami_id != "" ? var.wireguard_ami_id : data.aws_ami.ubuntu.id
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
  ami                    = var.nginx_ami_id != "" ? var.nginx_ami_id : data.aws_ami.ubuntu.id
  instance_type          = "t3.micro"
  key_name               = var.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.nginx.id]
  private_ip             = "10.0.1.20"

  # Inyecta el DNS del ALB en tiempo de despliegue para que Nginx proxee a él
  user_data = templatefile("user_data/nginx.sh.tpl", {
    alb_dns = aws_lb.alb.dns_name
  })

  root_block_device {
    volume_size = 30
    encrypted   = true
  }

  tags = { Name = "ec2-nginx-dracs" }

  # El ALB debe existir antes de que Nginx arranque con su DNS
  depends_on = [aws_lb.alb]
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
