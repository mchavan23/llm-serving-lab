#!/usr/bin/env bash
#
# scripts/step-load.sh - the KEDA step-load test (scale-out under a load step).
# Week 5 A4. Design and reasons: NOTES.md "Week 5 A4 decision" and "Week 5 A4".
#
#   scripts/step-load.sh <config> [run-id]
#
#   <config>  benchmarks/configs/step-gpu.sh (main) | step-gpu-collapse.sh (optional 3->8)
#             | step-kind.sh (A6/A7 dry run)
#   [run-id]  resume that run: cycles with a DONE marker are skipped, a partial
#             cycle is moved aside and redone. Omitted = new run.
#
# Per cycle: wait for exactly one replica -> leg sidecar -> trace (make_trace.py)
# -> recorders on (1 s cluster timeline, per-GPU sampler) -> GuideLLM `replay`,
# open loop, Connection: close -> pod snapshot just after the step-down (replica 2
# is deleted ~6 min later and would take its startup record with it) -> recorders
# off -> Prometheus range export + namespace Events -> DONE.
#
# The harness holds <results-dir>/.lock for its whole life (teardown watcher
# contract, A0) and ends its log with COMPLETE or INCOMPLETE.
# Exit: 0 every cycle DONE | 1 a cycle failed (re-run with the run-id) | 2 usage/config.
#
# Config variables are set by the sourced config, which the linter cannot see;
# the loop after sourcing checks every one exists.
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
[ -f "$CONFIG" ] || { sed -n '5,11p' "$0"; exit 2; }
if command -v nvidia-smi >/dev/null 2>&1; then
  PLATFORM=gpu
  export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
else
  PLATFORM=kind
fi
# shellcheck source=/dev/null
. "$CONFIG"
for v in EXPECT_PLATFORM NAMESPACE ISVC MODEL CYCLES STEP_STAGE SEED_BASE PROMPT OUTPUT \
         TOKENIZER_REPO TOKENIZER_REV TOKENIZER_OFFLINE REQUIRE_KEDA KEDA_QUERY \
         PRECONDITION_TIMEOUT_S POLL_INTERVAL_S GPU_SAMPLE_MS PROM_STEP_S DRAIN_MAX_S \
         SNAPSHOT_DELAY_S; do
  declare -p "$v" >/dev/null 2>&1 || die 2 "$CONFIG does not set $v"
done
[ "$EXPECT_PLATFORM" = "$PLATFORM" ] || die 2 "$CONFIG is for $EXPECT_PLATFORM; this is $PLATFORM"
[ "$PLATFORM" = gpu ] && [ -z "$TOKENIZER_REV" ] && die 2 "a GPU run needs a pinned TOKENIZER_REV"
[ "${#CYCLES[@]}" -ge 1 ] || die 2 "CYCLES is empty"

RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%MZ)-step-$PLATFORM}
RESULTS="$REPO_ROOT/benchmarks/results/$RUN_ID"
mkdir -p "$RESULTS"
LOG="$RESULTS/step-load.log"
# One harness per run directory, and the lock is the teardown watcher's signal
# that the run is alive (A0): taken before anything else, held until exit.
exec 9>"$RESULTS/.lock"
flock -n 9 || die 2 "another harness holds $RESULTS"
if [ -f "$RESULTS/config.sh" ]; then
  cmp -s "$CONFIG" "$RESULTS/config.sh" || die 2 "config differs from the one this run started with"
else
  cp "$CONFIG" "$RESULTS/config.sh"
fi
# Background recorders and the port-forward must not outlive the harness.
trap 'kill $(jobs -p) 2>/dev/null' EXIT

DEPLOY="$ISVC-predictor"            # KServe Standard: Deployment and Service names
SVC="$ISVC-predictor"
SEL="serving.kserve.io/inferenceservice=$ISVC"

# --------------------------------------------------------------- helpers ---
target_url() {
  # As benchmark.sh: GPU reaches the predictor ClusterIP from the VM; kind uses
  # the NodePort on localhost:8080. Both go through kube-proxy, which picks a
  # replica per CONNECTION - hence Connection: close on every request.
  if [ "$PLATFORM" = kind ]; then echo "http://localhost:8080"; return; fi
  local hp
  hp=$(kubectl get svc -n "$NAMESPACE" "$SVC" \
       -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}' 2>/dev/null) || return 1
  [ -n "$hp" ] && echo "http://$hp"
}

