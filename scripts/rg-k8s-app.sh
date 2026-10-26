#!/usr/bin/env bash
# deploy the voting app (redis, postgres, vote, result, worker, route) to the rg-app namespace
set -euo pipefail; set -C
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
. "$here/lib.sh"

script_version=0.1.0
ns=rg-app
manifests=$here/../k8s/app

show_usage() {
  cat <<EOF
usage: rg-k8s-app.sh [--help] [--version]
applies k8s/app/*.yaml to namespace $ns and waits for every workload
creates secret rg-db once: from DB_PASSWORD, else a prompt (empty input generates one)
uses KUBECONFIG, default ~/.kube/rg-p2.config
EOF
}
case "${1:-}" in
  --help) show_usage; exit 0 ;;
  --version) echo "rg-k8s-app.sh $script_version"; exit 0 ;;
  "") ;;
  *) show_usage >&2; exit 2 ;;
esac

export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/rg-p2.config}
command -v kubectl >/dev/null || die "missing tool: kubectl"
kubectl get nodes >/dev/null || die "cluster unreachable: check kubeconfig and the api cidr (curl -4 https://checkip.amazonaws.com)"
kubectl get namespace "$ns" >/dev/null 2>&1 || die "namespace $ns missing: run scripts/rg-k8s-platform.sh first"

# the manifests pin images by tag@digest; make sure they still match .env
check_pins() {
  local envfile=$here/../.env key val
  [[ -f $envfile ]] || { echo "no .env, skipping pin check"; return 0; }
  while IFS='=' read -r key val; do
    val=${val%\"}; val=${val#\"}
    grep -rqF -- "$val" "$manifests" || die "k8s/app does not use $key=$val from .env"
  done < <(grep -E '^(VOTE|RESULT|WORKER|REDIS|POSTGRES)_IMAGE_TAG=' "$envfile")
  echo "image pins match .env"
}

# an initialised postgres volume keeps its first password, so never overwrite the secret
ensure_secret() {
  local pw=${DB_PASSWORD:-}
  if kubectl -n "$ns" get secret rg-db >/dev/null 2>&1; then
    echo "secret rg-db exists, left unchanged"
    return 0
  fi
  if [[ -z $pw ]]; then
    [[ -t 0 ]] || die "DB_PASSWORD not set and no terminal to prompt on"
    read -rsp 'db password (letters and digits only, empty to generate): ' pw
    echo
    if [[ -z $pw ]]; then
      command -v openssl >/dev/null || die "missing tool: openssl"
      pw=$(openssl rand -hex 16)
    fi
  fi
  [[ $pw =~ ^[A-Za-z0-9]+$ ]] || die "password must be letters and digits only (result builds a url from it)"
  # printf is a builtin, so the password never shows in ps; create (not apply) avoids a last-applied annotation holding it
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: rg-db\n  namespace: %s\n  labels:\n    app.kubernetes.io/part-of: rg-voting-app\nstringData:\n  POSTGRES_PASSWORD: "%s"\n  PG_PASSWORD: "%s"\n  DB_PASSWORD: "%s"\n' \
    "$ns" "$pw" "$pw" "$pw" | kubectl create -f -
}

check_pins
ensure_secret

kubectl apply -f "$manifests/10-redis.yaml" -f "$manifests/20-db.yaml"
kubectl -n "$ns" rollout status deploy/redis --timeout=120s
# first start waits for the EBS volume to be provisioned and attached
kubectl -n "$ns" rollout status statefulset/db --timeout=300s

kubectl apply -f "$manifests/30-vote.yaml" -f "$manifests/40-result.yaml" \
  -f "$manifests/50-worker.yaml" -f "$manifests/60-httproute.yaml"
for d in vote result worker; do
  kubectl -n "$ns" rollout status "deploy/$d" --timeout=180s
done

# the route status is per parent, so poll it instead of using kubectl wait
accepted=
for _ in $(seq 1 12); do
  accepted=$(kubectl -n "$ns" get httproute voting-app \
    -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)
  [[ $accepted == True ]] && break
  sleep 5
done
[[ $accepted == True ]] || die "httproute voting-app not accepted: kubectl -n $ns describe httproute voting-app"
echo "app deployed"
