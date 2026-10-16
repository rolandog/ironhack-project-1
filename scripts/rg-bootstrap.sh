#!/usr/bin/env bash
# rg-bootstrap.sh -- create lab prerequisites: key pair, state bucket, tf inputs
set -euo pipefail
set -C

readonly PROGRAM=${0##*/}
readonly VERSION=1.0
REGION=${AWS_DEFAULT_REGION:-eu-central-1}
KEY_NAME=rg-keypair
KEY_PATH=$HOME/.ssh/$KEY_NAME
TF_DIR=infra
tmpdir=

usage() {
  cat <<EOF
Usage: $PROGRAM [OPTION]...
Create the Ed25519 key pair, the S3 state bucket and the Terraform inputs.

  --tf-dir=DIR   Terraform directory (default: $TF_DIR)
  --help         display this help and exit
  --version      output version information and exit
EOF
}

die() { printf '%s: error: %s\n' "$PROGRAM" "$*" >&2; exit 1; }

cleanup() { if [[ -n $tmpdir ]]; then rm -rf -- "$tmpdir"; fi; }
trap cleanup EXIT

for arg; do
  case $arg in
    --help)     usage; exit 0 ;;
    --version)  printf '%s %s\n' "$PROGRAM" "$VERSION"; exit 0 ;;
    --tf-dir=*) TF_DIR=${arg#*=} ;;
    *)          usage >&2; die "unrecognized option '$arg'" ;;
  esac
done

for cmd in aws ssh-keygen curl; do
  command -v "$cmd" >/dev/null || die "$cmd not found"
done

account_id=$(aws sts get-caller-identity --query Account --output text) \
  || die "cannot get caller identity"
bucket="tf-state-${account_id}-${REGION}"

# Ed25519 key, empty passphrase: ephemeral lab only
if [[ ! -e $KEY_PATH ]]; then
  mkdir -p -m 700 "${KEY_PATH%/*}"
  ssh-keygen -t ed25519 -N '' -C "$KEY_NAME" -f "$KEY_PATH"
fi
if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
  aws ec2 import-key-pair --key-name "$KEY_NAME" \
    --public-key-material "fileb://${KEY_PATH}.pub" --output table
fi

# Versioning lets you recover a corrupted state file
if ! aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
  aws s3api create-bucket --bucket "$bucket" --region "$REGION" \
    --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
fi
aws s3api put-bucket-versioning --bucket "$bucket" \
  --versioning-configuration Status=Enabled
aws s3api put-public-access-block --bucket "$bucket" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# Backend blocks cannot use variables, so the bucket goes in a partial config
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/${PROGRAM}.XXXXXX")
my_ip=$(curl -fsS https://checkip.amazonaws.com) || die "cannot detect public ip"
my_ip=${my_ip//[[:space:]]/}
cat << EOF > "$tmpdir/backend.hcl"
bucket       = "$bucket"
key          = "ironhack-project-1/terraform.tfstate"
region       = "eu-central-1"
encrypt      = true
use_lockfile = true
EOF
printf 'admin_cidr = "%s/32"\n' "$my_ip" >"$tmpdir/terraform.tfvars"
mkdir -p "$TF_DIR"
mv -f "$tmpdir/backend.hcl" "$tmpdir/terraform.tfvars" "$TF_DIR/"

printf '%s: bucket=%s key=%s admin_cidr=%s/32\n' \
  "$PROGRAM" "$bucket" "$KEY_NAME" "$my_ip"
