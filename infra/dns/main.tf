# Long-lived zone: project records (vote.p2, result.p2) live in other roots.
resource "aws_route53_zone" "ih" {
  name    = var.zone_name
  comment = "rg-dns: delegated from DreamHost (rolan.dog)"

  lifecycle {
    prevent_destroy = true
  }
}
