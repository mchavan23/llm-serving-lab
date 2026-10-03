#!/usr/bin/env bash
#
# scripts/client-capacity.sh - can ONE GuideLLM worker process drive open-loop
# Poisson load on time? Week 4, before the pilot (NOTES, "open-loop pilot").
#
#   scripts/client-capacity.sh [run-id]
#
# Why: GuideLLM 0.7.4's Poisson strategy seeds every worker process with the
# same seed, so with >1 worker the arrival gaps repeat in blocks (found in
# pilot-kind-1). The pilot therefore runs with ONE worker. This proves that
# one worker is not itself the bottleneck: it drives a mock server whose
# timing is KNOWN (TTFT, ITL fixed), so any send lag or latency excess is
# the client's own error, never the server's.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

RUN_ID=${1:-$(date -u +%Y%m%dT%H%MZ)-client-capacity}
OUT="$REPO_ROOT/benchmarks/results/$RUN_ID"; mkdir -p "$OUT"
LOG="$OUT/capacity.log"
log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$LOG" >&2; }

PORT=8199
MOCK_TTFT_MS=50; MOCK_ITL_MS=15; TOKENS=256; PROMPT=1024
PROCESSOR=Qwen/Qwen2.5-0.5B-Instruct   # tokenizer choice barely affects client cost
RATES=(8 16 24 32)
MEASURED_S=60; WARMUP_S=10
SEED_BASE=842                          # outside every sweep / pilot range

trap 'kill $(jobs -p) 2>/dev/null' EXIT

# The mock gets 4 processes of its own so IT is never the slow side.
# No --processor: 0.7.4's mock loads it via the abstract PreTrainedTokenizer
# and crashes; its built-in MockTokenizer is fine (server-side text only).
uv run --locked guidellm mock-server --host 127.0.0.1 --port "$PORT" --workers 4 \
  --model mock --ttft-ms "$MOCK_TTFT_MS" --itl-ms "$MOCK_ITL_MS" \
  --output-tokens "$TOKENS" > "$OUT/mock-server.log" 2>&1 &
for _ in $(seq 60); do curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null && break; sleep 1; done
curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null || { log "mock server did not start"; exit 1; }
log "mock up: TTFT ${MOCK_TTFT_MS} ms, ITL ${MOCK_ITL_MS} ms, ${TOKENS} tokens"

backend=$(jq -nc --arg t "http://127.0.0.1:$PORT" '{kind:"openai_http", target:$t, model:"mock"}')
tok=$(jq -nc --arg m "$PROCESSOR" '{kind:"hf_auto", model:$m}')
data=$(jq -nc --argjson p "$PROMPT" --argjson o "$TOKENS" '{kind:"synthetic_text", prompt_tokens:$p, output_tokens:$o}')
cons=$(jq -nc --argjson s $((WARMUP_S + MEASURED_S)) '{kind:"max_duration", seconds:$s}')

echo "rate,sent_in_window,delivered_rps,lag_p50_ms,lag_p95_ms,lag_max_ms,ttft_p50_ms,ttft_p95_ms,itl_p50_ms,itl_p95_ms,worker_cpu_pct" > "$OUT/summary.csv"

i=0
for rate in "${RATES[@]}"; do
  d="$OUT/rate-$rate"; mkdir -p "$d"
  prof=$(jq -nc --argjson r "$rate" --argjson w "$WARMUP_S" '{kind:"poisson", rate:[$r], warmup:{value:$w, mode:"duration"}}')
  seedj=$(jq -nc --argjson s $((SEED_BASE + i)) '{kind:"static", value:$s}'); i=$((i + 1))
  outj=$(jq -nc --arg p "$d/guidellm.json" '{kind:"json", path:$p}')
  log "rate $rate req/s"

  # ONE worker process: the setting the pilot will use.
  GUIDELLM__MAX_WORKER_PROCESSES=1 uv run --locked guidellm run \
    --backend "$backend" --tokenizer "$tok" --data "$data" --seed "$seedj" \
    --profile "$prof" --constraint "$cons" --output "$outj" \
    --disable-console-interactive > "$d/guidellm.log" 2>&1 &
  cpid=$!
  # Mid-run CPU snapshot of every guidellm python process (%cpu = average since
  # that process started, which here is ~the run itself).
  sleep $((WARMUP_S + MEASURED_S / 2))
  ps -eo pid,ppid,pcpu,etimes,args | awk '/guidellm run/ && !/awk/ && !/uv run/' > "$d/cpu.txt"
  wait "$cpid"

  J="$d/guidellm.json"
  # Send lag over EVERY request scheduled in the measured window, finished or not.
  lag=$(jq -r '.benchmarks[0] as $b
    | [$b.requests | (.successful + .incomplete + .errored)[] | .info.timings
       | select(.targeted_start >= $b.start_time and .targeted_start <= $b.end_time)
       | (.request_start - .targeted_start) * 1000] | sort
    | if length == 0 then "0 0 0 0"
      else "\(length) \(.[(length*0.5|floor)]) \(.[(length*0.95|floor)]) \(.[-1])" end' "$J")
  read -r nsent l50 l95 lmax <<<"$lag"
  read -r t50 t95 i50 i95 < <(jq -r '.benchmarks[0].metrics as $m |
    "\($m.time_to_first_token_ms.successful.percentiles.p50) \($m.time_to_first_token_ms.successful.percentiles.p95) \($m.inter_token_latency_ms.successful.percentiles.p50) \($m.inter_token_latency_ms.successful.percentiles.p95)"' "$J")
  cpu=$(awk 'NR == 1 || $3 > m { m = $3 } END { print m + 0 }' "$d/cpu.txt")
  printf '%s,%s,%.2f,%.1f,%.1f,%.1f,%.1f,%.1f,%.2f,%.2f,%s\n' "$rate" "$nsent" \
    "$(awk -v n="$nsent" -v s="$MEASURED_S" 'BEGIN{print n/s}')" \
    "$l50" "$l95" "$lmax" "$t50" "$t95" "$i50" "$i95" "$cpu" >> "$OUT/summary.csv"
  log "  $(tail -1 "$OUT/summary.csv")"
done
log "done. $OUT/summary.csv"
