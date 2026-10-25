output "zone_id" {
  value = aws_route53_zone.ih.zone_id
}

output "zone_name" {
  value = aws_route53_zone.ih.name
}

output "name_servers" {
  value = aws_route53_zone.ih.name_servers
}
