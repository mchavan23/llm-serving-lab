#!/usr/bin/env bash
# =============================================================================
# stage-models.sh -- ON THE GPU NODE: SeaweedFS (S3) on k3s, then the four weight
# variants  Hugging Face -> local staging -> S3  (week 3, Phase D step 7).
#
#   scripts/stage-models.sh
#
# Staging is the Hugging Face cache on the ROOT volume, and it is KEPT after
# upload (context doc A3): a re-upload then costs nothing, and the local copy
# is what the S3 copy is verified against. Idempotent: S3 install, downloads and
# uploads all skip or resume. Needs .env (gitignored) next to the repo with
# HF_TOKEN and the MINIO_* keys.
# =============================================================================
set -euo pipefail

UV_VERSION="${UV_VERSION:-0.12.13}"          # same as the laptop

# The four legs live in ONE file, shared with verify-gpu.sh.
# shellcheck source=scripts/variants.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/variants.sh"

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

# ---- 2. S3 store: SeaweedFS ----------------------------------------------------
# MinIO's images stopped being publicly pullable in September 2026; SeaweedFS
# replaced it (proven on the laptop kind cluster first, 2026-09-27).
say "2. SeaweedFS (S3)"
"${REPO_ROOT}/scripts/install-seaweedfs.sh"      # no --kind: ClusterIP only here
# The node reaches the ClusterIP directly. Point .env at it, so upload_model.py
# (which reads .env only) needs no change from the laptop version.
S3_IP="$(kubectl -n seaweedfs get svc seaweedfs-s3 -o jsonpath='{.spec.clusterIP}')"
[[ -n "$S3_IP" ]] || die "no ClusterIP on svc/seaweedfs-s3"
sed -i "s#^MINIO_ENDPOINT=.*#MINIO_ENDPOINT=http://${S3_IP}:8333#" "$ENV_FILE"
for _ in $(seq 1 24); do curl -s -o /dev/null --max-time 3 "http://${S3_IP}:8333/" && break; sleep 5; done
curl -s -o /dev/null --max-time 3 "http://${S3_IP}:8333/" || die "SeaweedFS S3 not answering on ${S3_IP}:8333"
ok "S3 live at http://${S3_IP}:8333 (ClusterIP only)"
# KServe's storage-initializer credentials + in-cluster endpoint.
"${REPO_ROOT}/scripts/create-s3-secret.sh" >/dev/null
ok "KServe S3 secret -> seaweedfs-s3.seaweedfs.svc.cluster.local:8333"

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
  # Verify: same file count and same total bytes locally and in S3.
  uv run python - "$snap" "$prefix" <<'PY' || die "S3 copy of ${prefix} does not match staging"
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
