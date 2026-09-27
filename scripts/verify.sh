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

# --- 4. s3 store (SeaweedFS; replaced MinIO 2026-09-27) --------------------
hdr "4. s3 store (seaweedfs)"
phase="$(kubectl -n seaweedfs get pod -l app=seaweedfs -o jsonpath='{.items[0].status.phase}' 2>/dev/null)"
[ "$phase" = "Running" ] && ok "pod Running" || bad "pod phase='$phase'"
[ "$(kubectl -n seaweedfs get pvc seaweedfs-data -o jsonpath='{.status.phase}' 2>/dev/null)" = "Bound" ] \
  && ok "PVC Bound" || bad "PVC not Bound"
# 403 + AccessDenied XML is the CORRECT answer to an unsigned request: it
# proves the S3 server answered AND that anonymous access is closed. Connection
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

# --- 6. KServe control plane ----------------------------------------------
hdr "6. kserve control plane"
if ! kubectl get ns kserve >/dev/null 2>&1; then
  skip "kserve not installed - see RUNBOOK.md step 6"
else
  for d in cert-manager cert-manager-webhook cert-manager-cainjector; do
    rdy="$(kubectl get deploy "$d" -n cert-manager -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
    [ "${rdy:-0}" -ge 1 ] && ok "$d ready" || bad "$d not ready"
  done

  # cainjector only COPIES a CA; it cannot invent one. An empty caBundle here
  # means either cainjector is down or the source Certificate never issued.
  cb="$(kubectl get validatingwebhookconfiguration inferenceservice.serving.kserve.io \
        -o jsonpath='{.webhooks[0].clientConfig.caBundle}' 2>/dev/null | wc -c)"
  [ "$cb" -gt 100 ] && ok "KServe webhook caBundle populated ($cb chars)" \
                    || bad "KServe webhook caBundle EMPTY - check: kubectl get certificate -n kserve"

  rdy="$(kubectl get deploy kserve-controller-manager -n kserve -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  [ "${rdy:-0}" -ge 1 ] && ok "kserve-controller-manager ready" || bad "kserve controller not ready"

  mode="$(kubectl get cm inferenceservice-config -n kserve \
          -o jsonpath='{.data.deploy}' 2>/dev/null | tr -d ' \n')"
  case "$mode" in
    *Standard*) ok "deploymentMode Standard" ;;
    *) bad "deploymentMode is not Standard: $mode" ;;
  esac

  kubectl get clusterservingruntime vllm-cpu-runtime >/dev/null 2>&1 \
    && ok "ClusterServingRuntime vllm-cpu-runtime present" \
    || bad "ClusterServingRuntime vllm-cpu-runtime missing"

  # `crictl images` listing the image is NOT proof the content is complete.
  if docker exec llm-serving-lab-control-plane ctr -n k8s.io images check 2>/dev/null \
       | grep -q 'vllm-cpu-release-repo.*true'; then
    ok "vLLM image fully loaded on the node"
  else
    bad "vLLM image missing or incomplete on the node - re-run 'kind load docker-image'"
  fi
fi

# --- 7. inference endpoint -------------------------------------------------
hdr "7. inference endpoint"
if ! kubectl get isvc qwen-0-5b -n llm-serving >/dev/null 2>&1; then
  skip "InferenceService qwen-0-5b not deployed - see RUNBOOK.md step 6d"
else
  ready="$(kubectl get isvc qwen-0-5b -n llm-serving \
           -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)"
  [ "$ready" = "True" ] && ok "InferenceService Ready" \
    || bad "InferenceService not Ready - if the pod is 1/1, suspect a stuck Ingress"

  eps="$(kubectl get endpointslice -n llm-serving \
         -l kubernetes.io/service-name=qwen-0-5b-nodeport \
         -o jsonpath='{.items[*].endpoints[*].addresses[0]}' 2>/dev/null)"
  [ -n "$eps" ] && ok "NodePort endpoints: $eps" \
                || bad "qwen-0-5b-nodeport has NO endpoints - check the selector"

  # The served id comes from --served-model-name={{.Name}}; it is qwen-0-5b
  # with HYPHENS. Week 1 used qwen-0.5b with a dot. Mismatch = 404.
  served="$(curl -s --max-time 10 http://localhost:8080/v1/models \
            | python3 -c 'import sys,json; print(json.load(sys.stdin)["data"][0]["id"])' 2>/dev/null)"
  if [ -n "$served" ]; then
    ok "/v1/models serves '$served' via host port 8080"
  else
    bad "no answer on localhost:8080/v1/models"
  fi

  # End-to-end generation. Allow 300s: an unseen batch shape triggers a fresh
  # torch.compile pass, which is a minute on CPU even with a warm cache.
  if [ -n "$served" ]; then
    txt="$(curl -s --max-time 300 http://localhost:8080/v1/chat/completions \
          -H 'Content-Type: application/json' \
          -d '{"model":"'"$served"'","messages":[{"role":"user","content":"Say OK"}],"max_tokens":5,"temperature":0}' \
          | python3 -c 'import sys,json; print(json.load(sys.stdin)["choices"][0]["message"]["content"])' 2>/dev/null)"
    [ -n "$txt" ] && ok "generation works: '$(echo "$txt" | tr -d '\n' | cut -c1-40)'" \
                  || bad "generation returned nothing"
  fi
fi

# --- summary ---------------------------------------------------------------
printf '\n== summary ==\n'
if [ "$fails" -eq 0 ]; then
  printf '  \033[32mall checks passed\033[0m\n'; exit 0
else
  printf '  \033[31m%d check(s) failed\033[0m\n' "$fails"; exit 1
fi
