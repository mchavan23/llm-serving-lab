#!/usr/bin/env bash
# =============================================================================
# install-autoscaling.sh -- Prometheus + KEDA for the week-5 scale-out, on
# EITHER cluster (k3s GPU node or kind). Repeats exactly what was done by hand
# on kind in A3 (Prometheus) and A6 (KEDA), as one checked, repeatable step.
#
#   scripts/install-autoscaling.sh
#
# Order and why:
#   1. Prometheus (manifests/prometheus.yaml, v3.15.0 by digest): KEDA's
#      trigger queries it, so it comes first.
#   2. Guard: exactly ONE provider may serve external.metrics.k8s.io. If
#      another one holds it, KEDA's install would silently take it over (or
#      lose it) and the HPA would read someone else's metrics. Refuse.
#      KEDA's own APIService (re-run) is accepted.
#   3. KEDA v2.21.0 from the upstream release file, verified by full sha256
#      (the only release tested on k8s 1.36; decision 2026-10-25). Its images
#      are tag-pinned upstream (:2.21.0); the file itself is hash-pinned here.
#   4. Restart the KServe controller: it looks for KEDA's CRDs only at start
#      (A2). Without the restart it never creates ScaledObjects.
#   5. Report the HPA sync period (stage 4 of time-to-relief,
#      benchmarks/scaling-constants.md): default 15 s unless overridden.
# Idempotent: a re-run re-applies the same objects and restarts KServe.
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEDA_VERSION=2.21.0
KEDA_SHA256=b43c89ffeef81722d7e2dd2c079d74789767a0f89cae1336cff784994814f6d7
KEDA_URL="https://github.com/kedacore/keda/releases/download/v${KEDA_VERSION}/keda-${KEDA_VERSION}.yaml"
KEDA_CACHE="${KEDA_CACHE:-$HOME/src/keda-release}"
APISVC=v1beta1.external.metrics.k8s.io

die() { printf '\n!!! %s\n' "$*" >&2; exit 1; }
ok()  { printf '    [ok] %s\n' "$*"; }

kubectl version --request-timeout=10s >/dev/null 2>&1 || die "kubectl cannot reach a cluster (KUBECONFIG?)"
kubectl -n kserve get deploy kserve-controller-manager >/dev/null 2>&1 \
  || die "KServe controller not found in namespace kserve - install KServe first"
# Captured first, then matched: with pipefail, `kubectl ... | grep -q` can
# report failure when grep exits early and kubectl gets SIGPIPE.
kv="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')"
if [[ "$kv" == *+k3s* ]]; then PLATFORM=k3s; else PLATFORM=kind; fi
echo "== platform: $PLATFORM"

echo "== 1. Prometheus"
kubectl apply -f "${REPO_ROOT}/manifests/prometheus.yaml" >/dev/null
kubectl -n monitoring rollout status deploy/prometheus --timeout=5m
ok "Prometheus (monitoring/prometheus:9090)"

echo "== 2. guard: one provider for external.metrics.k8s.io"
if kubectl get apiservice "$APISVC" >/dev/null 2>&1; then
  owner="$(kubectl get apiservice "$APISVC" -o jsonpath='{.spec.service.namespace}/{.spec.service.name}')"
  [[ "$owner" == "keda/keda-metrics-apiserver" ]] \
    || die "REFUSED: $APISVC is already served by '$owner', not KEDA. Remove it or stop here."
  ok "already served by KEDA (re-run)"
else
  ok "no provider yet"
fi

echo "== 3. KEDA v${KEDA_VERSION}"
mkdir -p "$KEDA_CACHE"
f="${KEDA_CACHE}/keda-${KEDA_VERSION}.yaml"
[[ -f "$f" ]] || curl -fsSL -o "$f" "$KEDA_URL" || die "download failed: $KEDA_URL"
echo "${KEDA_SHA256}  $f" | sha256sum -c --quiet - \
  || { rm -f "$f"; die "sha256 mismatch for $f (deleted) - not applying"; }
ok "keda-${KEDA_VERSION}.yaml sha256 verified"
kubectl apply --server-side -f "$f" >/dev/null
kubectl -n keda rollout status deploy --timeout=5m
kubectl wait --for=condition=Available "apiservice/$APISVC" --timeout=3m >/dev/null
owner="$(kubectl get apiservice "$APISVC" -o jsonpath='{.spec.service.namespace}/{.spec.service.name}')"
[[ "$owner" == "keda/keda-metrics-apiserver" ]] || die "$APISVC is served by '$owner' after install"
ok "KEDA running; $APISVC Available, served by KEDA"

echo "== 4. restart the KServe controller (it checks for KEDA CRDs only at start)"
kubectl -n kserve rollout restart deploy/kserve-controller-manager >/dev/null
kubectl -n kserve rollout status deploy/kserve-controller-manager --timeout=5m
seen=0
for _ in $(seq 1 12); do
  logs="$(kubectl -n kserve logs deploy/kserve-controller-manager -c manager --since=5m 2>/dev/null || true)"
  [[ "$logs" == *v1alpha1.ScaledObject* ]] && { seen=1; break; }
  sleep 5
done
(( seen )) || die "KServe controller restarted but does not log a ScaledObject watch - check its logs"
ok "KServe controller watches ScaledObjects"

echo "== 5. HPA sync period (time-to-relief stage 4)"
flag=horizontal-pod-autoscaler-sync-period
if [[ "$PLATFORM" == kind ]]; then
  v="$(docker exec llm-serving-lab-control-plane sh -c 'ps -o args= -C kube-controller-manager' \
        | tr ' ' '\n' | grep -- "--$flag" || true)"
else
  v="$(grep -rhs -- "$flag" /etc/rancher/k3s/ /etc/systemd/system/k3s.service* 2>/dev/null || true)"
fi
if [[ -n "$v" ]]; then echo "    override found: $v"; else ok "no override -> Kubernetes default 15s"; fi

echo "== done: apply a KEDA ISVC, then check its ScaledObject threshold and HPA type (AverageValue)"
