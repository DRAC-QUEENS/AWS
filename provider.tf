terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Backend remoto S3 + DynamoDB (ver backend.tf).
  # Descomentar SOLO tras el primer `terraform apply` que crea el bucket
  # y la tabla. Luego ejecutar:  terraform init -migrate-state
  #
  # backend "s3" {
  #   bucket         = "dracs-tfstate-<ACCOUNT_ID>"
  #   key            = "infra/terraform.tfstate"
  #   region         = "us-east-1"
  #   encrypt        = true
  #   dynamodb_table = "dracs-tfstate-lock"
  # }
}

provider "aws" {
  region = var.region
}
