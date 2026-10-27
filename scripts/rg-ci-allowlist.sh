#!/usr/bin/env bash
# rg-ci-allowlist.sh -- add this host's /32 to the EKS API allow-list, later restore the original
set -euo pipefail
set -C

readonly PROGRAM=${0##*/}
readonly VERSION=1.0
cluster=${RG_CLUSTER:-eks-rolando-p2}
region=${AWS_REGION:-eu-central-1}
timeout=900
action=
state=${RG_ALLOWLIST_STATE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/rg-allowlist.json}

usage() {
  cat <<USAGE
Usage: $PROGRAM [OPTION]... open|restore
open     save the current API allow-list, then add this host's public IPv4 /32
restore  put the saved list back (does nothing when nothing was saved)
Both wait until the cluster is ACTIVE with the wanted list. The list is saved
before any change, so restore also works after a half-finished open.

  --cluster=NAME   EKS cluster (default: $cluster)
  --region=NAME    AWS region (default: $region)
  --timeout=SEC    wait limit (default: $timeout)
  --help           display this help and exit
  --version        output version information and exit
USAGE
}

die() { printf '%s: error: %s\n' "$PROGRAM" "$*" >&2; exit 1; }
log() { printf '%s: %s\n' "$PROGRAM" "$*" >&2; }

for arg; do
  case $arg in
    --help)      usage; exit 0 ;;
    --version)   printf '%s %s\n' "$PROGRAM" "$VERSION"; exit 0 ;;
    --cluster=*) cluster=${arg#*=} ;;
    --region=*)  region=${arg#*=} ;;
    --timeout=*) timeout=${arg#*=} ;;
    open|restore) action=$arg ;;
    *)           usage >&2; die "unrecognized argument '$arg'" ;;
  esac
done
[[ -n $action ]] || { usage >&2; die "need open or restore"; }
[[ $timeout =~ ^[0-9]+$ ]] || die "--timeout must be a number"
for tool in aws jq curl; do command -v "$tool" >/dev/null || die "$tool not found"; done

describe() {
  aws eks describe-cluster --name "$cluster" --region "$region" --query "$1" --output "${2:-json}"
}

# why: the update call returns before the cluster leaves ACTIVE, so poll for the end state
apply_list() {
  local want=$1 out deadline st got
  if ! out=$(aws eks update-cluster-config --name "$cluster" --region "$region" \
      --resources-vpc-config "$(jq -cn --argjson c "$want" '{publicAccessCidrs: $c}')" 2>&1); then
    case $out in
      *[Nn]o\ changes*) log "no change needed" ;;
      *) die "update-cluster-config failed: ${out##*$'\n'}" ;;
    esac
  fi
  want=$(jq -c 'sort' <<<"$want")
  deadline=$((SECONDS + timeout))
  while (( SECONDS < deadline )); do
    st=$(describe cluster.status text)
    got=$(describe cluster.resourcesVpcConfig.publicAccessCidrs | jq -c 'sort')
    if [[ $st == ACTIVE && $got == "$want" ]]; then
      log "allow-list is now $got"
      return 0
    fi
    sleep 10
  done
  die "timed out after ${timeout}s waiting for $want (status $st, list $got)"
}

case $action in
  open)
    [[ ! -e $state ]] || die "state file $state exists: allow-list already opened"
    orig=$(describe cluster.resourcesVpcConfig.publicAccessCidrs)
    printf '%s\n' "$orig" > "$state"
    ip=$(curl -4fsS https://checkip.amazonaws.com | tr -d '[:space:]')
    [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "cannot determine the public IPv4"
    log "original list $orig, adding $ip/32"
    apply_list "$(jq -c --arg c "$ip/32" '. + [$c] | unique' <<<"$orig")"
    ;;
  restore)
    [[ -e $state ]] || { log "no state file, nothing to restore"; exit 0; }
    apply_list "$(jq -c . "$state")"
    rm -f -- "$state"
    ;;
esac
