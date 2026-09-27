#!/usr/bin/env bash
# =============================================================================
# stage-models.sh -- ON THE GPU NODE: MinIO on k3s, then the four weight
# variants  Hugging Face -> local staging -> MinIO  (week 3, Phase D step 7).
#
#   scripts/stage-models.sh
#
# Staging is the Hugging Face cache on the ROOT volume, and it is KEPT after
# upload (context doc A3): a re-upload then costs nothing, and the local copy
# is what MinIO is verified against. Idempotent: MinIO install, downloads and
# uploads all skip or resume. Needs .env (gitignored) next to the repo with
# HF_TOKEN and the MINIO_* keys.
# =============================================================================
set -euo pipefail

UV_VERSION="${UV_VERSION:-0.12.13}"          # same as the laptop
MINIO_CHART_VERSION="${MINIO_CHART_VERSION:-5.4.0}"   # same as week 2

# repo | prefix in the bucket
VARIANTS=(
  "meta-llama/Llama-3.1-8B-Instruct|llama-3.1-8b-bf16"
  "RedHatAI/Meta-Llama-3.1-8B-Instruct-FP8|llama-3.1-8b-fp8"
  "RedHatAI/Meta-Llama-3.1-8B-Instruct-quantized.w4a16|llama-3.1-8b-w4a16-gptq"
  "hugging-quants/Meta-Llama-3.1-8B-Instruct-AWQ-INT4|llama-3.1-8b-w4a16-awq"
)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

say() { printf '\n==> %s\n' "$*"; }
ok()  { printf '    [ok] %s\n' "$*"; }
die() { printf '\n!!! %s\n' "$*" >&2; exit 1; }
# Read one KEY from .env without sourcing it (see NOTES: the 2026-09-13 leak).
envget() { grep -m1 "^$1=" "$ENV_FILE" | cut -d= -f2-; }

[[ -r "$ENV_FILE" ]] || die "missing ${ENV_FILE} (copy it from the laptop; it is gitignored)"
for k in HF_TOKEN MINIO_ROOT_USER MINIO_ROOT_PASSWORD MINIO_BUCKET; do
  [[ -n "$(envget "$k")" ]] || die "${k} unset in ${ENV_FILE}"
done

# ---- 1. uv (detect, install pinned if absent) --------------------------------
say "1. uv ${UV_VERSION}"
if command -v uv >/dev/null && uv --version | grep -q " ${UV_VERSION}"; then
  ok "already present: $(uv --version)"
else
  curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" \
    | env UV_INSTALL_DIR=/usr/local/bin INSTALLER_NO_MODIFY_PATH=1 sh
  ok "installed: $(uv --version)"
fi
( cd "$REPO_ROOT" && uv sync --quiet ) || die "uv sync failed"
ok "python env: $(cd "$REPO_ROOT" && uv run python --version)"

# ---- 2. MinIO ------------------------------------------------------------------
say "2. MinIO (chart ${MINIO_CHART_VERSION})"
if helm status minio -n minio >/dev/null 2>&1; then
  ok "already installed"
else
  helm repo add minio https://charts.min.io/ >/dev/null 2>&1 || true
  helm repo update minio >/dev/null
  helm upgrade --install minio minio/minio \
    --namespace minio --create-namespace --version "${MINIO_CHART_VERSION}" \
    --values "${REPO_ROOT}/manifests/minio-values.yaml" \
    --values "${REPO_ROOT}/manifests/minio-values-gpu.yaml" \
    --set rootUser="$(envget MINIO_ROOT_USER)" \
    --set rootPassword="$(envget MINIO_ROOT_PASSWORD)" \
    --wait --timeout 5m
fi
kubectl -n minio rollout status deploy/minio --timeout=5m
# The node reaches the ClusterIP directly. Point .env at it, so upload_model.py
# (which reads .env only) needs no change from the laptop version.
MINIO_IP="$(kubectl -n minio get svc minio -o jsonpath='{.spec.clusterIP}')"
[[ -n "$MINIO_IP" ]] || die "no ClusterIP on svc/minio"
sed -i "s#^MINIO_ENDPOINT=.*#MINIO_ENDPOINT=http://${MINIO_IP}:9000#" "$ENV_FILE"
curl -fsS -o /dev/null "http://${MINIO_IP}:9000/minio/health/live" \
  || die "MinIO not answering on ${MINIO_IP}:9000"
ok "MinIO live at http://${MINIO_IP}:9000 (ClusterIP only)"

# ---- 3. download, upload, verify -------------------------------------------------
export HF_TOKEN; HF_TOKEN="$(envget HF_TOKEN)"
cd "$REPO_ROOT"
for v in "${VARIANTS[@]}"; do
  repo="${v%%|*}"; prefix="${v##*|}"
  say "3. ${repo}  ->  s3://$(envget MINIO_BUCKET)/${prefix}/"
  t0=$(date +%s)
  # original/* is Meta's raw PyTorch checkpoint (14.96 GiB). vLLM never reads
  # it (Phase A pre-flight), so excluding it halves the BF16 leg.
  # hf download resumes and skips files already cached; --quiet prints only
  # the local snapshot path.
  snap="$(uv run hf download "$repo" --exclude 'original/*' --quiet | tail -1)"
  [[ -d "$snap" ]] || die "download of ${repo} did not return a directory (got: ${snap})"
  ok "staged in $(( $(date +%s) - t0 )) s: ${snap} ($(du -shL "$snap" | cut -f1))"
  t0=$(date +%s)
  uv run python scripts/upload_model.py "$snap" "$prefix" | tail -1
  ok "uploaded in $(( $(date +%s) - t0 )) s"
  # Verify: same file count and same total bytes locally and in MinIO.
  uv run python - "$snap" "$prefix" <<'PY' || die "MinIO copy of ${prefix} does not match staging"
import sys, pathlib
sys.path.insert(0, "scripts")
from upload_model import read_env, make_client, ENV_FILE
snap, prefix = pathlib.Path(sys.argv[1]), sys.argv[2]
env = read_env(ENV_FILE)
local = {p.relative_to(snap).as_posix(): p.stat().st_size
         for p in snap.rglob("*") if p.is_file()
         and not any(x.startswith(".") for x in p.relative_to(snap).parts)}
s3, remote = make_client(env), {}
for page in s3.get_paginator("list_objects_v2").paginate(Bucket=env["MINIO_BUCKET"], Prefix=prefix + "/"):
    for o in page.get("Contents", []):
        remote[o["Key"][len(prefix) + 1:]] = o["Size"]
if local != remote:
    print(f"    MISMATCH local={len(local)} files remote={len(remote)} files", file=sys.stderr)
    sys.exit(1)
print(f"    [ok] verified: {len(local)} files, {sum(local.values())/2**30:.2f} GiB match")
PY
done

say "DONE"
df -h / | tail -1 | sed 's/^/    root volume: /'
