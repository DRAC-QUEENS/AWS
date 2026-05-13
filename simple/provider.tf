terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Backend remoto S3.
  # Descomentar SOLO tras el primer `terraform apply` que crea el bucket.
  # Luego ejecutar:  terraform init -migrate-state
  #
  # backend "s3" {
  #   bucket  = "dracs-tfstate-<ACCOUNT_ID>"
  #   key     = "simple/terraform.tfstate"
  #   region  = "us-east-1"
  #   encrypt = true
  # }
}

provider "aws" {
  region = var.region
}
