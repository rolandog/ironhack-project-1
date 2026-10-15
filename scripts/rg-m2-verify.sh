#!/usr/bin/env bash
# rg-m2-verify.sh -- show the M2 resources with the AWS CLI
set -euo pipefail
set -C

readonly PROGRAM=${0##*/}
readonly VERSION=1.0

usage() {
  cat <<EOF
Usage: $PROGRAM [OPTION]...
Print tables for the VPC, subnets, NAT gateway, instances, security group
rules and the remote state (uses the default AWS region).

  --help     display this help and exit
  --version  output version information and exit
EOF
}

for arg; do
  case $arg in
    --help)    usage; exit 0 ;;
    --version) printf '%s %s\n' "$PROGRAM" "$VERSION"; exit 0 ;;
    *)         usage >&2; printf "%s: error: unrecognized option '%s'\n" "$PROGRAM" "$arg" >&2; exit 1 ;;
  esac
done

command -v aws >/dev/null || { printf '%s: error: aws not found\n' "$PROGRAM" >&2; exit 1; }
region=$(aws configure get region || true)
region=${region:-eu-central-1}
account=$(aws sts get-caller-identity --query Account --output text)
tagged() { printf 'Name=tag:Name,Values=%s' "$1"; }

printf '\n== AMI used by the instances ==\n'
aws ec2 describe-images --owners 136693071363 \
  --filters 'Name=name,Values=debian-13-arm64-*' 'Name=architecture,Values=arm64' \
  --query 'reverse(sort_by(Images, &CreationDate))[:3].[CreationDate,Name,ImageId]' --output table

printf '\n== VPC and subnets ==\n'
aws ec2 describe-vpcs --filters "$(tagged rg-vpc)" \
  --query 'Vpcs[].[VpcId,CidrBlock,State]' --output table
aws ec2 describe-subnets --filters 'Name=tag:Name,Values=rg-*' \
  --query 'Subnets[].[Tags[?Key==`Name`]|[0].Value,CidrBlock,AvailabilityZone,MapPublicIpOnLaunch]' --output table

printf '\n== NAT gateway ==\n'
aws ec2 describe-nat-gateways --filter "$(tagged rg-nat)" \
  --query 'NatGateways[].[NatGatewayId,State,SubnetId]' --output table

printf '\n== Instances ==\n'
aws ec2 describe-instances \
  --filters 'Name=tag:Name,Values=rg-vm*' 'Name=instance-state-name,Values=pending,running' \
  --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value,InstanceType,Architecture,State.Name,PrivateIpAddress,PublicIpAddress,MetadataOptions.HttpTokens]' \
  --output table

for sg in frontend backend db; do
  printf '\n== Security group rg-sg-%s ==\n' "$sg"
  id=$(aws ec2 describe-security-groups --filters "Name=group-name,Values=rg-sg-$sg" \
    --query 'SecurityGroups[0].GroupId' --output text)
  aws ec2 describe-security-group-rules --filters "Name=group-id,Values=$id" \
    --query 'SecurityGroupRules[].[IsEgress,IpProtocol,FromPort,ToPort,CidrIpv4,ReferencedGroupInfo.GroupId]' \
    --output table
done

printf '\n== Remote state ==\n'
aws s3 ls "s3://tf-state-$account-$region/" --recursive
