variable "region" {
  default = "us-east-1"
}

variable "key_name" {
  default = "dracs-keypair"
}

variable "ami_id" {
  description = "AMI custom para migracion entre cuentas. Vacio = usa Ubuntu 24.04 LTS latest."
  default     = ""
}

variable "glpi_db_password" {
  description = "Contrasena de la BD MariaDB local de GLPI"
  type        = string
  sensitive   = true
}

# Claves WireGuard del tunel site-to-site con OPNsense.
# Sensibles: NUNCA commitear; pasar via terraform.tfvars (gitignored) o TF_VAR_*.
variable "wg_aws_private_key" {
  description = "WireGuard private key del gateway AWS"
  type        = string
  sensitive   = true
}

variable "wg_opnsense_public_key" {
  description = "WireGuard public key del peer OPNsense"
  type        = string
  sensitive   = true
}

variable "wg_preshared_key" {
  description = "WireGuard preshared key (PSK) del tunel"
  type        = string
  sensitive   = true
}
