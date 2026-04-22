variable "aws_region" {
  description = "Región AWS del laboratorio"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "Tipo de instancia barato permitido en el laboratorio"
  type        = string
  default     = "t3.micro"
}

variable "key_name" {
  description = "Nombre de la key pair de AWS para acceder por SSH"
  type        = string
  default     = "dracs-keypair"
}

variable "project_name" {
  description = "Nombre del proyecto para etiquetas"
  type        = string
  default     = "dracs-hybrid"
}