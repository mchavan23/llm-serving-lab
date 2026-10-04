#!/usr/bin/env bash
#
# scripts/verify-gpu.sh - check every layer of the GPU node, bottom to top.
#
# The GPU-cluster sibling of verify.sh (which is kind-specific). Runs ON THE
# VM - it needs nvidia-smi and reaches ClusterIPs directly. From the laptop:
#   ssh root@<vm> 'cd /root/llm-serving-lab && scripts/verify-gpu.sh'
#
# Read-only. PASS/FAIL per check, exits non-zero if anything is broken, so a
# FAIL names the LAYER at fault before any debugging starts.

fails=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fails=$((fails+1)); }
info() { printf '        %s\n' "$1"; }
hdr()  { printf '\n== %s ==\n' "$1"; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2
export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
# shellcheck source=scripts/variants.sh
. "$REPO_ROOT/scripts/variants.sh"
. "$REPO_ROOT/scripts/lib-pods.sh"

# Expected values - the recorded platform. A mismatch is a FAIL, because
# numbers from a different platform are not comparable (week 6).
EXPECTED_GPU="${EXPECTED_GPU:-L40S}"
EXPECTED_DRIVER="${EXPECTED_DRIVER:-580.126.20}"
EXPECTED_K3S="${EXPECTED_K3S:-v1.36.4+k3s1}"
K3S_CONTAINERD_CONFIG=/var/lib/rancher/k3s/agent/etc/containerd/config.toml

# --- 1. tooling ---------------------------------------------------------------
hdr "1. tooling"
for t in kubectl helm uv jq curl; do
  command -v "$t" >/dev/null 2>&1 && ok "$t -> $(command -v "$t")" || bad "$t not on PATH"
done
k3sv="$(k3s --version 2>/dev/null | head -1 | awk '{print $3}')"
[ "$k3sv" = "$EXPECTED_K3S" ] && ok "k3s $k3sv (pinned)" || bad "k3s '$k3sv', expected $EXPECTED_K3S"

# --- 2. GPU host -----------------------------------------------------------------
hdr "2. gpu host"
gpus="$(nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader 2>/dev/null)"
ngpu=$(printf '%s' "$gpus" | grep -c .)
# EVERY GPU must match, not just the first: on a multi-GPU instance a bad
# second card would otherwise pass.
nmatch=$(awk -v g="$EXPECTED_GPU" -v d="$EXPECTED_DRIVER" 'index($0, g) && index($0, d)' <<<"$gpus" | grep -c .)
if [ "$ngpu" -gt 0 ] && [ "$nmatch" -eq "$ngpu" ]; then
  ok "$ngpu x $(head -1 <<<"$gpus")"
else
  bad "$nmatch of $ngpu GPU(s) match ${EXPECTED_GPU} / driver ${EXPECTED_DRIVER}: $(tr '\n' ';' <<<"${gpus:-nothing}")"
fi
# The host cannot know how many GPUs the instance type SHOULD have. Set
# EXPECTED_GPU_COUNT (2 on L40S-2-48G) to catch a card that failed to appear.
if [ -n "${EXPECTED_GPU_COUNT:-}" ]; then
  [ "$ngpu" = "$EXPECTED_GPU_COUNT" ] && ok "GPU count $ngpu = EXPECTED_GPU_COUNT" \
    || bad "host sees $ngpu GPU(s), EXPECTED_GPU_COUNT=$EXPECTED_GPU_COUNT"
else
  info "GPU count $ngpu (set EXPECTED_GPU_COUNT to assert it)"
fi

# --- 3. k3s + GPU plumbing -----------------------------------------------------------
hdr "3. k3s and the gpu path"
[ "$(kubectl get nodes -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = "True" ] \
  && ok "node Ready" || bad "node not Ready"
# THE check this project exists to get right: nvidia must be the DEFAULT
# handler, because a KServe predictor pod cannot name a RuntimeClass. Read
# the RENDERED config - k3s regenerates it at every start.
if grep -Eq "^[[:space:]]*default_runtime_name[[:space:]]*=[[:space:]]*['\"]nvidia['\"]" "$K3S_CONTAINERD_CONFIG" 2>/dev/null; then
  ok "nvidia is the DEFAULT containerd handler (rendered config)"
else
  bad "nvidia is NOT the default handler in $K3S_CONTAINERD_CONFIG - predictor pods would get runc and no GPU"
fi
kubectl get runtimeclass nvidia >/dev/null 2>&1 && ok "RuntimeClass nvidia present" || bad "RuntimeClass nvidia missing"
alloc="$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.nvidia\.com/gpu}' 2>/dev/null)"
# The device plugin must advertise every GPU the driver sees - no more, no fewer.
[ -n "$alloc" ] && [ "$alloc" = "$ngpu" ] && ok "allocatable nvidia.com/gpu = $alloc (= GPUs on the host)" \
  || bad "allocatable nvidia.com/gpu = '${alloc}', host sees $ngpu"

# --- 4. exposure -------------------------------------------------------------------------
# On this node a NodePort or LoadBalancer binds the PUBLIC IP. The provider
# firewall is then the only thing between it and the internet - an open
# inference endpoint gets found and used within hours. There must be none.
hdr "4. exposure"
exposed="$(kubectl get svc -A -o json 2>/dev/null \
  | jq -r '.items[] | select(.spec.type=="NodePort" or .spec.type=="LoadBalancer") | "\(.metadata.namespace)/\(.metadata.name) (\(.spec.type))"')"
[ -z "$exposed" ] && ok "no NodePort / LoadBalancer Services" || bad "exposed on the public IP: $(echo $exposed)"

# --- 5. S3 store ---------------------------------------------------------------------------
hdr "5. s3 store (seaweedfs)"
swpod="$(one_live_pod seaweedfs app=seaweedfs)" && ok "one live pod ($swpod)" || bad "not exactly one live seaweedfs pod (details above)"
[ "$(kubectl -n seaweedfs get pvc seaweedfs-data -o jsonpath='{.status.phase}' 2>/dev/null)" = "Bound" ] \
  && ok "PVC Bound" || bad "PVC not Bound"
s3ip="$(kubectl -n seaweedfs get svc seaweedfs-s3 -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
# 403 + AccessDenied to an unsigned request = answered AND anonymous closed.
code="$(curl -s -o /tmp/_s3 -w '%{http_code}' --max-time 5 "http://${s3ip}:8333/" 2>/dev/null)"
if [ "$code" = "403" ] && grep -q AccessDenied /tmp/_s3 2>/dev/null; then
  ok "S3 API on ${s3ip}:8333 (403 AccessDenied = healthy)"
else
  bad "S3 API on ${s3ip:-?}:8333 returned '${code}' (expected 403 + AccessDenied)"
fi
rm -f /tmp/_s3

# --- 6. model objects ------------------------------------------------------------------------
hdr "6. model objects (all four legs)"
prefixes=""; for v in "${VARIANTS[@]}"; do prefixes+="${v##*|} "; done
# upload_model.py reads the endpoint from .env; stage-models.sh points it at
# the ClusterIP. Every leg needs its config and at least one weights shard.
# One FAIL for the section if any leg is incomplete OR S3 cannot be listed
# (python exits non-zero on either); the lines above name which.
uv run python - $prefixes <<'PY' 2>&1 | sed 's/^/  /'
import sys; sys.path.insert(0, "scripts")
from upload_model import read_env, make_client, ENV_FILE
env = read_env(ENV_FILE); s3 = make_client(env); bad = 0
for prefix in sys.argv[1:]:
    objs = []
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=env["S3_BUCKET"], Prefix=prefix + "/"):
        objs += page.get("Contents", [])
    names = {o["Key"].rsplit("/", 1)[-1] for o in objs}
    gib = sum(o["Size"] for o in objs) / 2**30
    if "config.json" in names and any(n.endswith(".safetensors") for n in names):
        print(f"\033[32mPASS\033[0m  {prefix}: {len(objs)} objects, {gib:.2f} GiB")
    else:
        print(f"\033[31mFAIL\033[0m  {prefix}: {len(objs)} objects - missing config.json or .safetensors"); bad += 1
sys.exit(1 if bad else 0)
PY
[ "${PIPESTATUS[0]}" = "0" ] || fails=$((fails+1))

# --- 7. KServe control plane -------------------------------------------------------------------
hdr "7. kserve control plane"
for d in cert-manager cert-manager-webhook cert-manager-cainjector; do
  [ "$(kubectl -n cert-manager get deploy "$d" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = "1" ] \
    && ok "$d ready" || bad "$d not ready"
done
[ "$(kubectl -n kserve get deploy kserve-controller-manager -o jsonpath='{.status.readyReplicas}' 2>/dev/null)" = "1" ] \
  && ok "kserve-controller-manager ready" || bad "kserve-controller-manager not ready"
mode="$(kubectl -n kserve get cm inferenceservice-config -o jsonpath='{.data.deploy}' 2>/dev/null | jq -r '.defaultDeploymentMode' 2>/dev/null)"
[ "$mode" = "Standard" ] && ok "deploymentMode Standard" || bad "deploymentMode '${mode}'"
kubectl get clusterservingruntime vllm-gpu-runtime >/dev/null 2>&1 \
  && ok "ClusterServingRuntime vllm-gpu-runtime present" || bad "vllm-gpu-runtime missing"

# --- 8. inference, per InferenceService ----------------------------------------------------------
hdr "8. inference"
isvcs="$(kubectl -n llm-serving get isvc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"
[ -n "$isvcs" ] || bad "no InferenceService in llm-serving - nothing is being served"
for i in $isvcs; do
  info "--- $i"
  [ "$(kubectl -n llm-serving get isvc "$i" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = "True" ] \
    && ok "$i Ready" || bad "$i not Ready"
  # Recreate, not RollingUpdate: a rollout starts the new pod before the old one
  # frees its GPU, so whenever every GPU is in use (1 replica on 1 GPU, or 2 on
  # 2) the new pod is Pending forever. Observed 2026-09-27. Scaling - KEDA
  # changing replicas - does not go through the strategy, so this does not
  # limit scale-out.
  strat="$(kubectl -n llm-serving get deploy "${i}-predictor" -o jsonpath='{.spec.strategy.type}' 2>/dev/null)"
  [ "$strat" = "Recreate" ] && ok "$i strategy Recreate" || bad "$i strategy '${strat}' - must be Recreate (see comment above)"
  # Must NOT name a RuntimeClass: if it does, a pass here would hide a broken
  # default handler, which is what every other predictor relies on.
  if p="$(one_live_pod llm-serving "serving.kserve.io/inferenceservice=$i")"; then
    rc="$(kubectl -n llm-serving get pod "$p" -o jsonpath='{.spec.runtimeClassName}' 2>/dev/null)"
    [ -z "$rc" ] && ok "$i pod has no runtimeClassName (gets the default handler)" || bad "$i pod names runtimeClassName '$rc'"
  else
    bad "$i: not exactly one live pod (details above)"
  fi
  ip="$(kubectl -n llm-serving get svc "${i}-predictor" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)"
  port="$(kubectl -n llm-serving get svc "${i}-predictor" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)"
  base="http://${ip}:${port}"
  served="$(curl -s --max-time 10 "$base/v1/models" | jq -r '.data[0].id' 2>/dev/null)"
  [ "$served" = "$i" ] && ok "$i serves model id '$served'" || bad "$i /v1/models returned '${served}'"
  reply="$(curl -s --max-time 60 "$base/v1/chat/completions" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$i\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word OK.\"}],\"max_tokens\":5,\"temperature\":0}" \
    | jq -r '.choices[0].message.content' 2>/dev/null)"
  [ -n "$reply" ] && [ "$reply" != "null" ] && ok "$i generation works: '${reply}'" || bad "$i generation failed"
  m="$(curl -s --max-time 10 "$base/metrics")"
  grep -q '^vllm:num_requests_waiting{' <<<"$m" && ok "$i /metrics: vllm:num_requests_waiting" || bad "$i /metrics lacks num_requests_waiting"
  grep -q '^vllm:time_to_first_token_seconds_bucket' <<<"$m" && ok "$i /metrics: TTFT histogram" || bad "$i /metrics lacks the TTFT histogram"
done

# --- summary --------------------------------------------------------------------------------------
hdr "summary"
if [ "$fails" -eq 0 ]; then
  printf '  \033[32mall checks passed\033[0m\n'
else
  printf '  \033[31m%d check(s) failed\033[0m\n' "$fails"
fi
exit $(( fails > 0 ))
