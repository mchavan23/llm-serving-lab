#!/usr/bin/env bash
#
# scripts/preflight-vm.sh - the client-side prerequisites the harness and the
# pilot ASSUME, checked once at Phase B step 2 (after verify-gpu.sh is green).
#
#   scripts/preflight-vm.sh <sweep-config> <isvc>
#   e.g. scripts/preflight-vm.sh benchmarks/configs/sweep-gpu.sh llama-fp8
#
# 1. uv provisions the locked venv: Python 3.13.x, GuideLLM as pinned in uv.lock
# 2. the tokenizer (config's TOKENIZER_REPO @ TOKENIZER_REV) loads OFFLINE,
#    with no token, through GuideLLM's own loader
# 3. /metrics is readable through the API-server proxy (how gauges are read)
# 4. the access log records every request (how the pilot counts arrivals):
#    count, send ONE request, count again -> must rise by exactly 1
# The predictor ClusterIP itself is verify-gpu.sh's job (run just before).
#
# Exit: 0 all pass | 1 a check failed (stops at the first) | 2 usage.
# Reasoning: NOTES.md 2026-10-03, "VM-side prerequisites".

# shellcheck disable=SC2153   # TOKENIZER_* / NAMESPACE come from the sourced config

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2
CONFIG=${1:-}; ISVC=${2:-}
if [ ! -f "$CONFIG" ] || [ -z "$ISVC" ]; then sed -n '6,7p' "$0"; exit 2; fi
# shellcheck source=/dev/null
. "$CONFIG"

if command -v nvidia-smi >/dev/null 2>&1; then
  PLATFORM=gpu; export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
else
  PLATFORM=kind
fi

pass() { printf '  PASS  %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; exit 1; }
echo "preflight ($PLATFORM): config=$CONFIG isvc=$ISVC"

# ---- 1. the locked venv --------------------------------------------------------
# Explicit sync, not left to the first `uv run`: the VM's old .venv is
# Python 3.14 without GuideLLM (session 3 predates the 3.13 + GuideLLM pins).
uv sync --locked --no-progress >/tmp/preflight-sync.log 2>&1 \
  || fail "uv sync --locked (see /tmp/preflight-sync.log)"
read -r pyv glv < <(uv run --locked python -c \
  'import sys, importlib.metadata as m; print(sys.version.split()[0], m.version("guidellm"))')
want_gl=$(awk '/^name = "guidellm"$/ { getline; gsub(/version = |"/, ""); print; exit }' uv.lock)
[[ "$pyv" == 3.13.* ]] || fail "python is $pyv, .python-version wants 3.13"
[ "$glv" = "$want_gl" ] || fail "guidellm $glv, uv.lock pins $want_gl"
pass "venv: python $pyv, guidellm $glv (= uv.lock)"

# ---- 2. tokenizer, offline -----------------------------------------------------
if [ "$TOKENIZER_OFFLINE" = 1 ]; then
  [ -n "$TOKENIZER_REV" ] || fail "offline tokenizer needs a pinned TOKENIZER_REV"
  snap="${HF_HOME:-$HOME/.cache/huggingface}/hub/models--${TOKENIZER_REPO//\//--}/snapshots/$TOKENIZER_REV"
  # The four files transformers fetched for this tokenizer (laptop test,
  # 2026-10-03). -f follows the cache's symlinks into blobs/.
  for f in tokenizer.json tokenizer_config.json special_tokens_map.json config.json; do
    [ -f "$snap/$f" ] || fail "missing $snap/$f"
  done
  pass "tokenizer files present in snapshot $TOKENIZER_REV"
  envp=(env -u HF_TOKEN HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1)
else
  envp=(env)   # kind: online, unpinned (allowed there only)
fi
out=$("${envp[@]}" uv run --locked python - "$TOKENIZER_REPO" "$TOKENIZER_REV" <<'PY' 2>&1
import sys
from guidellm.data.tokenizers.huggingface import HuggingFaceTokenizer, HuggingFaceTokenizerArgs
kw = {"revision": sys.argv[2]} if sys.argv[2] else {}
t = HuggingFaceTokenizer(HuggingFaceTokenizerArgs(model=sys.argv[1], load_kwargs=kw))()
print(len(t), len(t.encode("The quick brown fox jumps over the lazy dog.")))
PY
) || fail "tokenizer load: $(tail -1 <<<"$out")"
read -r vocab ntok <<<"$(tail -1 <<<"$out")"
[ "${vocab:-0}" -gt 0 ] || fail "tokenizer load returned: $out"
pass "tokenizer loads ($([ "$TOKENIZER_OFFLINE" = 1 ] && echo OFFLINE, no token || echo online)): vocab $vocab, sample -> $ntok tokens"

# ---- 3. /metrics through the API-server proxy ----------------------------------
pod=$(kubectl get pod -n "$NAMESPACE" -l "serving.kserve.io/inferenceservice=$ISVC" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$pod" ] || fail "no pod for ISVC $ISVC"
m=$(kubectl get --raw "/api/v1/namespaces/$NAMESPACE/pods/$pod:8080/proxy/metrics" 2>&1) \
  || fail "API-server proxy to $pod:8080/metrics: $(head -1 <<<"$m")"
grep -qE '^vllm:num_requests_waiting[{ ]' <<<"$m" || fail "proxy /metrics lacks vllm:num_requests_waiting"
grep -qE '^vllm:num_requests_running[{ ]' <<<"$m" || fail "proxy /metrics lacks vllm:num_requests_running"
pass "/metrics via API-server proxy: num_requests_waiting + running present"

# ---- 4. the access log counts arrivals -----------------------------------------
# Same target the harness uses: ClusterIP on the VM, the NodePort on kind.
if [ "$PLATFORM" = kind ]; then
  target=http://localhost:8080
else
  target="http://$(kubectl get svc -n "$NAMESPACE" "$ISVC-predictor" \
           -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}')"
fi
count() {   # POST lines in the pod's log over the last hour (pod NAME: -l returns 10 lines)
  kubectl logs -n "$NAMESPACE" "$pod" -c kserve-container --since=1h 2>/dev/null \
    | grep -c 'POST /v1/chat/completions'
}
before=$(count)
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 "$target/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"$ISVC\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply OK.\"}],\"max_tokens\":4}")
[ "$code" = 200 ] || fail "test request to $target returned HTTP $code"
sleep 2   # let the log line land
after=$(count)
[ $((after - before)) -eq 1 ] || fail "access log rose by $((after - before)) for 1 request ($before -> $after)"
pass "access log counts arrivals: $before -> $after for 1 request"

echo "  all preflight checks passed"
