# =============================================================================
# Backups: S3 bucket para volcados de aplicacion (DB dumps, configs, logs)
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
