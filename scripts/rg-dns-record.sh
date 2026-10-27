#!/usr/bin/env bash
# rg-dns-record.sh --- plan (default), --apply or --destroy the alias app.p2.ih.rolan.dog.
# The zone lives in infra/dns and is never touched here.
set -euo pipefail; set -C

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ -r $ROOT/scripts/lib.sh ]]; then . "$ROOT/scripts/lib.sh"; fi
declare -F banner >/dev/null || banner() { printf '=== %s ===\n' "$*"; }

readonly REC_VERSION=0.1.0
readonly PROG=${0##*/}
readonly REC_DIR=$ROOT/infra/app-dns
readonly KC=${KUBECONFIG:-$HOME/.kube/rg-p2.config}
readonly ZONE_NAME=ih.rolan.dog   # keep equal to the defaults in infra/app-dns/variables.tf
readonly FQDN=app.p2.$ZONE_NAME

usage() {
  cat <<USAGE
Usage: $PROG [--apply | --destroy] [--help] [--version]
Plan (default, no changes), create, or remove the alias record $FQDN.
The target is the address of Gateway rg-gw in namespace rg-app (uses KUBECONFIG,
default ~/.kube/rg-p2.config); override with TF_VAR_gateway_hostname.
USAGE
}
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
tf() { tofu -chdir="$REC_DIR" "$@"; }

mode=plan
for arg in "$@"; do
  case $arg in
    --apply) mode=apply ;;
    --destroy) mode=destroy ;;
    --help) usage; exit 0 ;;
    --version) echo "$PROG $REC_VERSION"; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

for cmd in aws tofu jq dig curl kubectl; do
  command -v "$cmd" >/dev/null || die "missing command: $cmd"
done

account=$(aws sts get-caller-identity --query Account --output text)
bucket=tf-state-$account-eu-central-1
aws s3api head-bucket --bucket "$bucket" >/dev/null 2>&1 \
  || die "shared state bucket missing or not accessible; run infra/bootstrap first"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

tf init -input=false -backend-config="bucket=$bucket"
tf validate

host=${TF_VAR_gateway_hostname:-}
if [[ $mode == destroy ]]; then
  # destroy still validates variables; the value is not used to find the record
  host=placeholder.elb.eu-central-1.amazonaws.com
elif [[ -z $host ]]; then
  for _ in {1..30}; do
    host=$(KUBECONFIG=$KC kubectl -n rg-app get gateway rg-gw \
      -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || true)
    [[ -n $host ]] && break
    sleep 10
  done
  [[ -n $host ]] || die "gateway rg-gw has no address after 300 s"
fi
export TF_VAR_gateway_hostname=$host
echo "gateway hostname: $host"

if [[ $mode == apply ]]; then
  st=none
  for _ in {1..30}; do
    st=$(aws elbv2 describe-load-balancers \
      --query "LoadBalancers[?DNSName=='$host'].State.Code | [0]" --output text 2>/dev/null || true)
    [[ $st == active ]] && break
    sleep 10
  done
  [[ $st == active ]] || die "load balancer $host is not active (state: $st)"
fi

if [[ $mode == destroy ]]; then
  tf plan -destroy -input=false -out="$tmp/rec.plan"
else
  tf plan -input=false -out="$tmp/rec.plan"
fi
if [[ $mode == plan ]]; then
  echo "plan only; re-run with --apply to create or update"
  exit 0
fi
tf apply -input=false "$tmp/rec.plan"

zone_id=$(aws route53 list-hosted-zones-by-name --dns-name "$ZONE_NAME" \
  --query "HostedZones[?Name=='$ZONE_NAME.' && !(Config.PrivateZone)].Id | [0]" --output text)
[[ $zone_id != None ]] || die "public zone $ZONE_NAME not found"
zone_id=${zone_id##*/}

if [[ $mode == destroy ]]; then
  left=$(aws route53 list-resource-record-sets --hosted-zone-id "$zone_id" \
    --query "ResourceRecordSets[?Name=='$FQDN.'].Type" --output text)
  [[ -z $left ]] || die "record still present: $left"
  banner "record $FQDN removed"
  exit 0
fi

# verify against the authoritative server first, so resolver caches cannot mislead
ns=$(aws route53 get-hosted-zone --id "$zone_id" --query 'DelegationSet.NameServers[0]' --output text)
ips=()
for _ in {1..12}; do
  mapfile -t ips < <(dig +short A "$FQDN" @"$ns")
  (( ${#ips[@]} > 0 )) && break
  sleep 5
done
(( ${#ips[@]} > 0 )) || die "$FQDN does not answer on $ns after 60 s"
echo "authoritative answers on $ns: ${ips[*]}"

# an NLB zone without a healthy target drops out of DNS: test every address, not the first
for ip in "${ips[@]}"; do
  code=000
  for _ in {1..18}; do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
      --resolve "$FQDN:80:$ip" "http://$FQDN/vote/" 2>/dev/null || true)
    [[ $code == 200 ]] && break
    sleep 10
  done
  echo "http://$FQDN/vote/ via $ip: $code"
  [[ $code == 200 ]] || die "expected 200 from /vote/ via $ip, got $code"
done
banner "record $FQDN ready"
