#!/usr/bin/env bash
# rg-build-images.sh -- build multi-arch images with podman, push, verify the registry
set -euo pipefail
set -C

readonly PROGRAM=${0##*/}
readonly VERSION=2.1
user=${DOCKERHUB_USER:-}
registry=docker.io
prefix=
prefix_set=no
tag=
platforms=linux/amd64,linux/arm64
mode=build
latest=no
resume=no
build_opts=()
images=()
tmp=

usage() {
  cat <<USAGE
Usage: $PROGRAM --tag=X.Y.Z [OPTION]...
Build the vote, result and worker images as multi-arch manifest lists,
optionally push them, and verify what the registry holds.

  --tag=X.Y.Z        version tag (required, SemVer, never 'latest')
  --user=NAME        Docker Hub user (default: \$DOCKERHUB_USER)
  --registry=HOST    registry host (default: docker.io)
  --prefix=STR       image is HOST/STR<name>; default is USER/ (ECR: rg-p2-)
  --platforms=LIST   comma-separated platforms (default: $platforms)
  --only=NAME        handle only this image; repeatable (vote, result, worker)
  --no-cache         build without the layer cache and pull fresh bases
  --push             push after building; refuses a tag that already exists
  --resume           with --push, verify a tag that already exists instead of failing
  --verify           build nothing; verify the tag already on the registry
  --latest           with --push, also move the floating 'latest' tag
                     (fails on immutable repositories)
  --help             display this help and exit
  --version          output version information and exit

Prints one NAME_IMAGE_TAG=tag@sha256:... line per pushed or verified image.
USAGE
}

die() { printf '%s: error: %s\n' "$PROGRAM" "$*" >&2; exit 1; }
warn() { printf '%s: warning: %s\n' "$PROGRAM" "$*" >&2; }

# why: e_machine bytes at ELF offset 18 are the ground truth for the architecture
elf_machine() {
  case $1 in
    linux/amd64) echo 3e00 ;;
    linux/arm64) echo b700 ;;
    *) return 1 ;;
  esac
}

# returns 0 if the tag exists, 1 if the registry says it does not, dies otherwise
tag_exists() {
  local out
  if out=$(skopeo inspect --raw "docker://$1" 2>&1); then return 0; fi
  case $out in
    *'manifest unknown'*|*'not found'*) return 1 ;;
    *) die "cannot check $1: ${out##*$'\n'}" ;;
  esac
}

verify_registry() {
  local name=$1 repo=$2 digest=$3 want got p expect out
  want=$(tr ',' '\n' <<<"$platforms" | LC_ALL=C sort | paste -sd, -)
  got=$(skopeo inspect --raw "docker://$repo@$digest" |
    jq -r '[.manifests[] | "\(.platform.os)/\(.platform.architecture)"] | sort | join(",")')
  [[ $got == "$want" ]] || die "$name: registry holds '$got', want '$want'"
  for p in ${platforms//,/ }; do
    expect=$(elf_machine "$p")
    if ! out=$(podman run --rm --platform="$p" --pull=always --entrypoint=/bin/sh \
        "$repo@$digest" -c 'od -An -tx1 -j18 -N2 /bin/sh' 2>&1 | tail -n 1); then
      die "$name $p: podman run failed: $out"
    fi
    out=${out// /}
    [[ $out == "$expect" ]] || die "$name $p: ELF e_machine '$out', want '$expect'"
    printf '%s %s: elf %s ok\n' "$name" "$p" "$expect" >&2
  done
}

for arg; do
  case $arg in
    --help)        usage; exit 0 ;;
    --version)     printf '%s %s\n' "$PROGRAM" "$VERSION"; exit 0 ;;
    --user=*)      user=${arg#*=} ;;
    --registry=*)  registry=${arg#*=} ;;
    --prefix=*)    prefix=${arg#*=}; prefix_set=yes ;;
    --tag=*)       tag=${arg#*=} ;;
    --platforms=*) platforms=${arg#*=} ;;
    --only=*)      images+=("${arg#*=}") ;;
    --no-cache)    build_opts=(--no-cache --pull=always) ;;
    --latest)      latest=yes ;;
    --resume)      resume=yes ;;
    --push)        [[ $mode == build ]] || die "--push and --verify are exclusive"; mode=push ;;
    --verify)      [[ $mode == build ]] || die "--push and --verify are exclusive"; mode=verify ;;
    *)             usage >&2; die "unrecognized option '$arg'" ;;
  esac
done

semver='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$'
[[ $tag =~ $semver ]] || die "--tag must be a SemVer version such as 1.2.3 (got '${tag}')"
if [[ $latest == yes && $mode != push ]]; then die "--latest needs --push"; fi
if [[ $resume == yes && $mode != push ]]; then die "--resume needs --push"; fi
if [[ $prefix_set == no && -n $user ]]; then prefix=$user/; fi
if [[ $mode != build && $prefix_set == no && -z $user ]]; then
  die "--user, DOCKERHUB_USER or --prefix required with --push or --verify"
fi
if (( ${#images[@]} == 0 )); then images=(vote result worker); fi
for name in "${images[@]}"; do
  case $name in vote|result|worker) ;; *) die "unknown image '$name'" ;; esac
done
for p in ${platforms//,/ }; do
  elf_machine "$p" >/dev/null || die "unsupported platform '$p' (linux/amd64 and linux/arm64 only)"
done
command -v podman >/dev/null || die "podman not found"
if [[ $mode != build ]]; then
  command -v skopeo >/dev/null || die "skopeo not found"
  command -v jq >/dev/null || die "jq not found"
fi

cd -- "$(dirname -- "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/$PROGRAM.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

pins=()
for name in "${images[@]}"; do
  [[ -f $name/Dockerfile ]] || die "$name/Dockerfile not found"
  repo=$registry/$prefix$name
  ref=localhost/rg-$name:$tag
  pushed=
  act=$mode

  case $mode in
    verify) tag_exists "$repo:$tag" || die "$repo:$tag does not exist" ;;
    push)
      if tag_exists "$repo:$tag"; then
        [[ $resume == yes ]] ||
          die "$repo:$tag already exists; never reuse a tag, bump the version (or use --resume)"
        printf '%s: %s exists, verifying instead of rebuilding\n' "$name" "$tag" >&2
        act=verify
      fi
      ;;
  esac

  if [[ $act != verify ]]; then
    # why: building into an existing manifest list appends duplicate entries
    podman manifest rm "$ref" >/dev/null 2>&1 || true
    podman build "${build_opts[@]}" --platform "$platforms" --manifest "$ref" "$name"
  fi

  if [[ $act == push ]]; then
    podman manifest push --all --digestfile="$tmp/$name.digest" "$ref" "docker://$repo:$tag"
    pushed=$(<"$tmp/$name.digest")
  fi

  if [[ $mode != build ]]; then
    # why: the registry digest is the only one that counts for pinning
    digest=$(skopeo inspect --format '{{.Digest}}' "docker://$repo:$tag")
    if [[ -n $pushed && $pushed != "$digest" ]]; then
      warn "$name: digestfile $pushed differs from registry $digest; pin the registry one"
    fi
    verify_registry "$name" "$repo" "$digest"
    if [[ $latest == yes && $act == push ]]; then
      podman manifest push --all "$ref" "docker://$repo:latest"
    fi
    pins+=("${name^^}_IMAGE_TAG=$tag@$digest")
  fi
done

if (( ${#pins[@]} > 0 )); then printf '%s\n' "${pins[@]}"; fi
