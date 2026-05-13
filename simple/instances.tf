# ---------- AMI SELECTION ----------

locals {
  ami = var.ami_id != "" ? var.ami_id : data.aws_ami.ubuntu.id
}

# ---------- EC2 INSTANCES ----------

resource "aws_instance" "wireguard" {
  ami                    = local.ami
  instance_type          = "t3.micro"
  key_name               = var.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.wireguard.id]
  private_ip             = "10.0.1.10"
  source_dest_check      = false

  user_data = templatefile("user_data/wireguard.sh.tpl", {
    aws_private_key     = var.wg_aws_private_key
    opnsense_public_key = var.wg_opnsense_public_key
    preshared_key       = var.wg_preshared_key
  })

  root_block_device {
    volume_size = 20
    encrypted   = true
  }

  tags = { Name = "ec2-wireguard-simple-dracs" }
}

resource "aws_instance" "nginx" {
  ami                    = local.ami
  instance_type          = "t3.micro"
  key_name               = var.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.nginx.id]
  private_ip             = "10.0.1.20"

  user_data = templatefile("user_data/nginx.sh.tpl", {
    glpi_ip = aws_instance.glpi.private_ip
  })

  root_block_device {
    volume_size = 20
    encrypted   = true
  }

  tags = { Name = "ec2-nginx-simple-dracs" }

  depends_on = [aws_instance.glpi]
}

resource "aws_instance" "glpi" {
  ami                    = local.ami
  instance_type          = "t3.small"
  key_name               = var.key_name
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.glpi.id]
  private_ip             = "10.0.2.30"

  user_data = templatefile("user_data/glpi.sh.tpl", {
    db_password = var.glpi_db_password
  })

  root_block_device {
    volume_size = 30
    encrypted   = true
  }

  tags = { Name = "ec2-glpi-simple-dracs" }
}

# ---------- ELASTIC IPs ----------

resource "aws_eip" "wireguard" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.igw]
  tags       = { Name = "eip-wireguard-simple-dracs" }
}

resource "aws_eip_association" "wireguard" {
  instance_id   = aws_instance.wireguard.id
  allocation_id = aws_eip.wireguard.id
}

# EIP del Nginx: esta es la IP que apunta a DuckDNS
resource "aws_eip" "nginx" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.igw]
  tags       = { Name = "eip-nginx-simple-dracs" }
}

resource "aws_eip_association" "nginx" {
  instance_id   = aws_instance.nginx.id
  allocation_id = aws_eip.nginx.id
}
