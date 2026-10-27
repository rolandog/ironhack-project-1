locals {
  fqdn = "${var.record_name}.${var.zone_name}"
}

data "aws_route53_zone" "ih" {
  name         = var.zone_name
  private_zone = false
}

data "aws_lb_hosted_zone_id" "nlb" {
  load_balancer_type = "network"
}

# the NLB belongs to Kubernetes, so its name comes in as a variable
resource "aws_route53_record" "app" {
  zone_id = data.aws_route53_zone.ih.zone_id
  name    = local.fqdn
  type    = "A"

  alias {
    name                   = var.gateway_hostname
    zone_id                = data.aws_lb_hosted_zone_id.nlb.id
    evaluate_target_health = false
  }
}
