terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # bucket comes from: tofu init -backend-config="bucket=tf-state-<account>-eu-central-1"
  backend "s3" {
    key          = "rg-p2-ci/terraform.tfstate"
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
      Project   = "rg-p2"
      ManagedBy = "opentofu"
    }
  }
}
