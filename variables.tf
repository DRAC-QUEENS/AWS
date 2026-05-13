variable "region" {
  default = "us-east-1"
}

variable "key_name" {
  default = "dracs-keypair"
}

variable "wireguard_ami_id" {
  description = "AMI custom para la EC2 WireGuard (migracion entre cuentas). Vacio = Ubuntu 24.04 LTS latest."
  default     = ""
}

variable "nginx_ami_id" {
  description = "AMI custom para la EC2 Nginx (migracion entre cuentas). Vacio = Ubuntu 24.04 LTS latest."
  default     = ""
}

variable "asg_desired" {
  description = "Numero de instancias deseado en el ASG GLPI. Bajar a 0 durante migracion de datos a RDS+EFS, luego subir a 1."
  type        = number
  default     = 1
}

variable "glpi_public_url" {
  description = "URL publica de GLPI. Se fuerza en cada arranque del ASG sobre `url_base` en BD para evitar que herede valores del setup viejo (p.ej. tras importar dump migrado)."
  type        = string
  default     = "https://dracs-glpi.duckdns.org"
}

variable "glpi_db_password" {
  description = "Contrasena de la BD RDS de GLPI"
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
