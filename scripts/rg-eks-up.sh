#!/usr/bin/env bash
# rg-eks-up.sh --- plan (default) or apply infra/eks for project 2
set -euo pipefail; set -C
PROG=rg-eks-up.sh
# shellcheck disable=SC2034  # read by version() in lib.sh
VERSION=0.1.0
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
. "$here/lib.sh"

usage() {
  cat <<USAGE
Usage: $PROG [--apply] [--help] [--version]
Plan (default) or apply infra/eks: VPC, EKS cluster, node group, add-ons.
  --apply    apply the saved plan after a successful plan
  --help     show this help and exit
  --version  show the version and exit
USAGE
}

apply=0
for arg in "$@"; do
  case $arg in
    --apply) apply=1 ;;
    --help) usage; exit 0 ;;
    --version) version; exit 0 ;;
    *) usage >&2; die "unknown option: $arg" ;;
  esac
done

for t in aws tofu jq kubectl; do
  command -v "$t" >/dev/null 2>&1 || die "missing tool: $t"
done

region=eu-central-1
acct=$(aws sts get-caller-identity --query Account --output text)
bucket="tf-state-${acct}-eu-central-1"
aws s3api head-bucket --bucket "$bucket" 2>/dev/null || die "state bucket $bucket not found"

# restrict the public API endpoint to this host's egress IP; override with TF_VAR_api_allowed_cidrs
if [[ -z ${TF_VAR_api_allowed_cidrs:-} ]]; then
  myip=$(curl -4 -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]') \
    || die "cannot detect the egress ip"
  [[ $myip =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die "unexpected ip answer: $myip"
  export TF_VAR_api_allowed_cidrs="[\"$myip/32\"]"
fi
echo "api allowed cidrs: $TF_VAR_api_allowed_cidrs"

cd "$here/../infra/eks"
tofu init -input=false -backend-config="bucket=${bucket}"
tofu validate

# one source of truth for the cluster name: the variable default
name=$(echo 'var.name' | tofu console | tr -d '"')
[ -n "$name" ] || die "could not read var.name"

# compare AWS with state before touching anything (resumed or failed runs)
state_list=$(tofu state list 2>/dev/null || true)
in_state=$(grep -c 'aws_eks_cluster' <<<"$state_list" || true)
if aws eks describe-cluster --name "$name" --region "$region" >/dev/null 2>&1 && [ "$in_state" -eq 0 ]; then
  aws eks list-pod-identity-associations --cluster-name "$name" --region "$region" --output table || true
  die "cluster $name exists in aws but not in state: tofu import it or delete it first"
fi
if aws iam get-role --role-name rg-p2-ebs-csi >/dev/null 2>&1 \
   && ! grep -q 'aws_iam_role.ebs_csi' <<<"$state_list"; then
  die "role rg-p2-ebs-csi exists in aws but not in state: tofu import aws_iam_role.ebs_csi rg-p2-ebs-csi"
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/rg-eks.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT
tofu plan -input=false -out="$tmp/plan"

if [ "$apply" -eq 0 ]; then
  echo 'plan only; re-run with --apply to create or update'
  exit 0
fi

banner 'apply'
tofu apply -input=false "$tmp/plan"

# separate kubeconfig so the minikube context is never touched
kc="$HOME/.kube/rg-p2.config"
aws eks update-kubeconfig --name "$name" --region "$region" --kubeconfig "$kc"

# nodes join after the apply returns: retry
ready=0
for _ in $(seq 1 30); do
  ready=$(KUBECONFIG="$kc" kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready' || true)
  [ "$ready" -ge 2 ] && break
  sleep 10
done
[ "$ready" -ge 2 ] || die "fewer than 2 nodes Ready after 5 minutes"
KUBECONFIG="$kc" kubectl get nodes -L kubernetes.io/arch,node.kubernetes.io/instance-type

for a in vpc-cni kube-proxy coredns aws-ebs-csi-driver eks-pod-identity-agent; do
  st=$(aws eks describe-addon --cluster-name "$name" --region "$region" --addon-name "$a" \
        --query addon.status --output text)
  printf '%-24s %s\n' "$a" "$st"
  [ "$st" = ACTIVE ] || die "add-on $a is $st"
done
echo "kubeconfig: export KUBECONFIG=$kc"
