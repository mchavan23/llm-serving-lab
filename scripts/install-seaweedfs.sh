#!/usr/bin/env bash
# =============================================================================
# install-seaweedfs.sh -- the S3 store for model weights, on EITHER cluster.
#
#   scripts/install-seaweedfs.sh          # GPU node (k3s): ClusterIP only
#   scripts/install-seaweedfs.sh --kind   # laptop: also NodePort 30900 -> :9000
#
# Credentials come from .env (S3_ACCESS_KEY_ID / S3_SECRET_ACCESS_KEY).
# Idempotent.
# =============================================================================
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
KIND=0; [[ "${1:-}" == "--kind" ]] && KIND=1

die() { printf '\n!!! %s\n' "$*" >&2; exit 1; }
envget() { grep -m1 "^$1=" "$ENV_FILE" | cut -d= -f2-; }   # never source .env
[[ -r "$ENV_FILE" ]] || die "missing $ENV_FILE"
AK="$(envget S3_ACCESS_KEY_ID)"; SK="$(envget S3_SECRET_ACCESS_KEY)"
[[ -n "$AK" && -n "$SK" ]] || die "S3_ACCESS_KEY_ID / S3_SECRET_ACCESS_KEY unset in .env"

kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Namespace
metadata: {name: seaweedfs}
YAML

# s3.json: one identity with full rights on this store. Built with jq so a
# secret containing quotes or backslashes cannot break the JSON.
# SERVER-SIDE apply: client-side `kubectl apply` copies the whole object,
# credentials included, into the last-applied-configuration annotation,
# where any `kubectl get -o yaml` prints it. Found the hard way 2026-09-27.
jq -n --arg ak "$AK" --arg sk "$SK" '{identities: [{
        name: "llm-serving-lab",
        credentials: [{accessKey: $ak, secretKey: $sk}],
        actions: ["Admin", "Read", "Write", "List", "Tagging"]}]}' \
  | kubectl create secret generic seaweedfs-s3-config -n seaweedfs \
      --from-file=s3.json=/dev/stdin --dry-run=client -o yaml \
  | kubectl apply --server-side --force-conflicts -f - >/dev/null
echo "    [ok] secret seaweedfs-s3-config (server-side apply, no last-applied copy)"

kubectl apply -f "${REPO_ROOT}/manifests/seaweedfs.yaml"
(( KIND )) && kubectl apply -f "${REPO_ROOT}/manifests/seaweedfs-nodeport-kind.yaml"
# The Secret is read once at start: restart so a rotated credential takes effect.
kubectl -n seaweedfs rollout restart deploy/seaweedfs >/dev/null
kubectl -n seaweedfs rollout status deploy/seaweedfs --timeout=5m
echo "    [ok] SeaweedFS S3 at seaweedfs-s3.seaweedfs.svc.cluster.local:8333"
