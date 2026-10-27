output "registry" {
  value = local.registry
}

output "repositories" {
  value = { for k, r in aws_ecr_repository.app : k => r.repository_url }
}

output "push_role_arn" {
  value = aws_iam_role.push.arn
}

output "deploy_role_arn" {
  value = aws_iam_role.deploy.arn
}
