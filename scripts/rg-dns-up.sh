#!/usr/bin/env bash
# rg-dns-up.sh --- plan, or with --apply create/adopt the Route 53 zone.
# The zone is never destroyed here: prevent_destroy blocks it and no teardown calls this root.
set -euo pipefail; set -C

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# banner() comes from lib.sh when present; lib.sh API is otherwise not assumed
if [[ -r $ROOT/scripts/lib.sh ]]; then . "$ROOT/scripts/lib.sh"; fi
declare -F banner >/dev/null || banner() { printf '=== %s ===\n' "$*"; }

readonly DNS_VERSION=0.1.0
readonly PROG=${0##*/}
readonly DNS_DIR=$ROOT/infra/dns
readonly ZONE_NAME=ih.rolan.dog   # keep equal to the zone_name default in variables.tf

usage() {
  cat <<USAGE
Usage: $PROG [--apply] [--help] [--version]
Plan (default, no changes) or apply the public Route 53 zone $ZONE_NAME.
An existing zone that is missing from state is imported, never duplicated.
USAGE
}
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
tf() { tofu -chdir="$DNS_DIR" "$@"; }

apply=false
for arg in "$@"; do
  case $arg in
    --apply) apply=true ;;
    --help) usage; exit 0 ;;
    --version) echo "$PROG $DNS_VERSION"; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

for cmd in aws tofu jq dig; do
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

# look for an existing public zone first: Route 53 allows duplicates by name
json=$(aws route53 list-hosted-zones-by-name --dns-name "$ZONE_NAME" --output json)
mapfile -t ids < <(jq -r --arg n "$ZONE_NAME." \
  '.HostedZones[] | select(.Name == $n and (.Config.PrivateZone | not)) | .Id' <<<"$json")
(( ${#ids[@]} <= 1 )) || die "several public zones named $ZONE_NAME: ${ids[*]}; keep one, report the others"

in_state=$(tf state list 2>/dev/null || true)
if ! grep -qx 'aws_route53_zone.ih' <<<"$in_state" && (( ${#ids[@]} == 1 )); then
  if $apply; then
    echo "zone exists in AWS but not in state: importing ${ids[0]##*/}"
    tf import -input=false aws_route53_zone.ih "${ids[0]##*/}"
  else
    echo "zone ${ids[0]##*/} exists but is not in state; re-run with --apply to import it"
    exit 0
  fi
fi

tf plan -input=false -out="$tmp/dns.plan"
if ! $apply; then
  echo "plan only; re-run with --apply to create or update"
  exit 0
fi
tf apply -input=false "$tmp/dns.plan"

# verify: state, AWS API and the live authoritative answer must agree
mapfile -t want < <(tf output -json name_servers | jq -r '.[]' | sort)
(( ${#want[@]} == 4 )) || die "expected 4 name servers, got ${#want[@]}"
zone_id=$(tf output -raw zone_id)
mapfile -t have < <(aws route53 get-hosted-zone --id "$zone_id" \
  --query 'DelegationSet.NameServers' --output json | jq -r '.[]' | sort)
[[ "${want[*]}" == "${have[*]}" ]] || die "state and AWS disagree on name servers"

ok=false
for _ in {1..12}; do   # a new zone can take a short while to answer
  mapfile -t got < <(dig +short NS "$ZONE_NAME" @"${want[0]}" | sed 's/\.$//' | sort)
  if [[ "${got[*]}" == "${want[*]}" ]]; then ok=true; break; fi
  sleep 5
done
$ok || die "zone not answering on ${want[0]} after 60 s; re-run the dig test later"

printf '\nDreamHost: Name %s, Type NS, one record per value (no trailing dot):\n' "${ZONE_NAME%%.*}"
printf '%s\n' "${want[@]}"
banner "Route 53 zone ready!"
