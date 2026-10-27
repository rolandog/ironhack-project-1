#!/usr/bin/env bash
# rg-ci-vars.sh -- publish the non-secret CI values from infra/ci as repository variables
set -euo pipefail
set -C

readonly PROGRAM=${0##*/}
readonly VERSION=1.0
repo=${RG_REPO:-rolandog/ironhack-project-1}
api_version=2026-03-10

usage() {
  cat <<USAGE
Usage: $PROGRAM [--repo=OWNER/REPO]
Read the role ARNs and the registry from 'tofu output' in infra/ci and create or
update the repository variables RG_P2_PUSH_ROLE_ARN, RG_P2_DEPLOY_ROLE_ARN and
RG_P2_ECR_REGISTRY. Needs a token with 'Variables: write' (fine-grained) or the
'repo' scope (classic): read from GH_TOKEN or prompted without echo.

  --repo=OWNER/REPO  target repository (default: $repo)
  --help             display this help and exit
  --version          output version information and exit
USAGE
}

die() { printf '%s: error: %s\n' "$PROGRAM" "$*" >&2; exit 1; }

for arg; do
  case $arg in
    --help)    usage; exit 0 ;;
    --version) printf '%s %s\n' "$PROGRAM" "$VERSION"; exit 0 ;;
    --repo=*)  repo=${arg#*=} ;;
    *)         usage >&2; die "unrecognized option '$arg'" ;;
  esac
done

command -v curl >/dev/null || die "curl not found"
command -v jq >/dev/null || die "jq not found"
command -v tofu >/dev/null || die "tofu not found"
cd -- "$(dirname -- "$0")/.."

token=${GH_TOKEN:-}
if [[ -z $token ]]; then
  read -rsp 'github token (Variables: write): ' token
  echo >&2
fi
[[ -n $token ]] || die "no token"

# why: -K - keeps the token out of argv and out of the process list
api() {
  local method=$1 path=$2
  shift 2
  printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl -sS -K - -w '%{http_code}' -X "$method" \
      -H 'Accept: application/vnd.github+json' \
      -H "X-GitHub-Api-Version: $api_version" \
      "https://api.github.com/repos/$repo/actions/$path" "$@"
}

set_var() {
  local name=$1 value=$2 body code
  [[ -n $value ]] || die "empty value for $name; is infra/ci applied?"
  body=$(jq -cn --arg n "$name" --arg v "$value" '{name: $n, value: $v}')
  code=$(api GET "variables/$name" -o /dev/null)
  case $code in
    200) code=$(api PATCH "variables/$name" -o /dev/null -d "$body"); [[ $code == 204 ]] || die "$name: update returned $code" ;;
    404) code=$(api POST variables -o /dev/null -d "$body"); [[ $code == 201 ]] || die "$name: create returned $code" ;;
    *)   die "$name: lookup returned $code (token scope or repo name?)" ;;
  esac
  printf '%s=%s\n' "$name" "$value"
}

out() { tofu -chdir=infra/ci output -raw "$1"; }

set_var RG_P2_PUSH_ROLE_ARN "$(out push_role_arn)"
set_var RG_P2_DEPLOY_ROLE_ARN "$(out deploy_role_arn)"
set_var RG_P2_ECR_REGISTRY "$(out registry)"
