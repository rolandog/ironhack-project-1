#!/usr/bin/env bash
# rg-build-images.sh -- build multi-arch images with podman, optionally push to Docker Hub
set -euo pipefail
set -C

readonly PROGRAM=${0##*/}
readonly VERSION=1.0
user=${DOCKERHUB_USER:-}
tag=0.1.0
platforms=linux/amd64,linux/arm64
push=no
images=()

usage() {
  cat <<EOF
Usage: $PROGRAM [OPTION]...
Build the vote, result and worker images as multi-arch manifest lists.

  --user=NAME        Docker Hub user (default: \$DOCKERHUB_USER)
  --tag=TAG          version tag (default: $tag); 'latest' is pushed too
  --platforms=LIST   comma-separated platforms (default: $platforms)
  --only=NAME        build only this image; repeatable (vote, result, worker)
  --push             push to docker.io after building
  --help             display this help and exit
  --version          output version information and exit
EOF
}

die() { printf '%s: error: %s\n' "$PROGRAM" "$*" >&2; exit 1; }

for arg; do
  case $arg in
    --help)        usage; exit 0 ;;
    --version)     printf '%s %s\n' "$PROGRAM" "$VERSION"; exit 0 ;;
    --user=*)      user=${arg#*=} ;;
    --tag=*)       tag=${arg#*=} ;;
    --platforms=*) platforms=${arg#*=} ;;
    --only=*)      images+=("${arg#*=}") ;;
    --push)        push=yes ;;
    *)             usage >&2; die "unrecognized option '$arg'" ;;
  esac
done

if (( ${#images[@]} == 0 )); then images=(vote result worker); fi
if [[ $push == yes && -z $user ]]; then die "--user or DOCKERHUB_USER required with --push"; fi
command -v podman >/dev/null || die "podman not found"

cd -- "$(dirname -- "$0")/.."

for name in "${images[@]}"; do
  [[ -f $name/Dockerfile ]] || die "$name/Dockerfile not found"
  ref=localhost/rg-$name:$tag

  # why: building into an existing manifest list appends duplicate entries
  podman manifest rm "$ref" >/dev/null 2>&1 || true
  podman build --platform "$platforms" --manifest "$ref" "$name"

  if [[ $push == yes ]]; then
    for t in "$tag" latest; do
      # --all also pushes the per-arch images, not just the list (default true)
      podman manifest push --all "$ref" "docker://docker.io/$user/$name:$t"
    done
  fi
done
