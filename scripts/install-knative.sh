#!/usr/bin/env bash
# =============================================================================
# install-knative.sh -- Knative Serving + Kourier for week 6 (canary, wake
# from zero, queue-proxy overhead), on EITHER cluster (k3s GPU node or kind).
# Same shape as install-autoscaling.sh: pinned, hash-checked, idempotent.
#
#   scripts/install-knative.sh
#
# Order and why:
#   1. Knative Serving CRDs, then core, v1.21.1 -- the version KServe v0.20.0's
#      own installer uses (hack/setup/quick-install: KNATIVE_SERVING_VERSION=
#      1.21.1; go.mod knative.dev/serving v0.48.1). Release files are verified
#      by full sha256; their Knative images are digest-pinned upstream.
#   2. Kourier (net-kourier v1.21.1) as the Knative ingress -- lightest option,
#      no mesh needed. Two changes to the upstream file:
#      - Envoy: upstream uses the FLOATING tag envoy:v1.36-latest. Replaced by
#        v1.36.13 by digest (what that tag pointed to on 2026-10-26; released
#        2026-10-12, >= 14 days old).
#      - Service kourier: LoadBalancer -> NodePort 30880. On k3s a LoadBalancer
#        Service is answered by servicelb, which binds 80/443 on the VM's
#        public interface. NodePort keeps it in-cluster/on-node only.
#   3. Knative config: ingress class = Kourier; domain = example.com (the
#      KServe default; no DNS - clients send a Host header).
#   4. KServe: helm upgrade, SAME chart v0.20.0, SAME manifests/kserve-values.yaml
#      (now with disableIstioVirtualHost: true). Then restart the controller:
#      it looks for Knative's CRDs at start (controller.go:629), like KEDA.
# Default deployment mode stays Standard; an ISVC opts in to Knative with the
# annotation serving.kserve.io/deploymentMode: Knative.
# Idempotent: a re-run re-applies the same objects and restarts KServe.
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KN_VERSION=1.21.1
KSERVE_VERSION=v0.20.0
SERVING_URL="https://github.com/knative/serving/releases/download/knative-v${KN_VERSION}"
KOURIER_URL="https://github.com/knative/net-kourier/releases/download/knative-v${KN_VERSION}"
declare -A SHA=(
  [serving-crds.yaml]=bb6d837db047aef64dfb437f66365f95aa55b32db3f8e74343e59dc1f7e9ce8e
  [serving-core.yaml]=636e36155fecb51a60bf869c0d8fa3ef6c2966b1fa9ded8464a48e8a5a880669
  [kourier.yaml]=136bf8b5e46511b45a3871789761474d33f4b98f5dc491ab681921e5a1c273ea
)
ENVOY_FLOATING='docker.io/envoyproxy/envoy:v1.36-latest'
ENVOY_PINNED='docker.io/envoyproxy/envoy:v1.36.13@sha256:93e25ef06d87a908a1114e8dff9a2b3a3046fbbfda7e644d448d752332633de6'
KOURIER_NODEPORT=30880
CACHE="${KNATIVE_CACHE:-$HOME/src/knative-release}"

die() { printf '\n!!! %s\n' "$*" >&2; exit 1; }
ok()  { printf '    [ok] %s\n' "$*"; }

kubectl version --request-timeout=10s >/dev/null 2>&1 || die "kubectl cannot reach a cluster (KUBECONFIG?)"
kubectl -n kserve get deploy kserve-controller-manager >/dev/null 2>&1 \
  || die "KServe controller not found in namespace kserve - install KServe first"
chart="$(helm list -n kserve -o json | jq -r '.[] | select(.name=="kserve") | .chart')"
[[ "$chart" == "kserve-resources-${KSERVE_VERSION}" ]] || die "helm release kserve is '$chart', expected kserve-resources-${KSERVE_VERSION}"
kv="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')"
if [[ "$kv" == *+k3s* ]]; then PLATFORM=k3s; else PLATFORM=kind; fi
echo "== platform: $PLATFORM ($kv)"

fetch() {  # $1 = file name, $2 = base URL; prints the verified local path
  local f="$CACHE/$1"
  [[ -f "$f" ]] || curl -fsSL -o "$f" "$2/$1" || die "download failed: $2/$1"
  echo "${SHA[$1]}  $f" | sha256sum -c --quiet - >/dev/null \
    || { rm -f "$f"; die "sha256 mismatch for $1 (deleted) - not applying"; }
  echo "$f"
}
mkdir -p "$CACHE"

echo "== 1. Knative Serving v${KN_VERSION}"
f="$(fetch serving-crds.yaml "$SERVING_URL")"; ok "serving-crds.yaml sha256 verified"
kubectl apply -f "$f" >/dev/null
kubectl wait --for condition=established --timeout=2m -f "$f" >/dev/null
ok "CRDs established"
f="$(fetch serving-core.yaml "$SERVING_URL")"; ok "serving-core.yaml sha256 verified"
kubectl apply -f "$f" >/dev/null
kubectl -n knative-serving rollout status deploy --timeout=5m
ok "Knative Serving core running"

