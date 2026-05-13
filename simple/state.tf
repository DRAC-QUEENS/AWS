# ---------- REMOTE STATE (S3) ----------
# Bootstrap (chicken-and-egg):
#   1. terraform apply  <- crea el bucket con state local
#   2. Descomentar bloque backend "s3" en provider.tf
#   3. terraform init -migrate-state  <- mueve el state local al bucket

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "tfstate" {
  bucket = "dracs-tfstate-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true
  }

  tags = { Name = "tfstate-simple-dracs" }
}

# Versionado: permite recuperar versiones previas del state si se corrompe
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Cifrado en reposo (el state puede contener secretos en texto plano)
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Bloquea cualquier exposicion publica accidental
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
