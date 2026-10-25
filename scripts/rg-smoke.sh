#!/usr/bin/env bash
# rg-smoke.sh: run the stack once, from local builds or from the pinned registry images
set -euo pipefail; set -C
VERSION=0.2.0
PROG=${0##*/}

usage() {
  cat <<EOF
Usage: $PROG [--pinned] [--user=NAME] [--keep] [--help] [--version]
Run vote, result and worker with rootless podman next to the pinned redis and
postgres images from .env.example, cast two votes and read them back.
The database password is random and lives only in this process.
  --pinned     do not build; pull the images from Docker Hub by the tag@digest
               pins in .env.example
  --user=NAME  Docker Hub user for --pinned (default: \$DOCKERHUB_USER)
  --keep       leave containers, network, volume and built images for debugging
EOF
}
die() { echo "$PROG: $*" >&2; exit 1; }

keep=0
pinned=0
user=${DOCKERHUB_USER:-}
for a in "$@"; do
  case $a in
    --help) usage; exit 0 ;;
    --version) echo "$PROG $VERSION"; exit 0 ;;
    --keep) keep=1 ;;
    --pinned) pinned=1 ;;
    --user=*) user=${a#*=} ;;
    *) usage >&2; die "unknown option: $a" ;;
  esac
done
if [ "$pinned" -eq 1 ] && [ -z "$user" ]; then die "--pinned needs --user or DOCKERHUB_USER"; fi

for c in podman curl openssl git sed; do
  command -v "$c" >/dev/null || die "$c not found"
done
cd "$(git rev-parse --show-toplevel)"
[ -r .env.example ] || die ".env.example not found"

need() {
  local v
  v=$(sed -n "s/^$1=//p" .env.example | head -n 1)
  [ -n "$v" ] || die "$1 missing in .env.example"
  printf '%s' "$v"
}
pg_image=docker.io/library/postgres:$(need POSTGRES_IMAGE_TAG)
redis_image=docker.io/library/redis:$(need REDIS_IMAGE_TAG)

tag=t$$
net=rg-smoke-net
vol=rg-smoke-pgdata
names=(rg-smoke-db rg-smoke-redis rg-smoke-vote rg-smoke-result rg-smoke-worker)
roles=(vote result worker)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/rg-smoke.XXXXXX")

# why: one place decides where each image comes from
declare -A img
for r in "${roles[@]}"; do
  if [ "$pinned" -eq 1 ]; then
    pin=$(need "${r^^}_IMAGE_TAG")
    case $pin in *@sha256:*) ;; *) die "${r^^}_IMAGE_TAG is not pinned by digest: $pin" ;; esac
    img[$r]=docker.io/$user/$r:$pin
  else
    img[$r]=localhost/rg-smoke/$r:$tag
  fi
done

wipe() {
  podman rm -f "${names[@]}" >/dev/null 2>&1 || true
  podman volume rm -f "$vol" >/dev/null 2>&1 || true
  podman network rm -f "$net" >/dev/null 2>&1 || true
}
on_exit() {
  local rc=$? c r
  if [ "$rc" -ne 0 ]; then
    for c in "${names[@]}"; do
      podman logs --tail=15 "$c" 2>&1 | sed "s/^/$c: /" >&2 || true
    done
  fi
  if [ "$keep" -eq 0 ]; then
    wipe
    # why: only built images are ours to delete; pulled ones stay cached
    if [ "$pinned" -eq 0 ]; then
      for r in "${roles[@]}"; do
        podman rmi -f "${img[$r]}" >/dev/null 2>&1 || true
      done
    fi
  fi
  rm -rf "$tmp"
  exit "$rc"
}
trap on_exit EXIT

# why: eventual consistency; every wait has a time limit and a name
retry() {
  local n=$1 what=$2 i
  shift 2
  for ((i = 0; i < n; i++)); do
    if "$@" >/dev/null 2>&1; then echo "ok: $what"; return 0; fi
    sleep 1
  done
  die "timeout waiting for $what"
}

