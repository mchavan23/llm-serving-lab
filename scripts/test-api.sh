#!/usr/bin/env bash
# Talk to the KServe-served model from the command line.
#
# P1 week 2, step 10. Reaches the endpoint the same way any external client
# would: kind hostPort 8080 -> nodePort 30800 -> Service -> pod :8080.
#
# Usage:
#   ./scripts/test-api.sh                        # default prompt
#   ./scripts/test-api.sh "Explain etcd briefly"
#   ./scripts/test-api.sh "Write a haiku" 120    # prompt + max_tokens
#   MODEL=other-isvc ./scripts/test-api.sh "hi"
#
# Env overrides: HOST (default localhost:8080), MODEL (default qwen-0-5b).

set -uo pipefail

HOST="${HOST:-localhost:8080}"
MODEL="${MODEL:-qwen-0-5b}"
PROMPT="${1:-In one sentence, what is Kubernetes?}"
MAX_TOKENS="${2:-80}"

command -v jq >/dev/null || { echo "note: jq not installed, printing raw JSON"; }

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
say "1. Is anything listening on $HOST ?"
if ! curl -s --max-time 5 -o /dev/null "http://$HOST/v1/models"; then
  echo "  UNREACHABLE."
  echo "  Check, in this order:"
  echo "    kubectl get isvc  -n llm-serving          # READY should be True"
  echo "    kubectl get pods  -n llm-serving          # should be 1/1"
  echo "    kubectl get svc   qwen-0-5b-nodeport -n llm-serving"
  echo "    kubectl get endpointslice -n llm-serving  # must be non-empty"
  exit 1
fi
echo "  reachable"

# ---------------------------------------------------------------------------
say "2. Which model does the server think it is serving?"
# This id is what the 'model' field below MUST match. It comes from the
# ClusterServingRuntime's --served-model-name={{.Name}}, templated with the
# InferenceService name -- so it is qwen-0-5b with HYPHENS, not week 1's
# qwen-0.5b with a dot. A mismatch returns 404, not a completion.
MODELS_JSON="$(curl -s --max-time 10 "http://$HOST/v1/models")"
if command -v jq >/dev/null; then
  echo "$MODELS_JSON" | jq -r '.data[] | "  id=\(.id)  root=\(.root)  max_model_len=\(.max_model_len)"'
else
  echo "$MODELS_JSON"
fi

# root=/mnt/models is the tell that the weights came from the
# storage-initializer's emptyDir -- i.e. out of MinIO -- rather than from
# anything baked into the image.

# ---------------------------------------------------------------------------
say "3. Chat completion"
echo "  prompt: $PROMPT"
echo "  model : $MODEL   max_tokens: $MAX_TOKENS"
echo

START="$(date +%s.%N)"
RESP="$(curl -s --max-time 300 "http://$HOST/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "$(jq -n --arg m "$MODEL" --arg p "$PROMPT" --argjson n "$MAX_TOKENS" \
        '{model:$m, messages:[{role:"user",content:$p}], max_tokens:$n, temperature:0}' \
        2>/dev/null || printf '{"model":"%s","messages":[{"role":"user","content":"%s"}],"max_tokens":%s,"temperature":0}' \
        "$MODEL" "$PROMPT" "$MAX_TOKENS")")"
END="$(date +%s.%N)"

if command -v jq >/dev/null; then
  if echo "$RESP" | jq -e '.choices' >/dev/null 2>&1; then
    echo "--- reply ---"
    echo "$RESP" | jq -r '.choices[0].message.content'
    echo
    echo "$RESP" | jq -r '"--- usage ---\nprompt=\(.usage.prompt_tokens)  completion=\(.usage.completion_tokens)  total=\(.usage.total_tokens)\nfinish_reason=\(.choices[0].finish_reason)\nserver=\(.system_fingerprint)"'
  else
    echo "--- server returned an error ---"
    echo "$RESP" | jq . 2>/dev/null || echo "$RESP"
    echo
    echo "If this says the model does not exist, compare the id from step 2"
    echo "against MODEL=$MODEL."
    exit 1
  fi
else
  echo "$RESP"
fi

# Wall-clock, NOT a benchmark. It includes curl startup, the four network
# hops, and any torch.compile the server does for an unseen batch shape.
# Real numbers come from GuideLLM on the GPU (week 5), with warmup requests
# discarded -- see NOTES.md "Timings - and why they are not benchmarks".
awk -v s="$START" -v e="$END" 'BEGIN { printf "\nwall clock: %.2f s  (indicative only, not a benchmark)\n", e-s }'