echo "== 2. Kourier v${KN_VERSION}"
f="$(fetch kourier.yaml "$KOURIER_URL")"; ok "kourier.yaml sha256 verified"
n="$(grep -c -F "$ENVOY_FLOATING" "$f" || true)"
[[ "$n" == 1 ]] || die "expected exactly 1 '$ENVOY_FLOATING' in kourier.yaml, found $n - upstream changed, re-check the pin"
n="$(grep -c '^  type: LoadBalancer$' "$f" || true)"
[[ "$n" == 1 ]] || die "expected exactly 1 LoadBalancer Service in kourier.yaml, found $n - re-check"
# Both changes in the stream, so the Service never exists as a LoadBalancer
# (k3s servicelb would bind 80/443 on the VM in the gap before a patch).
sed -e "s#${ENVOY_FLOATING}#${ENVOY_PINNED}#" -e 's/^  type: LoadBalancer$/  type: NodePort/' "$f" \
  | kubectl apply -f - >/dev/null
ok "applied with Envoy pinned (${ENVOY_PINNED#docker.io/envoyproxy/}) and Service kourier as NodePort"
kubectl -n kourier-system patch svc kourier --type merge -p \
  "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"name\":\"http2\",\"port\":80,\"protocol\":\"TCP\",\"targetPort\":8080,\"nodePort\":${KOURIER_NODEPORT}},{\"name\":\"https\",\"port\":443,\"protocol\":\"TCP\",\"targetPort\":8443}]}}" >/dev/null
t="$(kubectl -n kourier-system get svc kourier -o jsonpath='{.spec.type} {.spec.ports[?(@.port==80)].nodePort}')"
[[ "$t" == "NodePort ${KOURIER_NODEPORT}" ]] || die "kourier Service is '$t', expected 'NodePort ${KOURIER_NODEPORT}'"
ok "Service kourier: NodePort ${KOURIER_NODEPORT} (not LoadBalancer)"
kubectl -n kourier-system rollout status deploy --timeout=5m
kubectl -n knative-serving rollout status deploy/net-kourier-controller --timeout=5m
ok "Kourier running"

echo "== 3. Knative config"
kubectl -n knative-serving patch cm config-network --type merge \
  -p '{"data":{"ingress-class":"kourier.ingress.networking.knative.dev"}}' >/dev/null
kubectl -n knative-serving patch cm config-domain --type merge \
  -p '{"data":{"example.com":""}}' >/dev/null
ok "ingress-class = kourier; domain = example.com"
if [[ "$PLATFORM" == kind ]]; then
  # KIND ONLY. Knative resolves every image tag to a digest before running a
  # revision. The kind CPU runtime image (public.ecr.aws/.../vllm-cpu-release-
  # repo:latest) was side-loaded into the node on 2026-09-16 (content digest
  # e42aae44c784...); the node holds it only under that tag, and the registry
  # is unreachable from inside kind (resolution timed out, A1). Skipping
  # resolution for that registry runs the local copy, which kind never re-
  # pulls. The GPU runtime image is digest-pinned, so k3s needs none of this.
  kubectl -n knative-serving patch cm config-deployment --type merge \
    -p '{"data":{"registries-skipping-tag-resolving":"kind.local,ko.local,dev.local,public.ecr.aws"}}' >/dev/null
  ok "kind: tag resolution skipped for public.ecr.aws (side-loaded CPU image)"
  # KIND ONLY. Knative + Kourier REQUEST 1.0 CPU (activator 300m, gateway
  # 200m, four at 100m) on an 8-CPU node: a second 3-CPU qwen no longer fit
  # (5.78 + 3 > 8, "Insufficient cpu", week 6 A3), and A4/A5 need two. They sit
  # idle on kind, so the reservation is waste: requests -> 25m each (limits
  # untouched). The GPU node has the CPUs and keeps upstream values.
  for dn in knative-serving/activator knative-serving/autoscaler knative-serving/controller \
            knative-serving/webhook knative-serving/net-kourier-controller \
            kourier-system/3scale-kourier-gateway; do
    kubectl -n "${dn%%/*}" set resources deploy "${dn#*/}" --requests=cpu=25m >/dev/null
  done
  kubectl -n knative-serving rollout status deploy --timeout=5m >/dev/null
  kubectl -n kourier-system rollout status deploy --timeout=5m >/dev/null
  ok "kind: Knative/Kourier CPU requests 1.0 -> 0.15 (25m x 6), limits unchanged"
fi

echo "== 4. KServe ${KSERVE_VERSION}: values upgrade + restart"
helm upgrade kserve "oci://ghcr.io/kserve/charts/kserve-resources" \
  --version "${KSERVE_VERSION}" -n kserve \
  -f "${REPO_ROOT}/manifests/kserve-values.yaml" --wait --timeout 10m >/dev/null
v="$(kubectl -n kserve get cm inferenceservice-config -o jsonpath='{.data.ingress}' | jq -r .disableIstioVirtualHost)"
[[ "$v" == true ]] || die "inferenceservice-config ingress.disableIstioVirtualHost is '$v', expected true"
m="$(kubectl -n kserve get cm inferenceservice-config -o jsonpath='{.data.deploy}' | jq -r .defaultDeploymentMode)"
[[ "$m" == Standard ]] || die "defaultDeploymentMode is '$m', expected Standard"
ok "disableIstioVirtualHost=true; default mode still Standard"
kubectl -n kserve rollout restart deploy/kserve-controller-manager >/dev/null
kubectl -n kserve rollout status deploy/kserve-controller-manager --timeout=5m
ok "KServe controller restarted (picks up Knative CRDs at start)"

echo "== done: next, a Knative-mode ISVC (annotation serving.kserve.io/deploymentMode: Knative)"
