# =============================================================================
# Backups: AMI snapshots + S3 bucket
# =============================================================================
# - AMIs: imagenes completas de las instancias (migracion entre cuentas)
# - Bucket S3: destino para volcados de aplicacion (DB dumps, configs, logs)
# =============================================================================

# ---------- S3 BUCKET DE BACKUPS DE APLICACION ----------

resource "aws_s3_bucket" "backups" {
  bucket = "dracs-backups-${data.aws_caller_identity.current.account_id}"
  tags   = { Name = "backups-dracs" }
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Lifecycle: 30d en S3 estandar -> Glacier; expiracion total a los 365d.
# Reduce coste sin perder backups recientes (los mas probables de necesitar).
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "archivado-y-expiracion"
    status = "Enabled"

    filter {}

    transition {
      days          = 30
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }
  }
}

# ---------- AMI SNAPSHOTS ----------
# Uso: terraform apply -var create_ami_backup=true

variable "create_ami_backup" {
  description = "Crear AMI snapshots de las instancias (true/false)"
  type        = bool
  default     = false
}

# AMI de WireGuard (VPN Gateway)
resource "aws_ami_from_instance" "wireguard" {
  count                   = var.create_ami_backup ? 1 : 0
  name                    = "wireguard-gateway-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"
  source_instance_id      = aws_instance.wireguard.id
  snapshot_without_reboot = true

  tags = {
    Name             = "wireguard-backup"
    Description      = "WireGuard VPN Gateway backup"
    BackupDate       = formatdate("YYYY-MM-DD hh:mm:ss", timestamp())
    OriginalInstance = aws_instance.wireguard.id
  }

  depends_on = [aws_instance.wireguard]
}

# AMI de Nginx (Reverse Proxy)
resource "aws_ami_from_instance" "nginx" {
  count                   = var.create_ami_backup ? 1 : 0
  name                    = "nginx-proxy-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"
  source_instance_id      = aws_instance.nginx.id
  snapshot_without_reboot = true

  tags = {
    Name             = "nginx-backup"
    Description      = "Nginx Reverse Proxy backup"
    BackupDate       = formatdate("YYYY-MM-DD hh:mm:ss", timestamp())
    OriginalInstance = aws_instance.nginx.id
  }

  depends_on = [aws_instance.nginx]
}

# AMI de GLPI (Inventory Management - CRÍTICA)
resource "aws_ami_from_instance" "glpi" {
  count                   = var.create_ami_backup ? 1 : 0
  name                    = "glpi-server-${formatdate("YYYY-MM-DD-hhmm", timestamp())}"
  source_instance_id      = aws_instance.glpi.id
  snapshot_without_reboot = true

  tags = {
    Name             = "glpi-backup"
    Description      = "GLPI Inventory Server backup (CRÍTICA)"
    BackupDate       = formatdate("YYYY-MM-DD hh:mm:ss", timestamp())
    OriginalInstance = aws_instance.glpi.id
    Criticality      = "HIGH"
  }

  depends_on = [aws_instance.glpi]
}

# Outputs de AMI IDs para referencia
output "ami_wireguard_id" {
  description = "AMI ID del WireGuard (si se creó)"
  value       = try(aws_ami_from_instance.wireguard[0].id, "No creada - ejecuta: terraform apply -var create_ami_backup=true")
}

output "ami_nginx_id" {
  description = "AMI ID del Nginx (si se creó)"
  value       = try(aws_ami_from_instance.nginx[0].id, "No creada - ejecuta: terraform apply -var create_ami_backup=true")
}

output "ami_glpi_id" {
  description = "AMI ID del GLPI (si se creó)"
  value       = try(aws_ami_from_instance.glpi[0].id, "No creada - ejecuta: terraform apply -var create_ami_backup=true")
}
