#!/usr/bin/env bash
#
# scripts/pilot.sh - the week 4 OPEN-LOOP pilot (Phase B step 6).
#
#   scripts/pilot.sh <config> [run-id]
#
#   <config>  benchmarks/configs/pilot-gpu.sh | pilot-kind.sh (test)
#
# NOT a published result. It informs the closed-loop ladder (step 7) and
# answers one week 5 question: is vllm:num_requests_waiting usable as a
# scaling signal? Reasoning: NOTES.md, "open-loop pilot".
#
# Runs against an ISVC that is ALREADY Ready; creates and deletes nothing.
# Per rate: Poisson arrivals at that rate -> gauges every GAUGE_INTERVAL_S ->
# drain to empty -> one summary line. Stops after STOP_AFTER_SATURATED
# saturated rates in a row.
#
# The client runs as ONE GuideLLM worker process: 0.7.4 seeds every worker's
# Poisson generator with the same seed, so with >1 worker the arrival gaps
# repeat in blocks (pilot-kind-1). One worker keeps up to 32 req/s on the
# laptop (scripts/client-capacity.sh); every rate is still checked for send
# lag (client_limited) and against the server's own arrival count.
#
# Exit: 0 ran to the end or stopped early as designed | 1 a rate failed or the
# queue did not drain | 2 usage or config error.

# Config variables (TOKENIZER_REPO, ...) come from the sourced config, which
# the linter cannot see; the loop after sourcing checks every one exists.
# shellcheck disable=SC2153

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/scripts/lib-pods.sh"
cd "$REPO_ROOT" || exit 2
SIDECAR="$REPO_ROOT/scripts/sidecar.sh"
LOG=/dev/null

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$LOG" >&2; }
die() { local code=$1; shift; log "FATAL: $*"; exit "$code"; }

CONFIG=${1:-}
RUN_ID=${2:-}
[ -f "$CONFIG" ] || { sed -n '3,7p' "$0"; exit 2; }

if command -v nvidia-smi >/dev/null 2>&1; then
  PLATFORM=gpu
  export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
else
  PLATFORM=kind
fi

# shellcheck source=/dev/null
. "$CONFIG"
for v in EXPECT_PLATFORM NAMESPACE ISVC TOKENIZER_REPO TOKENIZER_REV TOKENIZER_OFFLINE \
         PROMPT OUTPUT SEED_BASE RATES RATE_S EDGE_START_S GAUGE_INTERVAL_S \
         DRAIN_TIMEOUT_S SAT_ACHIEVED_FRAC STOP_AFTER_SATURATED \
         LAG_P95_LIMIT_MS ARRIVALS_TOLERANCE; do
  declare -p "$v" >/dev/null 2>&1 || die 2 "$CONFIG does not set $v"
done
[ "$EXPECT_PLATFORM" = "$PLATFORM" ] || die 2 "$CONFIG is for $EXPECT_PLATFORM; this is $PLATFORM"
[ "$PLATFORM" = gpu ] && [ -z "$TOKENIZER_REV" ] && die 2 "GPU needs a pinned TOKENIZER_REV"

RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%MZ)-pilot-$PLATFORM}
RESULTS="$REPO_ROOT/benchmarks/results/$RUN_ID"
mkdir -p "$RESULTS"
LOG="$RESULTS/pilot.log"
exec 9>"$RESULTS/.lock"
flock -n 9 || die 2 "another pilot.sh holds $RESULTS"
cp "$CONFIG" "$RESULTS/config.sh"
trap 'kill $(jobs -p) 2>/dev/null' EXIT

