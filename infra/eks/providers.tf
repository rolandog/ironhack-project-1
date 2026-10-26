terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # bucket is passed with -backend-config because its name contains the account id
  backend "s3" {
    key          = "rg-p2-eks/terraform.tfstate"
    region       = "eu-central-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Namespace = "rg"
      Project   = "rg-p2-eks"
      ManagedBy = "opentofu"
    }
  }
}
