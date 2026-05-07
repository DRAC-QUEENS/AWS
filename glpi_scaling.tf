# =============================================================================
# GLPI: ALB + ASG + RDS + EFS
# =============================================================================
# Arquitectura:
#   Internet → NLB (EIP fija, DuckDNS) → ALB → ASG GLPI (privado, 2 AZs)
#   WireGuard → Nginx (10.0.1.20) → ALB → ASG GLPI
#   Todas las instancias GLPI comparten: EFS (files) + RDS (MariaDB)
# =============================================================================

# ---------- EFS (almacenamiento compartido de ficheros GLPI) ----------

resource "aws_efs_file_system" "glpi" {
  encrypted = true
  tags      = { Name = "efs-glpi-dracs" }
}

resource "aws_efs_mount_target" "glpi_a" {
  file_system_id  = aws_efs_file_system.glpi.id
  subnet_id       = aws_subnet.private.id
  security_groups = [aws_security_group.efs.id]
}

resource "aws_efs_mount_target" "glpi_b" {
  file_system_id  = aws_efs_file_system.glpi.id
  subnet_id       = aws_subnet.private_b.id
  security_groups = [aws_security_group.efs.id]
}

# ---------- RDS (MariaDB fuera del ASG, datos persistentes) ----------

resource "aws_db_subnet_group" "glpi" {
  name       = "rds-subnet-glpi-dracs"
  subnet_ids = [aws_subnet.private.id, aws_subnet.private_b.id]
  tags       = { Name = "rds-subnet-group-dracs" }
}

resource "aws_db_instance" "glpi" {
  identifier        = "rds-glpi-dracs"
  engine            = "mariadb"
  engine_version    = "10.11"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "glpi"
  username = "glpi"
  password = var.glpi_db_password

  db_subnet_group_name   = aws_db_subnet_group.glpi.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  backup_retention_period = 7
  # Para entorno de laboratorio; en produccion: skip_final_snapshot = false
  skip_final_snapshot = true
  deletion_protection = false

  tags = { Name = "rds-glpi-dracs" }
}

# ---------- ALB (Application Load Balancer, Layer 7) ----------

resource "aws_lb" "alb" {
  name               = "alb-glpi-dracs"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = [aws_subnet.public.id, aws_subnet.public_b.id]
  tags               = { Name = "alb-glpi-dracs" }
}

resource "aws_lb_target_group" "glpi" {
  name     = "tg-glpi-dracs"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/glpi/"
    matcher             = "200-302"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
  }

  tags = { Name = "tg-glpi-dracs" }
}

resource "aws_lb_listener" "alb_http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.glpi.arn
  }
}

# ---------- NLB + EIP (IP fija para DuckDNS) ----------

resource "aws_eip" "nlb" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.igw]
  tags       = { Name = "eip-nlb-dracs" }
}

# NLB en una sola AZ con EIP: DuckDNS apunta a esta unica IP.
# El ALB detras distribuye el trafico a ambas AZs del ASG.
resource "aws_lb" "nlb" {
  name               = "nlb-glpi-dracs"
  load_balancer_type = "network"
  internal           = false

  subnet_mapping {
    subnet_id     = aws_subnet.public.id
    allocation_id = aws_eip.nlb.id
  }

  tags = { Name = "nlb-glpi-dracs" }
}

# Target group tipo "alb": el NLB delega en el ALB directamente
resource "aws_lb_target_group" "nlb_to_alb" {
  name        = "nlb-to-alb-dracs"
  port        = 80
  protocol    = "TCP"
  target_type = "alb"
  vpc_id      = aws_vpc.main.id

  health_check {
    protocol            = "HTTP"
    path                = "/glpi/"
    matcher             = "200-302"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = { Name = "nlb-to-alb-dracs" }
}

resource "aws_lb_target_group_attachment" "nlb_to_alb" {
  target_group_arn = aws_lb_target_group.nlb_to_alb.arn
  target_id        = aws_lb.alb.arn
  port             = 80
}

resource "aws_lb_listener" "nlb_http" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nlb_to_alb.arn
  }
}

# ---------- LAUNCH TEMPLATE + ASG ----------

resource "aws_launch_template" "glpi" {
  name_prefix   = "lt-glpi-dracs-"
  image_id      = local.ami
  instance_type = "t3.small"
  key_name      = var.key_name

  vpc_security_group_ids = [aws_security_group.glpi.id]

  user_data = base64encode(templatefile("user_data/glpi_asg.sh.tpl", {
    rds_endpoint = aws_db_instance.glpi.address
    db_password  = var.glpi_db_password
    efs_dns      = "${aws_efs_file_system.glpi.id}.efs.${var.region}.amazonaws.com"
  }))

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = 20
      encrypted   = true
    }
  }
}

resource "aws_autoscaling_group" "glpi" {
  name                = "asg-glpi-dracs"
  min_size            = 1
  max_size            = 3
  desired_capacity    = 1
  vpc_zone_identifier = [aws_subnet.private.id, aws_subnet.private_b.id]

  target_group_arns = [aws_lb_target_group.glpi.arn]

  launch_template {
    id      = aws_launch_template.glpi.id
    version = aws_launch_template.glpi.latest_version
  }

  # ELB health checks para que el ASG termine instancias que no pasan el ALB check
  health_check_type         = "ELB"
  health_check_grace_period = 300

  # Garantizar que los mount targets EFS existen antes de lanzar instancias
  depends_on = [aws_efs_mount_target.glpi_a, aws_efs_mount_target.glpi_b]

  tag {
    key                 = "Name"
    value               = "ec2-glpi-asg-dracs"
    propagate_at_launch = true
  }
}
