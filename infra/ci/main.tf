data "aws_caller_identity" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  registry    = "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com"
  cluster_arn = "arn:aws:eks:${var.region}:${local.account_id}:cluster/${var.cluster_name}"
  repo_names  = { for i in var.images : i => "rg-p2-${i}" }
  push_subs   = [for b in var.push_branches : "${var.github_subject_repo}:ref:refs/heads/${b}"]
  deploy_subs = [for b in var.deploy_branches : "${var.github_subject_repo}:ref:refs/heads/${b}"]
  oidc_arn    = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

# one provider per URL per account: create it only when the pre-check found none
resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1

  url = "https://token.actions.githubusercontent.com"
}

resource "aws_ecr_repository" "app" {
  # checkov:skip=CKV_AWS_136: AES256 is enough for public application images; a CMK adds a monthly fee and a 30-day deletion wait
  for_each = local.repo_names

  name                 = each.value
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  for_each = aws_ecr_repository.app

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "keep the last ${var.keep_images} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.keep_images
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

data "aws_iam_policy_document" "trust_push" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.push_subs
    }
  }
}

data "aws_iam_policy_document" "trust_deploy" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.deploy_subs
    }
  }
}

resource "aws_iam_role" "push" {
  name                 = "rg-p2-ci-push"
  assume_role_policy   = data.aws_iam_policy_document.trust_push.json
  max_session_duration = 3600
}

resource "aws_iam_role" "deploy" {
  name                 = "rg-p2-ci-deploy"
  assume_role_policy   = data.aws_iam_policy_document.trust_deploy.json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "push" {
  # the authorization token call cannot be scoped to a repository
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPushOwnRepos"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [for r in aws_ecr_repository.app : r.arn]
  }
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "ClusterDescribeAndAllowList"
    actions   = ["eks:DescribeCluster", "eks:UpdateClusterConfig"]
    resources = [local.cluster_arn]
  }

  statement {
    sid       = "ResolveDigests"
    actions   = ["ecr:DescribeImages"]
    resources = [for r in aws_ecr_repository.app : r.arn]
  }
}

resource "aws_iam_role_policy" "push" {
  name   = "rg-p2-ci-push"
  role   = aws_iam_role.push.id
  policy = data.aws_iam_policy_document.push.json
}

resource "aws_iam_role_policy" "deploy" {
  name   = "rg-p2-ci-deploy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}
