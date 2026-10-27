#!/usr/bin/env bash
# rg-demo.sh -- read-only status screen for the project 2 demo, sized for 132x43
set -euo pipefail
set -C

readonly PROGRAM=${0##*/}
readonly VERSION=1.0
host=${RG_APP_HOST:-app.p2.ih.rolan.dog}
cluster=${RG_CLUSTER:-eks-rolando-p2}
namespace=${RG_NAMESPACE:-rg-app}
region=${AWS_REGION:-eu-central-1}
repo=${RG_REPO:-rolandog/ironhack-project-1}
step=no

usage() {
  cat <<USAGE
Usage: $PROGRAM [OPTION]...
Print a read-only status screen: nodes, workloads, image pins, HTTP checks,
newest ECR tags, API allow-list size and the latest CI runs. Changes nothing.

  --step      wait for Enter before each section
  --help      display this help and exit
  --version   output version information and exit

Environment: RG_APP_HOST, RG_CLUSTER, RG_NAMESPACE, RG_REPO, AWS_REGION, KUBECONFIG
USAGE
}

die() { printf '%s: error: %s\n' "$PROGRAM" "$*" >&2; exit 1; }

for arg; do
  case $arg in
    --help)    usage; exit 0 ;;
    --version) printf '%s %s\n' "$PROGRAM" "$VERSION"; exit 0 ;;
    --step)    step=yes ;;
    *)         usage >&2; die "unrecognized option '$arg'" ;;
  esac
done

for tool in kubectl aws curl jq sed; do
  command -v "$tool" >/dev/null || die "$tool not found"
done
export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/rg-p2.config}
export AWS_PAGER=''

section() {
  [[ $step == no ]] || read -rp '[enter] ' _
  printf '\n== %s ==\n' "$*"
}

# why: one failing check must not end the demo; show it and carry on
try() { "$@" || printf '(failed: %s)\n' "$1"; }

# why: full digests do not fit on screen; 12 characters are enough to compare
short() { sed -E 's/@sha256:([0-9a-f]{12})[0-9a-f]+/@\1../'; }

section "nodes of $cluster"
try kubectl get nodes -L kubernetes.io/arch,node.kubernetes.io/instance-type |
  sed 's/\.eu-central-1\.compute\.internal//'

section "pods in $namespace"
try kubectl -n "$namespace" get pods

section "images in $namespace (tag@digest)"
try kubectl -n "$namespace" get deployments,statefulsets \
  -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,IMAGE:.spec.template.spec.containers[0].image' |
  short

section "http through the NLB"
for path in /vote/ /result/; do
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://$host$path" || true)
  printf '%s%s -> %s\n' "$host" "$path" "$code"
done

section "newest tagged image per ECR repository"
for r in vote result worker; do
  tag=$(aws ecr describe-images --region "$region" --repository-name "rg-p2-$r" \
    --query 'sort_by(imageDetails[?imageTags!=null],&imagePushedAt)[-1].imageTags[0]' \
    --output text 2>/dev/null || echo '?')
  printf 'rg-p2-%s: %s\n' "$r" "$tag"
done

section "API allow-list"
n=$(aws eks describe-cluster --region "$region" --name "$cluster" \
  --query 'length(cluster.resourcesVpcConfig.publicAccessCidrs)' --output text 2>/dev/null || echo '?')
printf 'entries: %s\n' "$n"

section "latest CI runs ($repo)"
{
  curl -fsS "https://api.github.com/repos/$repo/actions/runs?per_page=3" |
    jq -r '.workflow_runs[] | [.name, .head_branch, .status, (.conclusion // "-")] | @tsv'
} || printf '(failed: github api)\n'