autoscaler_names() {
  # The ScaledObject and the HPA KEDA made for it, found by what they scale -
  # not by guessing names KServe or KEDA generate.
  SO=""; HPA=""
  [ "$REQUIRE_KEDA" = 1 ] || return 0
  SO=$(kubectl get scaledobject -n "$NAMESPACE" -o json 2>/dev/null | jq -r --arg d "$DEPLOY" \
       '[.items[] | select(.spec.scaleTargetRef.name == $d)] | if length == 1 then .[0].metadata.name else empty end')
  HPA=$(kubectl get hpa -n "$NAMESPACE" -o json 2>/dev/null | jq -r --arg d "$DEPLOY" \
       '[.items[] | select(.spec.scaleTargetRef.name == $d)] | if length == 1 then .[0].metadata.name else empty end')
  [ -n "$SO" ] && [ -n "$HPA" ]
}

PROM_URL=""
prom_connect() {
  # GPU: Prometheus ClusterIP, reachable from the VM. kind: a port-forward on a
  # port kubectl picks - never the API-server proxy, which stalls under load
  # (A3). Called again before each export in case the forward died.
  if [ "$PLATFORM" = gpu ]; then
    PROM_URL="http://$(kubectl get svc -n monitoring prometheus -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}')"
  else
    if [ -z "${PROM_PF_PID:-}" ] || ! kill -0 "$PROM_PF_PID" 2>/dev/null; then
      kubectl -n monitoring port-forward svc/prometheus :9090 > "$RESULTS/prom-pf.log" 2>&1 &
      PROM_PF_PID=$!
      local i port=""
      for i in $(seq 1 20); do
        port=$(grep -oE '127\.0\.0\.1:[0-9]+' "$RESULTS/prom-pf.log" | head -1 | cut -d: -f2)
        [ -n "$port" ] && break
        sleep 0.5
      done
      PROM_URL="http://127.0.0.1:$port"
    fi
  fi
  curl -sf --max-time 5 "$PROM_URL/-/ready" >/dev/null
}

prom_range() {   # prom_range <query> <start epoch> <end epoch> <out.json>
  curl -sf --max-time 60 -G "$PROM_URL/api/v1/query_range" \
    --data-urlencode "query=$1" --data-urlencode "start=$2" --data-urlencode "end=$3" \
    --data-urlencode "step=$PROM_STEP_S" > "$4" && [ "$(jq -r .status "$4")" = success ]
}

