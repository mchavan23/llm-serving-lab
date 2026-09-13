#!/usr/bin/env bash
#
# scripts/verify.sh - check every layer of the week 1 substrate.
#
# Read-only. Prints PASS/FAIL per check and exits non-zero if anything
# essential is broken. Run this after a WSL restart, or any time something
# behaves oddly, to find out WHICH layer is at fault before debugging.

fails=0

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fails=$((fails+1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }
hdr()  { printf '\n== %s ==\n' "$1"; }

# --- 1. tools --------------------------------------------------------------
hdr "1. tooling"
for t in kubectl helm kind uv docker; do
  if command -v "$t" >/dev/null 2>&1; then
    ok "$t -> $(command -v "$t")"
  else
    bad "$t not on PATH"
  fi
done
kubectl version --client 2>/dev/null | head -1 | sed 's/^/        /'
helm version --short 2>/dev/null | sed 's/^/        /'
kind version 2>/dev/null | sed 's/^/        /'

# --- 2. docker -------------------------------------------------------------
hdr "2. docker daemon"
if docker info >/dev/null 2>&1; then
  ok "daemon reachable (server $(docker version --format '{{.Server.Version}}'))"
else
  bad "docker daemon unreachable - is Docker Desktop running?"
fi

# --- 3. kind cluster -------------------------------------------------------
hdr "3. kind cluster"
if kind get clusters 2>/dev/null | grep -qx llm-serving-lab; then
  ok "cluster 'llm-serving-lab' exists"
else
  bad "cluster missing - recreate: kind create cluster --config cluster/kind-config.yaml"
fi
# A node can exist but be NotReady, so check the condition, not just presence.
if [ "$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ]; then
  ok "node Ready ($(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}'))"
else
  bad "node not Ready"
fi
# Host->container port plumbing, checked at the Docker layer that owns it.
for p in 8080 9000 9001; do
  if docker port llm-serving-lab-control-plane 2>/dev/null | grep -q ":$p\$"; then
    ok "host port $p published"
  else
    bad "host port $p not published"
  fi
done

# --- 4. minio --------------------------------------------------------------
hdr "4. minio"
phase="$(kubectl -n minio get pod -l app=minio -o jsonpath='{.items[0].status.phase}' 2>/dev/null)"
[ "$phase" = "Running" ] && ok "pod Running" || bad "pod phase='$phase'"
[ "$(kubectl -n minio get pvc minio -o jsonpath='{.status.phase}' 2>/dev/null)" = "Bound" ] \
  && ok "PVC Bound" || bad "PVC not Bound"
# 403 + AccessDenied XML is the CORRECT answer to an unsigned request: it
# proves MinIO answered AND that anonymous access is closed. Connection
# refused would mean the port chain is broken. 200 would mean it is wide open.
code="$(curl -s -o /tmp/_s3 -w '%{http_code}' --max-time 5 http://localhost:9000/ 2>/dev/null)"
if [ "$code" = "403" ] && grep -q AccessDenied /tmp/_s3 2>/dev/null; then
  ok "S3 API on :9000 (403 AccessDenied = healthy)"
else
  bad "S3 API on :9000 returned '$code' (expected 403 + AccessDenied)"
fi
rm -f /tmp/_s3

# --- 5. python + model in s3 ----------------------------------------------
hdr "5. python env and model objects"
if uv run python -c "import boto3" 2>/dev/null; then
  ok "boto3 importable via uv"
  uv run python - <<'PY' 2>/dev/null || bad "could not list s3://models/qwen-0.5b/"
import sys; sys.path.insert(0, "scripts")
from pathlib import Path
from upload_model import read_env, make_client
env = read_env(Path(".env"))
objs = make_client(env).list_objects_v2(
    Bucket=env["MINIO_BUCKET"], Prefix="qwen-0.5b/").get("Contents", [])
total = sum(o["Size"] for o in objs)
need = {"config.json", "model.safetensors", "tokenizer.json"}
have = {o["Key"].split("/")[-1] for o in objs}
missing = need - have
print(f"  \033[32mPASS\033[0m  {len(objs)} objects, {total/2**30:.2f} GiB in s3://models/qwen-0.5b/")
if missing:
    print(f"  \033[31mFAIL\033[0m  missing essential files: {missing}"); raise SystemExit(1)
print(f"  \033[32mPASS\033[0m  essential model files present")
PY
else
  bad "boto3 not importable - run 'uv sync'"
fi

# --- 6. vllm (optional) ----------------------------------------------------
hdr "6. vllm serving (optional)"
if ! docker ps --format '{{.Names}}' | grep -qx vllm-cpu; then
  skip "container 'vllm-cpu' not running - see NOTES.md for the docker run line"
elif [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:8000/health)" = "200" ]; then
  ok "/health 200"
  served="$(curl -s --max-time 5 http://localhost:8000/v1/models \
            | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"][0]["id"])' 2>/dev/null)"
  [ -n "$served" ] && ok "/v1/models serves '$served'" || bad "/v1/models unparseable"
  # End-to-end: does it actually generate? Slow on CPU, so allow 120s.
  txt="$(curl -s --max-time 120 http://localhost:8000/v1/completions \
        -H 'Content-Type: application/json' \
        -d '{"model":"'"$served"'","prompt":"2+2=","max_tokens":5,"temperature":0}' \
        | python3 -c 'import sys,json; print(json.load(sys.stdin)["choices"][0]["text"])' 2>/dev/null)"
  [ -n "$txt" ] && ok "generation works: '$(echo "$txt" | tr -d '\n' | cut -c1-40)'" \
                || bad "generation returned nothing"
else
  bad "container up but /health not 200 - check: docker logs vllm-cpu"
fi

# --- summary ---------------------------------------------------------------
printf '\n== summary ==\n'
if [ "$fails" -eq 0 ]; then
  printf '  \033[32mall checks passed\033[0m\n'; exit 0
else
  printf '  \033[31m%d check(s) failed\033[0m\n' "$fails"; exit 1
fi
