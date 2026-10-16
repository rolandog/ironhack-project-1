terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0" # must match infra/providers.tf
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
  # why: this folder creates the state bucket, so its own state stays local
}

provider "aws" {
  region = var.region
}
