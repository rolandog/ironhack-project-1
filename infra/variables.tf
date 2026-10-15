variable "region" {
  type    = string
  default = "eu-central-1"
}

variable "az_suffix" {
  description = "Availability zone letter; one AZ keeps NAT cost down"
  type        = string
  default     = "a"
}

variable "key_name" {
  description = "EC2 key pair created by the bootstrap script"
  type        = string
  default     = "rg-keypair"
}

variable "ssh_private_key_path" {
  description = "Private key matching key_name, written into hosts.ini"
  type        = string
  default     = "~/.ssh/rg-keypair"
}

variable "admin_cidr" {
  description = "Source CIDR allowed to SSH to the frontend (your IP/32)"
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && var.admin_cidr != "0.0.0.0/0"
    error_message = "admin_cidr must be a valid CIDR and must not be 0.0.0.0/0."
  }
}

variable "web_cidr" {
  description = "Source CIDR allowed to reach vote (80) and result (8081)"
  type        = string
  default     = "0.0.0.0/0"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "subnet_cidrs" {
  type = map(string)
  default = {
    public  = "10.0.1.0/24"
    backend = "10.0.2.0/24"
    db      = "10.0.3.0/24"
  }
}

variable "instance_types" {
  description = "Per tier; raise backend to t4g.micro if the worker is OOM-killed"
  type        = map(string)
  default = {
    frontend = "t4g.nano"
    backend  = "t4g.nano"
    db       = "t4g.nano"
  }
}

variable "root_volume_gb" {
  type    = number
  default = 10
}
