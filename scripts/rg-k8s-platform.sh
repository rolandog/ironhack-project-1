#!/usr/bin/env bash
# install gateway api crds (standard channel), envoy gateway and the cluster-level manifests
set -euo pipefail; set -C
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
. "$here/lib.sh"

script_version=0.1.1
eg_version=v1.9.2
# manifest digests recorded 2026-10-26; helm pulls by tag, so verify the tag first
eg_chart_digest=be034275b55deeddd6b7bc1f4da6eeb02b8efc418a4a29e2b1977851b24b1e63
eg_crds_digest=940b88fe361cb22fb651e3075f649e9be885f35b1c8a990658c1a2acc2d2a678

show_usage() {
  cat <<EOF
usage: rg-k8s-platform.sh [--help] [--version]
installs gateway api crds, envoy gateway $eg_version and k8s/platform/*.yaml
uses KUBECONFIG, default ~/.kube/rg-p2.config
EOF
}
case "${1:-}" in
  --help) show_usage; exit 0 ;;
  --version) echo "rg-k8s-platform.sh $script_version"; exit 0 ;;
  "") ;;
  *) show_usage >&2; exit 2 ;;
esac

verify_digest() {
  local ref=$1 want=$2 got
  got=$(skopeo inspect --raw "docker://$ref" | sha256sum | cut -d' ' -f1) \
    || die "cannot inspect $ref"
  [[ $got == "$want" ]] || die "digest mismatch for $ref: got $got, want $want"
  echo "digest ok: $ref"
}

export KUBECONFIG=${KUBECONFIG:-$HOME/.kube/rg-p2.config}
for t in helm kubectl skopeo; do
  command -v "$t" >/dev/null || die "missing tool: $t"
done
kubectl get nodes >/dev/null || die "cluster unreachable: check kubeconfig and the api cidr"

verify_digest "docker.io/envoyproxy/gateway-helm:$eg_version" "$eg_chart_digest"
verify_digest "docker.io/envoyproxy/gateway-crds-helm:$eg_version" "$eg_crds_digest"

# the crds chart defaults to the experimental channel; we want standard
helm template eg-crds oci://docker.io/envoyproxy/gateway-crds-helm --version "$eg_version" \
  --set crds.gatewayAPI.enabled=true \
  --set crds.gatewayAPI.channel=standard \
  --set crds.envoyGateway.enabled=true \
  | kubectl apply --server-side -f -
kubectl wait --for=condition=Established crd --all --timeout=120s

helm upgrade --install eg oci://docker.io/envoyproxy/gateway-helm --version "$eg_version" \
  --namespace envoy-gateway-system --create-namespace \
  --set crds.enabled=false --wait --timeout 5m
kubectl -n envoy-gateway-system rollout status deploy/envoy-gateway --timeout=120s

kubectl apply -f "$here/../k8s/platform/"
echo "platform applied"

