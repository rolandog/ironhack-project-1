terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # bucket is passed at init time (-backend-config): it embeds the account ID
  backend "s3" {
    key          = "rg-dns/terraform.tfstate"
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
      Project   = "rg-dns"
      ManagedBy = "opentofu"
    }
  }
}
