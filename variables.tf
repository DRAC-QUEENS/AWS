# Variables de Configuración del Proyecto
# ========================================
# Define parámetros que pueden modificarse sin editar la infraestructura

variable "aws_region" {
  description = "Región AWS donde se desplegará la infraestructura"
  type        = string
  default     = "us-east-1"

  # Nota: Cambiar región requiere nueva EIP allocation
  # Las instancias se relocalizarán en la nueva región
}

variable "instance_type" {
  description = "Tipo de instancia EC2 para todas las máquinas virtuales"
  type        = string
  default     = "t3.micro"

  # t3.micro es eligible para AWS Free Tier (750 hours/mes primer año)
  # Para cargas ligeras (desarrollo, labs): t3.micro, t3.small
  # Para producción: t3.medium, t3.large o similares dependiendo carga
}

variable "key_name" {
  description = "Nombre de la key pair EC2 registrada en AWS para acceso SSH"
  type        = string
  default     = "dracs-keypair"

  # Prerequisito: Esta key pair debe existir en AWS
  # Crear con: aws ec2 create-key-pair --key-name dracs-keypair --query 'KeyMaterial' --output text > dracs-keypair.pem
  # Configurar permisos: chmod 400 dracs-keypair.pem
}

variable "project_name" {
  description = "Nombre del proyecto para identificación y etiquetado de recursos"
  type        = string
  default     = "dracs-hybrid"

  # Se usa en:
  # - Tags de recursos (identificación visual en AWS Console)
  # - Nombres de SG, VPC, etc. para fácil búsqueda
}

# TODO: Variables adicionales para mayor parametrización
# variable "vpc_cidr" {
#   description = "CIDR block de la VPC"
#   type        = string
#   default     = "10.0.0.0/16"
# }
#
# variable "public_subnet_cidr" {
#   description = "CIDR block de la subnet pública"
#   type        = string
#   default     = "10.0.1.0/24"
# }
#
# variable "private_subnet_cidr" {
#   description = "CIDR block de la subnet privada"
#   type        = string
#   default     = "10.0.2.0/24"
# }
#
# variable "wireguard_private_ip" {
#   description = "IP privada fija para WireGuard"
#   type        = string
#   default     = "10.0.1.10"
# }