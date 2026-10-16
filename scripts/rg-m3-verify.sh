#!/usr/bin/env bash
# rg-m3-verify.sh -- check the Podman units, memory and the vote -> result path
set -euo pipefail
set -C

readonly PROGRAM=${0##*/}
readonly VERSION=1.0

usage() {
  cat <<EOF
Usage: $PROGRAM [OPTION]...
Check units, memory and the end-to-end vote path of the deployed stack.
Run it from the repository root, after ansible-playbook site.yml.

  --help     display this help and exit
  --version  output version information and exit
EOF
}

for arg; do
  case $arg in
    --help)    usage; exit 0 ;;
    --version) printf '%s %s\n' "$PROGRAM" "$VERSION"; exit 0 ;;
    *)         usage >&2; printf "%s: error: unrecognized option '%s'\n" "$PROGRAM" "$arg" >&2; exit 1 ;;
  esac
done

cd -- "$(dirname -- "$0")/.."
ip=$(tofu -chdir=infra output -raw frontend_public_ip)
cd ansible

# why: rootless podman and systemctl --user need the user's runtime dir
as_rg() {
  local group=$1; shift
  ansible "$group" -b --become-user rgapp -m shell \
    -a "XDG_RUNTIME_DIR=/run/user/\$(id -u) $*"
}

printf '\n== units ==\n'
as_rg db       'systemctl --user is-active db.service'
as_rg backend  'systemctl --user is-active redis.service worker.service'
as_rg frontend 'systemctl --user is-active vote.service result.service'

printf '\n== containers ==\n'
as_rg aws 'podman ps'

printf '\n== memory (issue 37) ==\n'
ansible aws -a 'free -m'
as_rg backend 'podman stats --no-stream'

printf '\n== http ==\n'
for url in "http://$ip/" "http://$ip:8081/"; do
  printf '%s -> ' "$url"
  curl -s -o /dev/null -w '%{http_code}\n' "$url"
done

printf '\n== end to end: cast a vote, read it from postgres ==\n'
curl -s -o /dev/null -w 'vote POST -> %{http_code}\n' -d vote=a "http://$ip/"
sleep 5
as_rg db "podman exec db psql -U postgres -c 'select vote, count(*) from votes group by vote'"
