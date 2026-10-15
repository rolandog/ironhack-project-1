#!/usr/bin/env bash
# rg-milestone-close.sh -- close a GitHub milestone (gcli 2.3.0 has no close action)
set -euo pipefail
set -C

readonly PROGRAM=${0##*/}
readonly VERSION=1.0
OWNER=rolandog
REPO=ironhack-project-1

usage() {
  cat <<EOF
Usage: $PROGRAM [OPTION]... NUMBER...
Close the milestones with the given numbers (the ids shown by gcli milestones).
The token is read from \$GITHUB_TOKEN, or prompted for.

  --owner=OWNER  repository owner (default: $OWNER)
  --repo=REPO    repository name (default: $REPO)
  --help         display this help and exit
  --version      output version information and exit
EOF
}

die() { printf '%s: error: %s\n' "$PROGRAM" "$*" >&2; exit 1; }

nums=()
for arg; do
  case $arg in
    --help)    usage; exit 0 ;;
    --version) printf '%s %s\n' "$PROGRAM" "$VERSION"; exit 0 ;;
    --owner=*) OWNER=${arg#*=} ;;
    --repo=*)  REPO=${arg#*=} ;;
    -*)        usage >&2; die "unrecognized option '$arg'" ;;
    *)         nums+=("$arg") ;;
  esac
done
(( ${#nums[@]} > 0 )) || { usage >&2; die "missing milestone number"; }
command -v curl >/dev/null || die "curl not found"
command -v jq >/dev/null || die "jq not found"

if [[ -z ${GITHUB_TOKEN:-} ]]; then
  read -rsp 'github token: ' GITHUB_TOKEN; echo
fi

for n in "${nums[@]}"; do
  # why: the token goes through a curl config on stdin, so it never shows in ps
  printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN" \
    | curl -fsS -K - -X PATCH \
        -H 'Accept: application/vnd.github+json' \
        -d '{"state":"closed"}' \
        "https://api.github.com/repos/$OWNER/$REPO/milestones/$n" \
    | jq -r '"\(.number) \(.title): \(.state)"'
done
