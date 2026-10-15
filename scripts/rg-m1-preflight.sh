#!/usr/bin/env bash
# rg-m1-preflight.sh -- check the toolchain before building multi-arch images
set -euo pipefail
set -C

readonly PROGRAM=${0##*/}
readonly VERSION=1.0

usage() {
  cat <<EOF
Usage: $PROGRAM [OPTION]...
Check podman, arm64 emulation and Docker Hub login for the M1 image build.

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

fail=0
check() {
  local desc=$1
  shift
  if "$@" >/dev/null 2>&1; then
    printf 'ok:   %s\n' "$desc"
  else
    printf 'FAIL: %s\n' "$desc" >&2
    fail=1
  fi
}

check "podman installed"                 command -v podman
check "compose provider (podman compose)" podman compose version
check "jq installed"                     command -v jq
check "qemu-aarch64 binfmt registered"   test -e /proc/sys/fs/binfmt_misc/qemu-aarch64
check "logged in to docker.io"           podman login --get-login docker.io
# why: an Exec format error here means emulation is missing inside this VM
check "arm64 container runs"             test "$(podman run --rm --platform linux/arm64 docker.io/library/alpine uname -m)" = aarch64

if (( fail )); then
  printf '%s: error: preflight failed\n' "$PROGRAM" >&2
  exit 1
fi
printf 'docker hub user: %s\n' "$(podman login --get-login docker.io)"
