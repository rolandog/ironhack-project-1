#!/usr/bin/env bash
# rg-down.sh --- project 2 teardown: DNS record, Gateway and its NLB, app namespace and volumes, then infra/eks.
# Default is a read-only inventory plus a destroy plan; --apply performs the teardown.
# Kubernetes must delete its own load balancers and volumes first: leftovers keep ENIs
# in the subnets and tofu then cannot delete the VPC.
set -euo pipefail; set -C

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=lib.sh
if [[ -r $ROOT/scripts/lib.sh ]]; then . "$ROOT/scripts/lib.sh"; fi
declare -F banner >/dev/null || banner() { printf '=== %s ===\n' "$*"; }

readonly DOWN_VERSION=0.1.0
readonly PROG=${0##*/}
readonly EKS_DIR=$ROOT/infra/eks
readonly KC=${KUBECONFIG:-$HOME/.kube/rg-p2.config}
readonly APP_NS=rg-app

usage() {
  cat <<USAGE
Usage: $PROG [--apply] [--help] [--version]
Inventory (default, read-only) or tear down project 2: the DNS record, Gateway rg-gw and
its load balancer, namespace $APP_NS and its volumes, then infra/eks. The zone stays.
Uses KUBECONFIG, default ~/.kube/rg-p2.config. Safe to re-run.
USAGE
}
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
step() { printf '\n== %s ==\n' "$*"; }
tf() { tofu -chdir="$EKS_DIR" "$@"; }
kc() { KUBECONFIG=$KC kubectl "$@"; }

apply=false
for arg in "$@"; do
  case $arg in
    --apply) apply=true ;;
    --help) usage; exit 0 ;;
    --version) echo "$PROG $DOWN_VERSION"; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

for cmd in aws tofu kubectl jq curl; do
  command -v "$cmd" >/dev/null || die "missing command: $cmd"
done

account=$(aws sts get-caller-identity --query Account --output text)
bucket=tf-state-$account-eu-central-1
aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1 \
  || die "shared state bucket missing or not accessible"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

tf init -input=false -backend-config="bucket=$bucket" >/dev/null

cluster=$(tf output -raw cluster_name 2>/dev/null || true)
: "${cluster:=eks-rolando-p2}"   # keep equal to the default in infra/eks/variables.tf
vpc=$(tf output -raw vpc_id 2>/dev/null || true)
if [[ -z $vpc ]]; then
  # state already empty or outputs gone: find the VPC by name so leftovers are still reported
  vpc=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$cluster" \
    --query 'Vpcs[0].VpcId' --output text)
  [[ $vpc != None ]] || vpc=''
fi

lb_services() {
  kc get svc -A -o json \
    | jq -r '.items[] | select(.spec.type == "LoadBalancer") | .metadata.namespace + "/" + .metadata.name'
}
pvs() { kc get pv -o name; }
vpc_lbs() {
  [[ -n $vpc ]] || return 0
  aws elbv2 describe-load-balancers \
    --query "LoadBalancers[?VpcId=='$vpc'].LoadBalancerName" --output text | tr '\t' '\n'
  aws elb describe-load-balancers \
    --query "LoadBalancerDescriptions[?VPCId=='$vpc'].LoadBalancerName" --output text | tr '\t' '\n'
}
pvc_volumes() {
  aws ec2 describe-volumes \
    --filters "Name=tag:kubernetes.io/created-for/pvc/namespace,Values=$APP_NS" \
    --query 'Volumes[].VolumeId' --output text | tr '\t' '\n'
}
cluster_volumes() {
  aws ec2 describe-volumes \
    --filters "Name=tag:kubernetes.io/cluster/$cluster,Values=owned" \
    --query 'Volumes[].VolumeId' --output text | tr '\t' '\n'
}

