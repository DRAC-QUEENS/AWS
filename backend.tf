# ---------- REMOTE STATE (S3 + DYNAMODB) ----------
# Recursos para guardar el tfstate en la nube y evitar applies concurrentes.
#
# Bootstrap (chicken-and-egg):
#   1. terraform apply  ← crea bucket y tabla con state local
#   2. Descomentar bloque backend "s3" en provider.tf
#   3. terraform init -migrate-state  ← mueve el state local al bucket

data "aws_caller_identity" "current" {}

# Bucket para el tfstate. Nombre con account_id para que sea globalmente unico.
resource "aws_s3_bucket" "tfstate" {
  bucket = "dracs-tfstate-${data.aws_caller_identity.current.account_id}"

  # Si se borra, se pierde el historial del state -> proteccion
  lifecycle {
    prevent_destroy = true
  }

  tags = { Name = "tfstate-dracs" }
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

# Tabla de locks: terraform escribe aqui durante apply para impedir
# que dos personas modifiquen el state a la vez
resource "aws_dynamodb_table" "tfstate_lock" {
  name         = "dracs-tfstate-lock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = { Name = "tfstate-lock-dracs" }
}
