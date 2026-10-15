#!/usr/bin/env bash
# rg-release.sh -- finish a Gitflow release, push it, publish it on GitHub
set -euo pipefail
set -C

readonly PROGRAM=${0##*/}
readonly VERSION=1.0
OWNER=rolandog
REPO=ironhack-project-1
github=yes
tmpdir=

usage() {
  cat <<EOF
Usage: $PROGRAM [OPTION]... VERSION
Finish release/VERSION with git flow (signed tag), push main, develop and the
tag, then create the GitHub release with gcli.  Run it on the release branch.

  --owner=OWNER  repository owner (default: $OWNER)
  --repo=REPO    repository name (default: $REPO)
  --no-github    skip the gcli release step
  --help         display this help and exit
  --version      output version information and exit
EOF
}

die() { printf '%s: error: %s\n' "$PROGRAM" "$*" >&2; exit 1; }
warn() { printf '%s: warning: %s\n' "$PROGRAM" "$*" >&2; }
cleanup() { if [[ -n $tmpdir ]]; then rm -rf -- "$tmpdir"; fi; }
trap cleanup EXIT

rel=
for arg; do
  case $arg in
    --help)    usage; exit 0 ;;
    --version) printf '%s %s\n' "$PROGRAM" "$VERSION"; exit 0 ;;
    --owner=*) OWNER=${arg#*=} ;;
    --repo=*)  REPO=${arg#*=} ;;
    --no-github) github=no ;;
    -*)        usage >&2; die "unrecognized option '$arg'" ;;
    *)         rel=$arg ;;
  esac
done
[[ -n $rel ]] || { usage >&2; die "missing VERSION"; }

[[ $(git rev-parse --abbrev-ref HEAD) == "release/$rel" ]] \
  || die "not on branch release/$rel"
[[ -z $(git status --porcelain) ]] || die "working tree not clean"

main=$(git config --get gitflow.branch.master || echo main)
develop=$(git config --get gitflow.branch.develop || echo develop)

# why: a signed tag needs a tty for the gpg pinentry
GPG_TTY=$(tty) || true
export GPG_TTY
export GIT_MERGE_AUTOEDIT=no

git flow release finish -s -m "Release $rel" "$rel"

tag=$(git describe --tags --abbrev=0 "$main")
printf '%s: tag is %s\n' "$PROGRAM" "$tag"

git push origin "$main" "$develop"
git push origin "$tag"

if [[ $github == yes ]]; then
  command -v gcli >/dev/null || die "gcli not found"
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/${PROGRAM}.XXXXXX")
  # gcli 2.3.0 opens $EDITOR for the release notes; overwrite them from here
  printf '#!/bin/sh\nprintf "%%s\\n" "$RG_NOTES" >"$1"\n' >|"$tmpdir/editor.sh"
  chmod +x "$tmpdir/editor.sh"
  # gcli 2.3.0 may abort after the request succeeds, so verify afterwards
  RG_NOTES="See CHANGELOG.md for $tag." EDITOR=$tmpdir/editor.sh \
    gcli releases create -o "$OWNER" -r "$REPO" -t "$tag" -c "$main" \
      -n "$tag" --yes \
    || warn "gcli exited with status $?; check the listing below"
  gcli releases -o "$OWNER" -r "$REPO"
fi
