output "fqdn" {
  description = "Public name of the voting app"
  value       = aws_route53_record.app.fqdn
}

output "target" {
  description = "NLB the record points at"
  value       = var.gateway_hostname
}
