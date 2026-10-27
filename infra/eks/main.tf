data "aws_availability_zones" "available" {
  # checkov:skip=CKV_AWS_394:two AZs are sliced on purpose and the opt-in filter excludes local zones
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# fail at plan time if the instance type and the AMI architecture disagree
data "aws_ec2_instance_type" "node" {
  instance_type = var.node_instance_type

  lifecycle {
    postcondition {
      condition     = contains(self.supported_architectures, var.node_arch)
      error_message = "${var.node_instance_type} does not support ${var.node_arch}"
    }
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  ami_types = {
    arm64  = "AL2023_ARM_64_STANDARD"
    x86_64 = "AL2023_x86_64_STANDARD"
  }
}

module "vpc" {
  # checkov:skip=CKV_TF_1:registry module pinned by version constraint, providers pinned by lock file
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = var.name
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = [for k in range(length(local.azs)) : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k in range(length(local.azs)) : cidrsubnet(var.vpc_cidr, 8, 200 + k)]

  # one shared NAT gateway: cheaper, but a single AZ failure would cut egress
  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# EBS CSI controller credentials through EKS Pod Identity
data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "rg-p2-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

module "eks" {
  # checkov:skip=CKV_TF_1:registry module pinned by version constraint, providers pinned by lock file
  source            = "terraform-aws-modules/eks/aws"
  enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  version           = "~> 21.0"

  name               = var.name
  kubernetes_version = var.kubernetes_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.api_allowed_cidrs

  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true
  enable_irsa                              = false

  addons = {
    eks-pod-identity-agent = {
      addon_version  = var.addon_versions["eks-pod-identity-agent"]
      most_recent    = false
      preserve       = false
      before_compute = true
    }
    vpc-cni = {
      addon_version  = var.addon_versions["vpc-cni"]
      most_recent    = false
      preserve       = false
      before_compute = true
    }
    kube-proxy = {
      addon_version = var.addon_versions["kube-proxy"]
      most_recent   = false
      preserve      = false
    }
    coredns = {
      addon_version = var.addon_versions["coredns"]
      most_recent   = false
      preserve      = false
    }
    aws-ebs-csi-driver = {
      addon_version = var.addon_versions["aws-ebs-csi-driver"]
      most_recent   = false
      preserve      = false

      pod_identity_association = [
        {
          role_arn        = aws_iam_role.ebs_csi.arn
          service_account = "ebs-csi-controller-sa"
        },
      ]
    }
  }

  eks_managed_node_groups = {
    main = {
      ami_type       = local.ami_types[var.node_arch]
      instance_types = [var.node_instance_type]
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size

      metadata_options = {
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }
    }
  }
}
