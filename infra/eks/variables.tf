variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "name" {
  description = "EKS cluster name, also used for the VPC"
  type        = string
  default     = "eks-rolando-p2"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,38}$", var.name))
    error_message = "name must be 3-39 chars: lowercase letters, digits, hyphens"
  }
}

variable "kubernetes_version" {
  type    = string
  default = "1.35"

  validation {
    condition     = can(regex("^1\\.[0-9]{2}$", var.kubernetes_version))
    error_message = "kubernetes_version must look like 1.35"
  }
}

variable "node_arch" {
  type    = string
  default = "arm64"

  validation {
    condition     = contains(["arm64", "x86_64"], var.node_arch)
    error_message = "node_arch must be arm64 or x86_64"
  }
}

variable "node_instance_type" {
  type    = string
  default = "t4g.medium"
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 3
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "vpc_cidr must be a valid IPv4 CIDR"
  }
}

variable "api_allowed_cidrs" {
  type        = list(string)
  description = "IPv4 CIDRs allowed to reach the public EKS API endpoint; set by rg-eks-up.sh from the current egress IP"

  validation {
    condition = (
      length(var.api_allowed_cidrs) > 0 &&
      alltrue([for c in var.api_allowed_cidrs : can(cidrnetmask(c)) && c != "0.0.0.0/0"])
    )
    error_message = "api_allowed_cidrs must be a non-empty list of IPv4 CIDRs and must not contain 0.0.0.0/0."
  }
}

variable "addon_versions" {
  description = "Pinned add-on versions, newest listed for Kubernetes 1.35 on 2026-10-25"
  type        = map(string)
  default = {
    "vpc-cni"                = "v1.23.2-eksbuild.8"
    "kube-proxy"             = "v1.35.3-eksbuild.62"
    "coredns"                = "v1.14.7-eksbuild.22"
    "aws-ebs-csi-driver"     = "v1.67.2-eksbuild.1"
    "eks-pod-identity-agent" = "v1.4.1-eksbuild.2"
  }
}