wipe
for r in "${roles[@]}"; do
  if [ "$pinned" -eq 1 ]; then
    echo "pull: ${img[$r]}"
    podman pull --quiet "${img[$r]}" >"$tmp/pull-$r.log" 2>&1 \
      || { tail -n 25 "$tmp/pull-$r.log" >&2; die "pull failed: $r"; }
  else
    echo "build: $r"
    podman build --tag="${img[$r]}" "$r" >"$tmp/build-$r.log" 2>&1 \
      || { tail -n 25 "$tmp/build-$r.log" >&2; die "build failed: $r"; }
  fi
done

pw=$(openssl rand -hex 24)
export POSTGRES_PASSWORD=$pw PG_PASSWORD=$pw DB_PASSWORD=$pw

podman network create "$net" >/dev/null
podman volume create "$vol" >/dev/null
podman run -d --name=rg-smoke-db --network="$net" --network-alias=db \
  -e POSTGRES_USER=postgres -e POSTGRES_PASSWORD \
  --volume="$vol:/var/lib/postgresql" "$pg_image" >/dev/null
podman run -d --name=rg-smoke-redis --network="$net" --network-alias=redis \
  "$redis_image" >/dev/null

# why: a fresh data directory prints the ready line twice (init server, then final)
pg_up() { [ "$(podman logs rg-smoke-db 2>&1 | grep -c 'ready to accept connections')" -ge 2 ]; }
retry 90 "postgres ready" pg_up
retry 30 "redis ready" podman exec rg-smoke-redis redis-cli ping

podman run -d --name=rg-smoke-vote --network="$net" \
  -e REDIS_HOST=redis -e VOTING_MODE=every-click \
  --sysctl=net.ipv4.ip_unprivileged_port_start=0 \
  --publish=127.0.0.1:18080:80 "${img[vote]}" >/dev/null
podman run -d --name=rg-smoke-worker --network="$net" \
  -e DB_HOST=db -e REDIS_HOST=redis -e DB_PASSWORD -e VOTING_MODE=every-click \
  "${img[worker]}" >/dev/null
podman run -d --name=rg-smoke-result --network="$net" \
  -e PG_HOST=db -e PG_PASSWORD \
  --sysctl=net.ipv4.ip_unprivileged_port_start=0 \
  --publish=127.0.0.1:18081:80 "${img[result]}" >/dev/null

retry 30 "vote answers on 18080" curl -fsS -o /dev/null http://127.0.0.1:18080/
retry 30 "result answers on 18081" curl -fsS -o /dev/null http://127.0.0.1:18081/

# why: one vote per route; upstream PR 28 makes both work
curl -fsS -c "$tmp/jar" -b "$tmp/jar" --data vote=a -o /dev/null http://127.0.0.1:18080/
curl -fsS -c "$tmp/jar" -b "$tmp/jar" --data vote=b -o /dev/null http://127.0.0.1:18080/vote

tally() {
  podman exec rg-smoke-db psql -U postgres -tA \
    -c 'select vote, count(*) from votes group by vote order by vote' 2>/dev/null
}
tally_is() { [ "$(tally | tr '\n' ' ')" = "a|1 b|1 " ]; }
retry 40 "worker stored a|1 and b|1" tally_is
echo "tally:"; tally
retry 30 "result connected to db" bash -c 'podman logs rg-smoke-result 2>&1 | grep -q "Connected to db"'

want=(vote:10001 result:1000 worker:1654)
for p in "${want[@]}"; do
  r=${p%%:*}; uid=${p##*:}
  got=$(podman exec "rg-smoke-$r" id -u)
  [ "$got" = "$uid" ] || die "$r runs as uid $got, want $uid"
  [ "$(podman inspect --format='{{.State.Running}}' "rg-smoke-$r")" = true ] || die "$r is not running"
  n=$(podman image inspect --format='{{.Config.Env}}' "${img[$r]}" | grep -c PASSWORD || true)
  [ "$n" -eq 0 ] || die "$r image has a PASSWORD default in its env"
  echo "ok: $r uid=$got, no password in image env"
done

echo '--- npm audit, production dependencies of result'
podman run --rm --entrypoint=node "${img[result]}" --version
podman run --rm --entrypoint=npm "${img[result]}" --version
podman run --rm --entrypoint=npm "${img[result]}" audit --omit=dev \
  || echo "npm audit exit $? (non-zero means findings or no network)"
echo "smoke test passed"