# wait_empty TRIES WHAT CMD...: CMD prints nothing once the condition holds (10 s per try)
wait_empty() {
  local tries=$1 what=$2 i out; shift 2
  for ((i = 0; i < tries; i++)); do
    out=$("$@")
    if [[ -z $out ]]; then echo "ok: no $what left"; return 0; fi
    echo "waiting for $what: ${out//$'\n'/ }"
    sleep 10
  done
  die "$what still present after $((tries * 10)) s: ${out//$'\n'/ }"
}

# a silent skip here would orphan the NLB, so an unreachable API is fatal
cluster_up=false
if aws eks describe-cluster --name "$cluster" --query cluster.status --output text >/dev/null 2>&1; then
  cluster_up=true
  kc --request-timeout=10s get --raw /readyz >/dev/null 2>&1 \
    || die "cluster $cluster exists but its API is unreachable; compare your IP (curl -s https://checkip.amazonaws.com) with api_allowed_cidrs, or refresh the kubeconfig"
fi

# destroy ignores the value, but the variable must be set
if [[ -z ${TF_VAR_api_allowed_cidrs:-} ]]; then
  ip=$(curl -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')
  [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "cannot determine the egress IP"
  export TF_VAR_api_allowed_cidrs="[\"$ip/32\"]"
fi

if ! $apply; then
  step "inventory (read-only)"
  echo "cluster=$cluster up=$cluster_up vpc=${vpc:-none} state_resources=$(tf state list | wc -l)"
  if $cluster_up; then
    echo "-- LoadBalancer services"; lb_services
    echo "-- persistent volumes"; pvs
  fi
  echo "-- load balancers in the VPC"; vpc_lbs
  echo "-- EBS volumes created for $APP_NS"; pvc_volumes
  step "destroy plan (read-only)"
  tf plan -destroy -input=false | tail -n 6
  echo "dry run only; re-run with --apply to tear down"
  exit 0
fi

if $cluster_up; then
  step "dns record"
  "$ROOT/scripts/rg-dns-record.sh" --destroy

  step "gateway and load balancer"
  kc -n "$APP_NS" delete gateway rg-gw --ignore-not-found --wait=true --timeout=300s
  wait_empty 36 'LoadBalancer services' lb_services
  wait_empty 36 'load balancers in the VPC' vpc_lbs

  step "namespace and volumes"
  kc delete namespace "$APP_NS" --ignore-not-found --wait=true --timeout=300s
  wait_empty 36 'persistent volumes' pvs
  wait_empty 36 'EBS volumes created for the app' pvc_volumes
else
  echo "cluster $cluster not found: skipping the Kubernetes steps"
  wait_empty 1 'load balancers in the VPC' vpc_lbs
fi

step "tofu destroy"
tf plan -destroy -input=false -out="$tmp/down.plan"
tf apply -input=false "$tmp/down.plan"

step "verify"
n=$(tf state list | wc -l)
(( n == 0 )) || die "state still lists $n resources"
if [[ -n $vpc ]]; then
  v=$(aws ec2 describe-vpcs --filters "Name=vpc-id,Values=$vpc" --query 'length(Vpcs)' --output text)
  [[ $v == 0 ]] || die "vpc $vpc still exists"
  nat=$(aws ec2 describe-nat-gateways \
    --filter "Name=vpc-id,Values=$vpc" "Name=state,Values=pending,available" \
    --query 'length(NatGateways)' --output text)
  [[ $nat == 0 ]] || die "$nat nat gateways still active in $vpc"
fi
c=$(aws eks list-clusters --query "length(clusters[?@=='$cluster'])" --output text)
[[ $c == 0 ]] || die "cluster $cluster still listed"
left=$(cluster_volumes)
[[ -z $left ]] || die "volumes tagged for $cluster remain: ${left//$'\n'/ }"
eips=$(aws ec2 describe-addresses --filters Name=tag:Namespace,Values=rg --query 'length(Addresses)' --output text)
[[ $eips == 0 ]] || die "$eips elastic ips tagged Namespace=rg remain"
echo "state empty, vpc gone, no nat gateway, no cluster, no tagged volumes, no elastic ips"
banner "project 2 torn down"
