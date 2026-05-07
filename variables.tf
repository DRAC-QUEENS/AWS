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
  description = "Contrasena de la BD RDS de GLPI"
  type        = string
  sensitive   = true
}