wait_one_replica() {
  # A cycle starts from exactly one replica: one pod in total (none Pending or
  # Terminating), it is live, the Deployment asks for 1 and KEDA's HPA wants 1.
  # Between cycles this waits out the previous scale-down (~6 min).
  local t=0 pods live spec desired
  while :; do
    pods=$(kubectl get pods -n "$NAMESPACE" -l "$SEL" -o name 2>/dev/null | grep -c .)
    live=$(live_pods "$NAMESPACE" "$SEL" | grep -c .)
    spec=$(kubectl get deploy -n "$NAMESPACE" "$DEPLOY" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    desired=1
    [ -n "$HPA" ] && desired=$(kubectl get hpa -n "$NAMESPACE" "$HPA" -o jsonpath='{.status.desiredReplicas}' 2>/dev/null)
    [ "$pods" = 1 ] && [ "$live" = 1 ] && [ "$spec" = 1 ] && [ "$desired" = 1 ] && return 0
    if [ "$t" -ge "$PRECONDITION_TIMEOUT_S" ]; then
      log "  not one replica after ${t}s: pods=$pods live=$live deploy=$spec hpa-desired=$desired"
      pod_report "$NAMESPACE" "$SEL" | tee -a "$LOG" >&2
      return 1
    fi
    [ $((t % 60)) -eq 0 ] && log "  waiting for one replica: pods=$pods live=$live deploy=$spec hpa-desired=$desired"
    sleep 5; t=$((t + 5))
  done
}

poller() {   # poller <timeline.jsonl>: one JSON line per tick, until killed
  # Three reads in parallel so a tick costs one round trip. "t" is when the
  # tick started (epoch s). The sleep is what is LEFT of the interval after the
  # reads, so ticks stay ~POLL_INTERVAL_S apart (smoke test without it: 1.35 s).
  local tmp t rest
  tmp=$(mktemp -d)
  while :; do
    t=$(date +%s.%N)
    kubectl get pods -n "$NAMESPACE" -l "$SEL" -o json > "$tmp/p" 2>/dev/null &
    kubectl get "deploy/$DEPLOY" ${HPA:+"hpa/$HPA"} -n "$NAMESPACE" -o json > "$tmp/d" 2>/dev/null &
    kubectl get endpointslices -n "$NAMESPACE" -l "kubernetes.io/service-name=$SVC" -o json > "$tmp/e" 2>/dev/null &
    wait
    jq -nc --argjson t "$t" --slurpfile p "$tmp/p" --slurpfile d "$tmp/d" --slurpfile e "$tmp/e" '
      def objs($x): if ($x | length) == 0 or $x[0] == null then []
                    elif $x[0].kind == "List" or ($x[0] | has("items")) then $x[0].items
                    else [$x[0]] end;
      (objs($d) | map(select(.kind == "Deployment")) | .[0]) as $dep
      | (objs($d) | map(select(.kind == "HorizontalPodAutoscaler")) | .[0]) as $hpa
      | {t: $t,
         deploy: (if $dep then {spec: $dep.spec.replicas, ready: ($dep.status.readyReplicas // 0)} else null end),
         hpa: (if $hpa then {desired: $hpa.status.desiredReplicas, current: $hpa.status.currentReplicas,
                             metric: ($hpa.status.currentMetrics[0].external.current // null)} else null end),
         pods: [objs($p)[] | {name: .metadata.name, phase: .status.phase,
                              deleting: (.metadata.deletionTimestamp != null),
                              ready: ((.status.conditions // []) | map(select(.type == "Ready")) | .[0].status // "-")}],
         endpoints_ready: ([objs($e)[] | .endpoints[]? | select(.conditions.ready == true)] | length)}' \
      >> "$1" 2>/dev/null || printf '{"t":%s,"error":"poll"}\n' "$t" >> "$1"
    rest=$(awk -v t="$t" -v now="$(date +%s.%N)" -v i="$POLL_INTERVAL_S" \
           'BEGIN {r = i - (now - t); printf "%.3f", (r > 0 ? r : 0)}')
    sleep "$rest"
  done
}

snapshot() {   # snapshot <dir>: every predictor pod's JSON and logs, as they are now
  # Pod conditions carry the authoritative stage times (scheduled, initialized,
  # ready); the logs carry the startup record sidecar.sh reads (copy, engine init).
  mkdir -p "$1/logs"
  kubectl get pods -n "$NAMESPACE" -l "$SEL" -o json > "$1/pods.json" 2> "$1/errors.txt"
  local p
  for p in $(jq -r '.items[].metadata.name' "$1/pods.json" 2>/dev/null); do
    kubectl logs -n "$NAMESPACE" "$p" -c kserve-container --timestamps > "$1/logs/$p.log" 2>> "$1/errors.txt"
    kubectl logs -n "$NAMESPACE" "$p" -c storage-initializer --timestamps \
      > "$1/logs/$p.storage-initializer.log" 2>> "$1/errors.txt"
  done
}

# ------------------------------------------------------------- one cycle ---
run_cycle() {   # run_cycle <n> <stages>
  local n=$1 stages=$2 dir seed
  dir=$(printf '%s/cycle-%02d' "$RESULTS" "$n")
  seed=$((SEED_BASE + n - 1))
  if [ -f "$dir/DONE" ]; then log "cycle $n: DONE already - skipped"; return 0; fi
  if [ -d "$dir" ]; then
    mv "$dir" "$dir.partial-$(date -u +%H%M%S)"; log "cycle $n: partial result moved aside"
  fi
  mkdir -p "$dir"
  log "cycle $n: stages $stages, seed $seed"

  autoscaler_names || { log "cycle $n: FAILED - no unique ScaledObject + HPA for $DEPLOY"; return 1; }
  wait_one_replica || { log "cycle $n: FAILED - precondition (one replica) not met"; return 1; }
  "$SIDECAR" leg "$dir/env-leg.json" "$ISVC" "$NAMESPACE"

  uv run --locked python scripts/make_trace.py --stages "$stages" --seed "$seed" \
    --prompt "$PROMPT" --output "$OUTPUT" --out "$dir" >> "$LOG" 2>&1 \
    || { log "cycle $n: FAILED - make_trace.py"; return 1; }
  local stepdown last
  stepdown=$(jq -r --argjson i "$STEP_STAGE" '.stages[$i].end_s' "$dir/stages.json")
  last=$(jq -r .last_arrival_s "$dir/stages.json")

  local target query threshold=""
  target=$(target_url) || { log "cycle $n: FAILED - no target for $SVC"; return 1; }
  query=$KEDA_QUERY
  if [ -n "$SO" ]; then   # record what KEDA actually evaluates, not what we meant it to
    query=$(kubectl get scaledobject -n "$NAMESPACE" "$SO" -o jsonpath='{.spec.triggers[0].metadata.query}')
    threshold=$(kubectl get scaledobject -n "$NAMESPACE" "$SO" -o jsonpath='{.spec.triggers[0].metadata.threshold}')
  fi

  local backend tok data seedj prof outj
  backend=$(jq -nc --arg t "$target" --arg m "$MODEL" \
            '{kind:"openai_http", target:$t, model:$m, extras:{headers:{Connection:"close"}}}')
  tok=$(jq -nc --arg m "$TOKENIZER_REPO" --arg r "$TOKENIZER_REV" \
        '{kind:"hf_auto", model:$m} + (if $r == "" then {} else {load_kwargs:{revision:$r}} end)')
  data=$(jq -nc --arg p "$dir/trace.csv" '{kind:"trace_synthetic", path:$p}')
  seedj=$(jq -nc --argjson s "$seed" '{kind:"static", value:$s}')
  prof='{"kind":"replay"}'
  outj=$(jq -nc --arg p "$dir/guidellm.json" '{kind:"json", path:$p}')
  local envp=(env GUIDELLM__MAX_WORKER_PROCESSES=1)
  [ "$TOKENIZER_OFFLINE" = 1 ] && envp+=(HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1)
  # Hard stop: schedule + drain allowance + startup. Open loop never stops by itself
  # if the server stops answering.
  local tmo
  tmo=$(awk -v l="$last" -v d="$DRAIN_MAX_S" 'BEGIN {printf "%d", l + d + 120}')

  poller "$dir/timeline.jsonl" &
  local ppid=$!
  "$SIDECAR" gpu-sample "$dir/gpu.csv" "$GPU_SAMPLE_MS" &
  local gpid=$!
  local t0 t1 rc
  t0=$(date +%s.%N)
  ( sleep "$(awk -v s="$stepdown" -v d="$SNAPSHOT_DELAY_S" 'BEGIN {printf "%d", s + d}')"
    snapshot "$dir/at-stepdown" ) &
  local spid=$!
  log "  load: replay to $target, $(jq -r .total_requests "$dir/stages.json") requests, step-down at ${stepdown}s, hard stop ${tmo}s"
  timeout "$tmo" "${envp[@]}" uv run --locked guidellm run \
    --backend "$backend" --tokenizer "$tok" --data "$data" --seed "$seedj" \
    --profile "$prof" --output "$outj" --disable-console-interactive > "$dir/guidellm.log" 2>&1
  rc=$?
  t1=$(date +%s.%N)

  kill "$ppid" "$gpid" 2>/dev/null; wait "$ppid" "$gpid" 2>/dev/null
  if kill -0 "$spid" 2>/dev/null; then   # load ended before the step-down snapshot
    kill "$spid" 2>/dev/null; log "  WARN: load ended before the step-down snapshot"
  fi
  wait "$spid" 2>/dev/null
  snapshot "$dir/at-end"
  "$SIDECAR" gpu-summary "$dir/gpu.csv" "$dir/gpu-summary.json"

  # Prometheus keeps a deleted pod's series, so this covers replica 2 too.
  # 60 s before the start: the 45 s smoothing window needs history.
  mkdir -p "$dir/prom"
  local ps pe sel name prom_ok=1
  ps=$(awk -v t="$t0" 'BEGIN {printf "%d", t - 60}'); pe=$(awk -v t="$t1" 'BEGIN {printf "%d", t + 10}')
  sel="namespace=\"$NAMESPACE\",isvc=\"$ISVC\""
  if prom_connect; then
    for name in running:vllm:num_requests_running waiting:vllm:num_requests_waiting \
                kv:vllm:kv_cache_usage_perc success:vllm:request_success_total; do
      prom_range "${name#*:}{$sel}" "$ps" "$pe" "$dir/prom/${name%%:*}.json" \
        || { prom_ok=0; log "  WARN: Prometheus export ${name%%:*} failed"; }
    done
    prom_range "$query" "$ps" "$pe" "$dir/prom/keda-query.json" \
      || { prom_ok=0; log "  WARN: Prometheus export keda-query failed"; }
  else
    prom_ok=0; log "  WARN: Prometheus not reachable - no range export"
  fi
  kubectl get events -n "$NAMESPACE" -o json > "$dir/events.json" 2>/dev/null \
    || log "  WARN: events export failed"

  local succ errd ok=0
  succ=$(jq -r '.benchmarks[0].metrics.request_totals.successful // 0' "$dir/guidellm.json" 2>/dev/null || echo 0)
  errd=$(jq -r '.benchmarks[0].metrics.request_totals.errored // 0' "$dir/guidellm.json" 2>/dev/null || echo 0)
  [ "$rc" -eq 0 ] && [ "${succ:-0}" -gt 0 ] && [ "$prom_ok" = 1 ] && ok=1

  jq -n --argjson n "$n" --arg stages "$stages" --argjson seed "$seed" --arg target "$target" \
        --arg model "$MODEL" --arg isvc "$ISVC" --arg so "$SO" --arg hpa "$HPA" --arg query "$query" --arg thr "$threshold" \
        --argjson stepst "$STEP_STAGE" \
        --arg trepo "$TOKENIZER_REPO" --arg trev "${TOKENIZER_REV:-n/a:unpinned (kind)}" \
        --argjson t0 "$t0" --argjson t1 "$t1" --argjson rc "$rc" --argjson succ "${succ:-0}" \
        --argjson errd "${errd:-0}" --argjson prom "$prom_ok" --argjson ok "$ok" --arg platform "$PLATFORM" \
        '{cycle:$n, platform:$platform, stages:$stages, seed:$seed, target:$target, model:$model, isvc:$isvc,
          scaledobject:$so, hpa:$hpa, keda_query:$query, keda_threshold:$thr, step_stage:$stepst,
          request_header:"Connection: close",
          tokenizer:{repo:$trepo, revision:$trev}, launched_at:$t0, ended_at:$t1,
          guidellm_exit:$rc, successful:$succ, errored:$errd, prometheus_export:($prom == 1), ok:($ok == 1)}' \
    > "$dir/cycle.json"
  log "  cycle $n: exit $rc, successful $succ, errored $errd, prometheus export $([ "$prom_ok" = 1 ] && echo ok || echo FAILED)"
  [ "$ok" = 1 ] || { log "cycle $n: FAILED"; return 1; }
  touch "$dir/DONE"; log "cycle $n: DONE"
}

# ------------------------------------------------------------------ main ---
log "step-load run $RUN_ID: $CONFIG on $PLATFORM, ${#CYCLES[@]} cycle(s), ISVC $ISVC"
"$SIDECAR" session "$RESULTS/env-session-$(date -u +%Y%m%dT%H%M%SZ).json"
prom_connect || log "WARN: Prometheus not reachable at start ($PROM_URL) - will retry at export"
failed=0
for i in "${!CYCLES[@]}"; do
  run_cycle $((i + 1)) "${CYCLES[$i]}" || failed=$((failed + 1))
done
if [ "$failed" -eq 0 ]; then
  log "COMPLETE: every cycle DONE - $RESULTS"; exit 0
fi
log "INCOMPLETE: $failed cycle(s) failed. Fix, then: scripts/step-load.sh $CONFIG $RUN_ID"
exit 1
