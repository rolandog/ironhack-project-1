variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "cluster_name" {
  type        = string
  description = "EKS cluster the deploy role may touch (infra/eks default)"
  default     = "eks-rolando-p2"
}

variable "images" {
  type        = set(string)
  description = "application images; one ECR repository rg-p2-<name> each"
  default     = ["vote", "result", "worker"]
}

variable "keep_images" {
  type    = number
  default = 20
}

variable "create_oidc_provider" {
  type        = bool
  description = "false when the account already has the GitHub OIDC provider (shared account)"
}

variable "github_subject_repo" {
  type        = string
  description = "repo segment of the OIDC sub claim, old or immutable format"

  validation {
    condition     = can(regex("^repo:[A-Za-z0-9-]+(@[0-9]+)?/[A-Za-z0-9._-]+(@[0-9]+)?$", var.github_subject_repo))
    error_message = "use repo:OWNER/REPO or repo:OWNER@ID/REPO@ID"
  }
}

variable "push_branches" {
  type    = list(string)
  default = ["develop", "main"]
}

variable "deploy_branches" {
  type    = list(string)
  default = ["main"]
}
