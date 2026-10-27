variable "region" {
  type        = string
  description = "AWS region for the provider (Route 53 itself is global)"
  default     = "eu-central-1"
}

variable "zone_name" {
  type        = string
  description = "Delegated zone created by infra/dns"
  default     = "ih.rolan.dog"

  validation {
    condition     = can(regex("^[a-z0-9-]+\\.rolan\\.dog$", var.zone_name))
    error_message = "zone_name must look like <label>.rolan.dog"
  }
}

variable "record_name" {
  type        = string
  description = "Record label inside the zone"
  default     = "app.p2"
}

variable "gateway_hostname" {
  type        = string
  description = "DNS name of the Envoy Gateway NLB; set by rg-dns-record.sh from kubectl"

  validation {
    condition     = can(regex("^[a-z0-9-]+\\.elb\\.[a-z0-9-]+\\.amazonaws\\.com$", var.gateway_hostname))
    error_message = "gateway_hostname must be an NLB name (<id>.elb.<region>.amazonaws.com); a Classic LB name has the region first"
  }
}