# ---- helpers: copied from benchmark.sh (pod_of now delegates to lib-pods.sh) -
pod_of() {   # exactly one live pod, else "" + diagnostics on stderr (lib-pods.sh)
  one_live_pod "$NAMESPACE" "serving.kserve.io/inferenceservice=$1"
}
# Week 5 A6: REPLICAS > 1 measures several replicas behind one Service. Gauges
# are then SUMMED across pods (running, waiting) - the totals KEDA's query sees;
# kv is the highest pod's. REPLICAS=1 (default) keeps the strict check above.
pods_of() {   # pods_of <isvc>: exactly REPLICAS live pods, one per line, else nothing
  if [ "$REPLICAS" = 1 ]; then pod_of "$1"; return; fi
  local sel="serving.kserve.io/inferenceservice=$1" list n
  list=$(live_pods "$NAMESPACE" "$sel")
  n=$(grep -c . <<<"$list")
  if [ "$n" != "$REPLICAS" ]; then
    echo "want $REPLICAS live pods, found $n:" >&2; pod_report "$NAMESPACE" "$sel" >&2; return 1
  fi
  echo "$list"
}
metrics_dump() { kubectl get --raw "/api/v1/namespaces/$NAMESPACE/pods/$1:8080/proxy/metrics"; }
target_url() {
  if [ "$PLATFORM" = kind ]; then echo "http://localhost:8080"; return; fi
  local hp
  hp=$(kubectl get svc -n "$NAMESPACE" "$1-predictor" \
       -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}' 2>/dev/null) || return 1
  [ -n "$hp" ] && echo "http://$hp"
}
gauge() { grep -E "^$2[{ ]" <<<"$1" | head -1 | awk '{print $NF}'; }
gauge_sampler() {   # gauge_sampler <csv> <pod>...: until killed; sums across pods
  local csv=$1; shift
  echo "epoch_s,num_requests_running,num_requests_waiting,kv_cache_usage_perc" > "$csv"
  local m p r w k t row
  while :; do
    t=$(date +%s.%3N); row=""
    for p in "$@"; do
      m=$(metrics_dump "$p" 2>/dev/null)
      r=$(gauge "$m" vllm:num_requests_running); w=$(gauge "$m" vllm:num_requests_waiting)
      k=$(gauge "$m" vllm:kv_cache_usage_perc)
      row+="$r $w $k"$'\n'
    done
    # A pod that did not answer leaves an empty field, never a silent 0.
    awk -v t="$t" -v n=$# 'NF == 3 { r += $1; w += $2; if ($3 > k) k = $3; c++ }
      END { if (c == n) printf "%s,%s,%s,%s\n", t, r, w, k; else printf "%s,,,\n", t }' \
      <<<"$row" >> "$csv"
    sleep "$GAUGE_INTERVAL_S"
  done
}

# ---- pilot-only -------------------------------------------------------------
# Wait until the engine is empty, so the next rate does not start behind.
# (vLLM aborts a request when its client disconnects, queued ones included,
# so this is fast; measured on kind.) Prints seconds taken; 1 on timeout.
drain() {   # drain <pod>...: every pod empty
  local t0=$SECONDS m r w p busy
  while [ $((SECONDS - t0)) -lt "$DRAIN_TIMEOUT_S" ]; do
    busy=0
    for p in "$@"; do
      m=$(metrics_dump "$p" 2>/dev/null)
      r=$(gauge "$m" vllm:num_requests_running); w=$(gauge "$m" vllm:num_requests_waiting)
      { [ "${r%.*}" = 0 ] && [ "${w%.*}" = 0 ]; } || busy=1
    done
    [ "$busy" = 0 ] && { echo $((SECONDS - t0)); return 0; }
    sleep 2
  done
  echo "$DRAIN_TIMEOUT_S"; return 1
}

# Gauge stats over the MEASURED window only (after the excluded start edge).
# The slopes are least-squares fits of the gauge against time (requests per
# second): positive = a backlog is BUILDING. On kind the backlog built up in
# `running` while `waiting` stayed 0 (pilot-kind-2), so both are reported.
# period = the real spacing of samples (each kubectl scrape adds ~0.4 s).
# Prints: n waiting_mean waiting_max waiting_pct running_mean running_max
#         running_slope waiting_slope period_s
window_stats() {   # window_stats <gauges.csv> <start_epoch> <end_epoch>
  awk -F, -v s="$2" -v e="$3" 'NR > 1 && $1 >= s && $1 <= e && $3 != "" {
      n++; t = $1 - s; w += $3; r += $2
      if ($3 > wmx) wmx = $3; if ($2 > rmx) rmx = $2; if ($3 > 0) pos++
      st += t; stt += t * t; sr += t * $2; sw += t * $3
      if (n == 1) t1 = t; tn = t }
    END { if (n < 2) { print "0 0 0 0 0 0 0 0 0"; exit }
          d = n * stt - st * st
          rs = (d > 0) ? (n * sr - st * r) / d : 0
          ws = (d > 0) ? (n * sw - st * w) / d : 0
          printf "%d %.2f %d %.1f %.2f %d %.3f %.3f %.2f\n",
                 n, w/n, wmx, 100*pos/n, r/n, rmx, rs, ws, (tn - t1) / (n - 1) }' "$1"
}

