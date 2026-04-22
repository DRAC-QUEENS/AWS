# Configuración de Terraform y AWS Provider
# =========================================
# Define los requisitos de versión, providers necesarios y credenciales de AWS

terraform {
  # Versión mínima de Terraform requerida
  required_version = ">= 1.5.0"

  # Providers necesarios para este proyecto
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # TODO: Configurar backend remoto para estado compartido
  # Esto permitirá:
  # - Trabajo en equipo sin conflictos de estado
  # - Historial de cambios auditables
  # - Prevención de cambios simultáneos (locking)
  # Ejemplo:
  # backend "s3" {
  #   bucket         = "dracs-terraform-state"
  #   key            = "aws/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "terraform-locks"
  #   encrypt        = true
  # }
}

# AWS Provider Configuration
# Autentica con AWS usando credenciales locales (AWS_PROFILE, ~/.aws/credentials)
provider "aws" {
  region = var.aws_region
}