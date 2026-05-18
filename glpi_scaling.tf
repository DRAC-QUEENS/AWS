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
    path                = "/"
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

  # Redirige todo HTTP a HTTPS (cert ACM en listener 443).
  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# Certificado importado por certbot (DNS-01 vía DuckDNS); se renueva cada 90d
# y se re-importa a ACM. `most_recent = true` recoge la versión más fresca.
data "aws_acm_certificate" "glpi" {
  domain      = "dracs-glpi.duckdns.org"
  most_recent = true
  statuses    = ["ISSUED"]
  # Certbot emite cert ECDSA por defecto; el filtro por defecto del data source es RSA.
  key_types = ["EC_prime256v1", "EC_secp384r1"]
}

resource "aws_lb_listener" "alb_https" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = data.aws_acm_certificate.glpi.arn

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
    path                = "/"
    matcher             = "200-302"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = { Name = "nlb-to-alb-dracs" }
}

resource "aws_lb_target_group_attachment" "nlb_to_alb" {
  target_group_arn = aws_lb_target_group.nlb_to_alb.arn
  target_id        = aws_lb.alb.arn
  port             = 80

  # NLB->ALB requiere que el ALB tenga listener en el puerto antes de registrar
  depends_on = [aws_lb_listener.alb_http]
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

# NLB TCP:443 → ALB:443 (TLS termina en ALB)
resource "aws_lb_target_group" "nlb_to_alb_443" {
  name        = "nlb-to-alb-443-dracs"
  port        = 443
  protocol    = "TCP"
  target_type = "alb"
  vpc_id      = aws_vpc.main.id

  health_check {
    protocol            = "HTTPS"
    path                = "/"
    matcher             = "200-302"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }

  tags = { Name = "nlb-to-alb-443-dracs" }
}

resource "aws_lb_target_group_attachment" "nlb_to_alb_443" {
  target_group_arn = aws_lb_target_group.nlb_to_alb_443.arn
  target_id        = aws_lb.alb.arn
  port             = 443
  depends_on       = [aws_lb_listener.alb_https]
}

resource "aws_lb_listener" "nlb_https" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nlb_to_alb_443.arn
  }
}

# ---------- LAUNCH TEMPLATE + ASG ----------

resource "aws_launch_template" "glpi" {
  name_prefix   = "lt-glpi-dracs-"
  image_id      = var.glpi_ami_id != "" ? var.glpi_ami_id : data.aws_ami.ubuntu.id
  instance_type = "t3.small"
  key_name      = var.key_name

  vpc_security_group_ids = [aws_security_group.glpi.id]

  # IAM profile preexistente de AWS Academy: da acceso a SSM Session Manager,
  # Run Command y CloudWatch Logs. Imprescindible para troubleshooting sin SSH.
  iam_instance_profile {
    name = "LabInstanceProfile"
  }

  user_data = base64encode(templatefile("user_data/glpi_asg.sh.tpl", {
    rds_endpoint    = aws_db_instance.glpi.address
    db_password     = var.glpi_db_password
    efs_dns         = "${aws_efs_file_system.glpi.id}.efs.${var.region}.amazonaws.com"
    glpi_public_url = var.glpi_public_url
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
  min_size            = 0
  max_size            = 3
  desired_capacity    = var.asg_desired
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

# ---------- Política de escalado (Target Tracking CPU) ----------

resource "aws_autoscaling_policy" "glpi_cpu" {
  name                   = "asg-glpi-cpu-tracking"
  autoscaling_group_name = aws_autoscaling_group.glpi.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value     = 60.0
    # Tiempo mínimo entre scale-in: 300s (evita flapping)
    disable_scale_in = false
  }
}
