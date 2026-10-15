terraform {
  # use_lockfile needs OpenTofu >= 1.10; you run 1.13.1
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }

  # bucket, key, region, encrypt and use_lockfile come from backend.hcl
  backend "s3" {}
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = "ironhack-project-1"
      ManagedBy = "opentofu"
    }
  }
}
