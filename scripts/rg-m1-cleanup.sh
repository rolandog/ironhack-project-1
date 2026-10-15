#!/usr/bin/env bash
# rg-m1-cleanup.sh -- stop the local stack and drop local build artefacts
set -euo pipefail
set -C

readonly PROGRAM=${0##*/}
readonly VERSION=1.0

usage() {
  cat <<EOF
Usage: $PROGRAM [OPTION]...
Stop the compose stack (removing its volume) and delete local image manifests.
Docker Hub images are not touched.

  --help     display this help and exit
  --version  output version information and exit
EOF
}

for arg; do
  case $arg in
    --help)    usage; exit 0 ;;
    --version) printf '%s %s\n' "$PROGRAM" "$VERSION"; exit 0 ;;
    *)         usage >&2; printf '%s: error: unrecognized option '\''%s'\''\n' "$PROGRAM" "$arg" >&2; exit 1 ;;
  esac
done

cd -- "$(dirname -- "$0")/.."

# DOCKERHUB_USER only feeds image names; any value works for teardown
DOCKERHUB_USER=${DOCKERHUB_USER:-unused} \
  podman compose -f docker-compose.yml down -v || true

for n in vote result worker; do
  podman manifest rm "localhost/rg-$n:0.1.0" >/dev/null 2>&1 || true
done
podman image prune -f
