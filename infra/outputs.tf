output "vpc_id" {
  value = aws_vpc.main.id
}

output "subnet_ids" {
  value = {
    public  = aws_subnet.public.id
    backend = aws_subnet.backend.id
    db      = aws_subnet.db.id
  }
}

output "nat_gateway_id" {
  value = aws_nat_gateway.main.id
}

output "security_group_ids" {
  value = local.sg_ids
}

output "ami" {
  description = "Resolved image, to check it is a plain Debian 13 arm64 release"
  value       = "${data.aws_ami.debian13.name} (${data.aws_ami.debian13.id})"
}

output "frontend_public_ip" {
  value = aws_instance.vm["frontend"].public_ip
}

output "private_ips" {
  value = {
    backend = aws_instance.vm["backend"].private_ip
    db      = aws_instance.vm["db"].private_ip
  }
}

output "urls" {
  value = {
    vote   = "http://${aws_instance.vm["frontend"].public_ip}"
    result = "http://${aws_instance.vm["frontend"].public_ip}:8081"
  }
}
