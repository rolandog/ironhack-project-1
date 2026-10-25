variable "region" {
  type        = string
  description = "AWS region for the provider (Route 53 itself is global)"
  default     = "eu-central-1"
}

variable "zone_name" {
  type        = string
  description = "Delegated zone; must be a direct child of rolan.dog"
  default     = "ih.rolan.dog"

  validation {
    condition     = can(regex("^[a-z0-9-]+\\.rolan\\.dog$", var.zone_name))
    error_message = "zone_name must look like <label>.rolan.dog"
  }
}
