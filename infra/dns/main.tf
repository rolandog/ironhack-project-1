# Long-lived zone: project records (app.p2) live in infra/app-dns.
resource "aws_route53_zone" "ih" {
  name    = var.zone_name
  comment = "rg-dns: delegated from DreamHost (rolan.dog)"

  lifecycle {
    prevent_destroy = true
  }
}
