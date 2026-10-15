locals {
  az = "${var.region}${var.az_suffix}"
}

# Debian 13 arm64 only; the name pattern also excludes the
# debian-13-backports-* images listed next to them
data "aws_ami" "debian13" {
  most_recent = true
  owners      = ["136693071363"]

  filter {
    name   = "name"
    values = ["debian-13-arm64-*"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

# ---------- network ----------

resource "aws_vpc" "main" {
  #checkov:skip=CKV2_AWS_11:lab VPC lives for hours; flow logs add IAM, log-group and cost for no benefit
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "rg-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "rg-igw" }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.subnet_cidrs["public"]
  availability_zone = local.az
  tags              = { Name = "rg-public" }
}

resource "aws_subnet" "backend" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.subnet_cidrs["backend"]
  availability_zone = local.az
  tags              = { Name = "rg-private-backend" }
}

resource "aws_subnet" "db" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.subnet_cidrs["db"]
  availability_zone = local.az
  tags              = { Name = "rg-private-db" }
}

resource "aws_eip" "nat" {
  domain     = "vpc"
  tags       = { Name = "rg-nat-eip" }
  depends_on = [aws_internet_gateway.main]
}

# private tiers need egress to pull images and packages
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  tags          = { Name = "rg-nat" }
  depends_on    = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "rg-rt-public" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "rg-rt-private" }
}

resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "backend" {
  subnet_id      = aws_subnet.backend.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "db" {
  subnet_id      = aws_subnet.db.id
  route_table_id = aws_route_table.private.id
}

# empty on purpose: nothing may rely on the VPC default group
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "rg-sg-default-locked" }
}

# ---------- security groups (rules are separate resources) ----------

resource "aws_security_group" "frontend" {
  name        = "rg-sg-frontend"
  description = "vote and result; SSH jump host"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "rg-sg-frontend" }
}

resource "aws_security_group" "backend" {
  name        = "rg-sg-backend"
  description = "redis and worker"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "rg-sg-backend" }
}

resource "aws_security_group" "db" {
  name        = "rg-sg-db"
  description = "postgres"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "rg-sg-db" }
}

# frontend: public ports plus SSH from the admin address only
resource "aws_vpc_security_group_ingress_rule" "frontend_vote" {
  #checkov:skip=CKV_AWS_260:vote is the public web endpoint; narrow with web_cidr
  security_group_id = aws_security_group.frontend.id
  description       = "vote"
  cidr_ipv4         = var.web_cidr
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  tags              = { Name = "rg-frontend-vote" }
}

resource "aws_vpc_security_group_ingress_rule" "frontend_result" {
  security_group_id = aws_security_group.frontend.id
  description       = "result"
  cidr_ipv4         = var.web_cidr
  ip_protocol       = "tcp"
  from_port         = 8081
  to_port           = 8081
  tags              = { Name = "rg-frontend-result" }
}

resource "aws_vpc_security_group_ingress_rule" "frontend_ssh" {
  security_group_id = aws_security_group.frontend.id
  description       = "ssh from admin"
  cidr_ipv4         = var.admin_cidr
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  tags              = { Name = "rg-frontend-ssh" }
}

# backend: redis from the frontend (vote) only
resource "aws_vpc_security_group_ingress_rule" "backend_redis" {
  security_group_id            = aws_security_group.backend.id
  description                  = "redis from vote"
  referenced_security_group_id = aws_security_group.frontend.id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  tags                         = { Name = "rg-backend-redis" }
}

resource "aws_vpc_security_group_ingress_rule" "backend_ssh" {
  #checkov:skip=CKV_AWS_24:source is the frontend SG, not a CIDR; checkov false positive
  security_group_id            = aws_security_group.backend.id
  description                  = "ssh via the frontend jump host"
  referenced_security_group_id = aws_security_group.frontend.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  tags                         = { Name = "rg-backend-ssh" }
}

# db: postgres from the worker (backend) and from result (frontend)
resource "aws_vpc_security_group_ingress_rule" "db_from_backend" {
  security_group_id            = aws_security_group.db.id
  description                  = "postgres from worker"
  referenced_security_group_id = aws_security_group.backend.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  tags                         = { Name = "rg-db-from-backend" }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_frontend" {
  security_group_id            = aws_security_group.db.id
  description                  = "postgres from result"
  referenced_security_group_id = aws_security_group.frontend.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  tags                         = { Name = "rg-db-from-frontend" }
}

resource "aws_vpc_security_group_ingress_rule" "db_ssh" {
  #checkov:skip=CKV_AWS_24:source is the frontend SG, not a CIDR; checkov false positive
  security_group_id            = aws_security_group.db.id
  description                  = "ssh via the frontend jump host"
  referenced_security_group_id = aws_security_group.frontend.id
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  tags                         = { Name = "rg-db-ssh" }
}

locals {
  sg_ids = {
    frontend = aws_security_group.frontend.id
    backend  = aws_security_group.backend.id
    db       = aws_security_group.db.id
  }
}

resource "aws_vpc_security_group_egress_rule" "all" {
  for_each          = local.sg_ids
  security_group_id = each.value
  description       = "all outbound; private tiers leave through the NAT gateway"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  tags              = { Name = "rg-${each.key}-egress" }
}

# ---------- compute ----------

locals {
  ssh_key     = pathexpand(var.ssh_private_key_path)
  known_hosts = "${abspath("${path.module}/../ansible")}/known_hosts"

  instances = {
    frontend = { name = "rg-vm1", subnet = aws_subnet.public.id, public = true }
    backend  = { name = "rg-vm2", subnet = aws_subnet.backend.id, public = false }
    db       = { name = "rg-vm3", subnet = aws_subnet.db.id, public = false }
  }
}

resource "aws_instance" "vm" {
  for_each = local.instances

  ami                         = data.aws_ami.debian13.id
  instance_type               = var.instance_types[each.key]
  subnet_id                   = each.value.subnet
  vpc_security_group_ids      = [local.sg_ids[each.key]]
  key_name                    = var.key_name
  associate_public_ip_address = each.value.public

  # IMDSv2 only; hop limit 1 keeps containers away from instance credentials
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = var.root_volume_gb
  }

  tags = {
    Name = each.value.name
    Tier = each.key
  }

  # private hosts need the NAT route before Ansible installs anything
  depends_on = [aws_route.private_nat]
}

# hosts.ini is generated, never committed; it holds IPs and the key path
resource "local_file" "ansible_hosts" {
  filename        = "${path.module}/../ansible/hosts.ini"
  file_permission = "0640"
  content         = <<-EOT
    [local]
    localhost ansible_connection=local

    [frontend]
    rg-vm1 ansible_host=${aws_instance.vm["frontend"].public_ip}

    [backend]
    rg-vm2 ansible_host=${aws_instance.vm["backend"].private_ip}

    [db]
    rg-vm3 ansible_host=${aws_instance.vm["db"].private_ip}

    [aws:children]
    frontend
    backend
    db

    [private:children]
    backend
    db

    [aws:vars]
    ansible_user=admin
    ansible_python_interpreter=/usr/bin/python3
    ansible_ssh_private_key_file=${local.ssh_key}

    # private hosts are reached through the frontend; a project-local
    # known_hosts avoids clashes when rebuilt VMs reuse private IPs
    [private:vars]
    ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${local.known_hosts} -o ProxyCommand="ssh -i ${local.ssh_key} -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=${local.known_hosts} -W %h:%p -q admin@${aws_instance.vm["frontend"].public_ip}"'
  EOT
}
