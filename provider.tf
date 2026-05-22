terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # Backend remoto S3 con locking nativo (ver backend.tf).
  # Bootstrap completado: bucket creado por el primer apply local.
  backend "s3" {
    bucket       = "dracs-tfstate-563771271989"
    key          = "infra/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
}
