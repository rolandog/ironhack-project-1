data "aws_caller_identity" "current" {}

locals {
  bucket = "tf-state-${data.aws_caller_identity.current.account_id}-${var.region}"

  backend_hcl = <<-EOT
    bucket       = "${aws_s3_bucket.state.bucket}"
    key          = "${var.state_key}"
    region       = "${var.region}"
    encrypt      = true
    use_lockfile = true
  EOT
}

resource "aws_s3_bucket" "state" {
  bucket = local.bucket

  # why: losing this bucket loses the state of every stack
  lifecycle { prevent_destroy = true }

  # checkov:skip=CKV_AWS_18:access logging needs a second bucket; not worth it for a lab
  # checkov:skip=CKV_AWS_144:cross-region replication is out of scope for a single-region lab
  # checkov:skip=CKV2_AWS_62:no consumers for bucket events
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "aws:kms" }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# why: versioning keeps every state revision; expire old ones
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    id     = "rg-expire-old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration { noncurrent_days = 90 }
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}

# why: a backend block cannot reference resources, so generate the
# partial-configuration file that `tofu init -backend-config=` reads
resource "local_file" "backend_config" {
  filename        = "${path.module}/../infra/backend.hcl"
  file_permission = "0600"
  content         = local.backend_hcl
}

# why: the real file is gitignored; this one is committed for fresh clones
resource "local_file" "backend_config_example" {
  filename        = "${path.module}/../infra/backend.hcl.example"
  file_permission = "0644"
  content         = replace(local.backend_hcl, data.aws_caller_identity.current.account_id, "<ACCOUNT_ID>")
}