# Client-side facts from GuideLLM's per-request records, all computed over
# the MEASURED window [start_time, end_time]:
#   sent      requests SCHEDULED in the window (finished or not)
#   lag_*     actual send - scheduled send, ms: is the client on time?
#   done      requests that COMPLETED in the window
#   total     every request the run sent, warmup included (for layer 3)
# Prints: sent window_s lag_p50 lag_p95 lag_max done total ttft_p50 ttft_p95
client_stats() {   # client_stats <guidellm.json>
  jq -r '.benchmarks[0] as $b
    | ($b.requests | (.successful + .incomplete + .errored)) as $all
    | [$all[].info.timings | select(.targeted_start >= $b.start_time and .targeted_start <= $b.end_time)
       | (.request_start - .targeted_start) * 1000] | sort as $lag
    | ($lag | length) as $n
    | [$b.requests.successful[].info.timings.request_end
       | select(. >= $b.start_time and . <= $b.end_time)] as $done
    | [$n, ($b.end_time - $b.start_time),
       (if $n > 0 then $lag[($n * 0.5 | floor)] else 0 end),
       (if $n > 0 then $lag[($n * 0.95 | floor)] else 0 end),
       (if $n > 0 then $lag[-1] else 0 end),
       ($done | length), ($all | length),
       ($b.metrics.time_to_first_token_ms.successful as $t
        | if ($t.count // 0) == 0 then "NA", "NA"
          else ($t.percentiles.p50 | round), ($t.percentiles.p95 | round) end)]
    | @tsv' "$1"
}

# Layer 3: the SERVER's own count of arrivals. vLLM 0.29 has no "requests
# received" metric, and aborted requests are counted nowhere in /metrics, so
# count the access-log lines instead. Use the pod NAME: `kubectl logs -l`
# silently returns only 10 lines per pod.
server_arrivals() {   # server_arrivals <since RFC3339> <pod>...: summed over pods
  local since=$1 p n=0; shift
  for p in "$@"; do
    n=$(( n + $(kubectl logs -n "$NAMESPACE" "$p" -c kserve-container --since-time="$since" 2>/dev/null \
                | grep -c 'POST /v1/chat/completions') ))
  done
  echo "$n"
}

# ---- run --------------------------------------------------------------------
REPLICAS=${REPLICAS:-1}   # older configs do not set it
mapfile -t PODS < <(pods_of "$ISVC")
if [ "${#PODS[@]}" -lt 1 ] || [ -z "${PODS[0]}" ]; then
  die 2 "no (or not $REPLICAS) live pod(s) for ISVC $ISVC"
fi
TARGET=$(target_url "$ISVC") || die 2 "no target for $ISVC"
log "pilot $RUN_ID: $ISVC pods=${PODS[*]} target=$TARGET rates=(${RATES[*]}) ${RATE_S}s each, 1 client worker"

# One worker process: the only way to get true Poisson arrivals from 0.7.4.
envp=(env GUIDELLM__MAX_WORKER_PROCESSES=1)
[ "$TOKENIZER_OFFLINE" = 1 ] && envp+=(HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1)
backend=$(jq -nc --arg t "$TARGET" --arg m "$ISVC" '{kind:"openai_http", target:$t, model:$m}')
tok=$(jq -nc --arg m "$TOKENIZER_REPO" --arg r "$TOKENIZER_REV" \
      '{kind:"hf_auto", model:$m} + (if $r == "" then {} else {load_kwargs:{revision:$r}} end)')
data=$(jq -nc --argjson p "$PROMPT" --argjson o "$OUTPUT" \
      '{kind:"synthetic_text", prompt_tokens:$p, output_tokens:$o}')
cons=$(jq -nc --argjson s $((EDGE_START_S + RATE_S)) '{kind:"max_duration", seconds:$s}')

SUMMARY="$RESULTS/summary.csv"
echo "rate_offered,seed,sent_in_window,delivered_rps,completed_rps,lag_p50_ms,lag_p95_ms,lag_max_ms,client_limited,client_sent_total,server_arrivals,arrivals_match,ttft_p50_ms,ttft_p95_ms,gauge_samples,gauge_period_s,waiting_mean,waiting_max,waiting_pct_gt0,waiting_slope_per_s,running_mean,running_max,running_slope_per_s,drain_s,saturated" > "$SUMMARY"

i=0; sat_run=0; rc_all=0
for rate in "${RATES[@]}"; do
  seed=$((SEED_BASE + i))
  dir="$RESULTS/$(printf 'rate-%02d' "$i")"; mkdir -p "$dir"
  i=$((i + 1))
  log "rate $rate req/s (seed $seed)"

  # Poisson: random gaps that AVERAGE 1/rate. The seed fixes both the prompt
  # text and the arrival times, so the run is repeatable.
  prof=$(jq -nc --argjson r "$rate" --argjson w "$EDGE_START_S" \
         '{kind:"poisson", rate:[$r], warmup:{value:$w, mode:"duration"}}')
  seedj=$(jq -nc --argjson s "$seed" '{kind:"static", value:$s}')
  outj=$(jq -nc --arg p "$dir/guidellm.json" '{kind:"json", path:$p}')

  since=$(date -u +%Y-%m-%dT%H:%M:%SZ)   # whole seconds: drained before this
  gauge_sampler "$dir/gauges.csv" "${PODS[@]}" & gpid=$!
  "$SIDECAR" gpu-sample "$dir/gpu.csv" & npid=$!
  "${envp[@]}" uv run --locked guidellm run \
    --backend "$backend" --tokenizer "$tok" --data "$data" --seed "$seedj" \
    --profile "$prof" --constraint "$cons" --output "$outj" \
    --disable-console-interactive > "$dir/guidellm.log" 2>&1
  grc=$?

  # Keep sampling through the drain: how fast the queue empties is evidence too.
  dsec=$(drain "${PODS[@]}"); drc=$?
  kill "$gpid" "$npid" 2>/dev/null; wait "$gpid" "$npid" 2>/dev/null
  arrivals=$(server_arrivals "$since" "${PODS[@]}")

  J="$dir/guidellm.json"
  succ=$(jq -r '.benchmarks[0].metrics.request_totals.successful // 0' "$J" 2>/dev/null || echo 0)
  if [ "$grc" -ne 0 ] || [ "${succ:-0}" -eq 0 ]; then
    log "  rate FAILED (exit $grc, successful $succ) - see $dir/guidellm.log"; rc_all=1; break
  fi
  read -r ws we < <(jq -r '.benchmarks[0] | "\(.start_time) \(.end_time)"' "$J")
  read -r sent wsec l50 l95 lmax ndone total t50 t95 < <(client_stats "$J")
  read -r n wmean wmax wpct rmean rmax rslope wslope gper < <(window_stats "$dir/gauges.csv" "$ws" "$we")

  # The three verdicts. All thresholds live in the config.
  read -r deliv compl climit amatch sat < <(awk \
    -v s="$sent" -v d="$ndone" -v w="$wsec" -v l95="$l95" -v L="$LAG_P95_LIMIT_MS" \
    -v tot="$total" -v arr="$arrivals" -v tol="$ARRIVALS_TOLERANCE" \
    -v F="$SAT_ACHIEVED_FRAC" 'BEGIN {
      deliv = s / w; cr = d / w
      climit = (l95 > L) ? 1 : 0                                  # layer 2
      diff = tot - arr; if (diff < 0) diff = -diff
      amatch = (diff <= tol) ? 1 : 0                              # layer 3
      # Saturated: completions fall clearly short of what was DELIVERED.
      # Throughput only - the gauges are what the pilot is TESTING, so they
      # cannot be part of the definition (agreed after pilot-kind-2).
      # Delivered, not nominal: Poisson noise moves it ~10% at low rates.
      sat = (cr < F * deliv) ? 1 : 0
      printf "%.3f %.3f %d %d %d\n", deliv, cr, climit, amatch, sat }')

  printf '%s,%s,%s,%s,%s,%.1f,%.1f,%.1f,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$rate" "$seed" "$sent" "$deliv" "$compl" "$l50" "$l95" "$lmax" "$climit" \
    "$total" "$arrivals" "$amatch" "$t50" "$t95" "$n" "$gper" "$wmean" "$wmax" "$wpct" "$wslope" \
    "$rmean" "$rmax" "$rslope" "$dsec" "$sat" >> "$SUMMARY"
  log "  delivered $deliv req/s, completed $compl | lag p95 $(printf %.1f "$l95") ms | sent $total / server saw $arrivals | running max $rmax slope $rslope/s | waiting max $wmax slope $wslope/s | drain ${dsec}s | saturated=$sat"
  [ "$climit" = 1 ] && log "  WARN: CLIENT-LIMITED (send lag p95 > ${LAG_P95_LIMIT_MS} ms) - do not use this rate for the knee"
  [ "$amatch" = 1 ] || log "  WARN: client sent $total but server logged $arrivals"

  if [ "$drc" -ne 0 ]; then log "  queue did not drain in ${DRAIN_TIMEOUT_S}s - stopping"; rc_all=1; break; fi
  if [ "$sat" = 1 ]; then sat_run=$((sat_run + 1)); else sat_run=0; fi
  if [ "$sat_run" -ge "$STOP_AFTER_SATURATED" ]; then
    log "  $sat_run saturated rates in a row - stopping early (by design)"; break
  fi
done

log "pilot done (exit $rc_all). Summary: $SUMMARY"
exit "$rc_all"
