#!/usr/bin/env bash
#
# scripts/benchmark.sh - the unattended week 4 sweep. Week 4 A5.
#
#   scripts/benchmark.sh <config> [run-id]
#
#   <config>  benchmarks/configs/sweep-gpu.sh (measured) | sweep-kind.sh (A7 dry-run)
#   [run-id]  resume that run: legs with a DONE marker are skipped, a partial
#             leg is moved aside and redone. Omitted = new run.
#
# Lifecycle and the reasons for it: NOTES.md, "A5 (part 1)". Per leg:
#   delete the previous ISVC, wait for its pod -> disk preflight -> apply ->
#   Ready -> leg sidecar -> warmup -> primary ladder -> shape-2 ladder -> DONE.
# Then the anchor: same lifecycle, one point.
#
# Exit: 0 every leg and the anchor DONE | 1 something failed (re-run with the
# run-id to redo only that) | 2 usage or config error | 3 disk preflight refused.

# Config variables (TOKENIZER_REPO, ...) are set by the sourced config, which
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
[ -f "$CONFIG" ] || { sed -n '3,9p' "$0"; exit 2; }

if command -v nvidia-smi >/dev/null 2>&1; then
  PLATFORM=gpu
  export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
else
  PLATFORM=kind
fi

# shellcheck source=/dev/null
. "$CONFIG"
# Every setting the harness reads must come from the config. A typo there
# fails here, before any GPU time is spent, not halfway through a sweep.
for v in EXPECT_PLATFORM NAMESPACE BASE_MANIFEST LEGS ANCHOR_LEG ANCHOR_SHAPE ANCHOR_C \
         DISK_MARGIN_GIB READY_TIMEOUT_S TOKENIZER_REPO TOKENIZER_REV TOKENIZER_OFFLINE \
         PRIMARY_PROMPT PRIMARY_OUTPUT PRIMARY_SEED_BASE PRIMARY_LADDER \
         SHAPE2_PROMPT SHAPE2_OUTPUT SHAPE2_SEED_BASE SHAPE2_LADDER \
         WARMUP_C WARMUP_S WARMUP_SEED EDGE_START_S EDGE_END_S GAUGE_INTERVAL_S; do
  declare -p "$v" >/dev/null 2>&1 || die 2 "$CONFIG does not set $v"
done
declare -F measured_s >/dev/null || die 2 "$CONFIG does not define measured_s()"
[ "$EXPECT_PLATFORM" = "$PLATFORM" ] || die 2 "$CONFIG is for $EXPECT_PLATFORM; this is $PLATFORM"
[ "$PLATFORM" = gpu ] && [ -z "$TOKENIZER_REV" ] && die 2 "a GPU sweep needs a pinned TOKENIZER_REV"

RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%MZ)-$PLATFORM}
RESULTS="$REPO_ROOT/benchmarks/results/$RUN_ID"
mkdir -p "$RESULTS"
LOG="$RESULTS/benchmark.log"

# One harness per run directory. An unattended run started twice would
# otherwise drive the same cluster from two processes.
exec 9>"$RESULTS/.lock"
flock -n 9 || die 2 "another benchmark.sh holds $RESULTS"

# The config is frozen at the run's first start. Resuming with a different
# config would mix two experiments under one run-id.
if [ -f "$RESULTS/config.sh" ]; then
  cmp -s "$CONFIG" "$RESULTS/config.sh" || die 2 "config differs from the one this run started with"
else
  cp "$CONFIG" "$RESULTS/config.sh"
fi

# Background samplers must not outlive the harness, whatever ends it.
trap 'kill $(jobs -p) 2>/dev/null' EXIT

# --------------------------------------------------------------- helpers ---
pod_of() {   # exactly one live pod, else "" + diagnostics on stderr (lib-pods.sh)
  one_live_pod "$NAMESPACE" "serving.kserve.io/inferenceservice=$1"
}
metrics_dump() { kubectl get --raw "/api/v1/namespaces/$NAMESPACE/pods/$1:8080/proxy/metrics"; }

target_url() {
  # GPU: the load generator runs on the VM (NOTES, "Load generator runs on the
  # VM"), which reaches the predictor's ClusterIP directly. kind: ClusterIPs
  # are not routable from WSL; the NodePort on localhost:8080 selects qwen-0-5b,
  # which is why the kind config deploys only that name.
  if [ "$PLATFORM" = kind ]; then echo "http://localhost:8080"; return; fi
  local hp
  hp=$(kubectl get svc -n "$NAMESPACE" "$1-predictor" \
       -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}' 2>/dev/null) || return 1
  [ -n "$hp" ] && echo "http://$hp"
}

seed_for() {   # seed_for <shape> <concurrency>: SEED_BASE + index in the ladder
  local base i=0 x
  local -a ladder
  if [ "$1" = shape2 ]; then base=$SHAPE2_SEED_BASE; ladder=("${SHAPE2_LADDER[@]}")
  else base=$PRIMARY_SEED_BASE; ladder=("${PRIMARY_LADDER[@]}"); fi
  for x in "${ladder[@]}"; do
    [ "$x" = "$2" ] && { echo $((base + i)); return 0; }
    i=$((i + 1))
  done
  return 1
}

clear_namespace() {
  # Legs are separate ISVCs, so Recreate cannot keep them apart: delete, then
  # wait until no predictor pod is left, which also frees its emptyDir copy.
  kubectl delete isvc -n "$NAMESPACE" --all --wait=true --timeout=300s >/dev/null 2>&1
  local t=0
  while [ -n "$(kubectl get pods -n "$NAMESPACE" -l serving.kserve.io/inferenceservice -o name 2>/dev/null)" ]; do
    [ "$t" -ge 300 ] && return 1
    sleep 5; t=$((t + 5))
  done
}

disk_free_gib() {
  # Free space where the storage-initializer's emptyDir copy will land.
  if [ "$PLATFORM" = kind ]; then
    docker exec llm-serving-lab-control-plane df -B1 --output=avail /var/lib/kubelet
  else
    df -B1 --output=avail /var/lib/kubelet
  fi | tail -1 | awk '{printf "%.2f", $1 / 1073741824}'
}

preflight() {   # preflight <leg size GiB>: true if free >= size + margin
  local need free
  need=$(awk -v s="$1" -v m="$DISK_MARGIN_GIB" 'BEGIN {printf "%.2f", s + m}')
  free=$(disk_free_gib)
  log "  disk: ${free:-unknown} GiB free, need $need"
  # An unreadable value counts as zero: refuse rather than guess.
  awk -v f="${free:-0}" -v n="$need" 'BEGIN {exit !(f >= n)}'
}

apply_leg_isvc() {   # apply_leg_isvc <isvc> <s3 prefix> <rendered.yaml>
  # Render from the proven base manifest: only metadata.name and the last path
  # segment of storageUri change. The server-side dry-run proves the render
  # BEFORE anything is created.
  sed -e "s|^  name: .*$|  name: $1|" \
      -e "s|^\(      storageUri: .*/\)[^/]*$|\1$2|" "$BASE_MANIFEST" > "$3"
  local got
  got=$(kubectl apply --dry-run=server -f "$3" -o json 2>/dev/null \
        | jq -r '.metadata.name + " " + .spec.predictor.model.storageUri') || return 1
  [[ $got == "$1 "*"/$2" ]] || { log "  render check failed: got '$got'"; return 1; }
  kubectl apply -f "$3" >/dev/null
}

gauge() { grep -E "^$2[{ ]" <<<"$1" | head -1 | awk '{print $NF}'; }

gauge_sampler() {   # gauge_sampler <pod> <csv>: until killed
  echo "epoch_s,num_requests_running,num_requests_waiting,kv_cache_usage_perc" > "$2"
  local m
  while :; do
    m=$(metrics_dump "$1" 2>/dev/null)
    printf '%s,%s,%s,%s\n' "$(date +%s.%3N)" \
      "$(gauge "$m" vllm:num_requests_running)" \
      "$(gauge "$m" vllm:num_requests_waiting)" \
      "$(gauge "$m" vllm:kv_cache_usage_perc)" >> "$2"
    sleep "$GAUGE_INTERVAL_S"
  done
}

# ------------------------------------------------------------- one point ---
run_point() {   # run_point <dir> <leg> <pod> <target> <model> <shape> <c> <seed> <measured_s>
  local dir=$1 leg=$2 pod=$3 target=$4 model=$5 shape=$6 c=$7 seed=$8 meas=$9
  local prompt=$PRIMARY_PROMPT output=$PRIMARY_OUTPUT
  if [ "$shape" = shape2 ]; then prompt=$SHAPE2_PROMPT output=$SHAPE2_OUTPUT; fi
  local total=$((EDGE_START_S + meas + EDGE_END_S))
  mkdir -p "$dir"
  log "  point $(basename "$dir"): c=$c seed=$seed ${prompt}/${output} tok, ${meas}s measured"

  # Every option is a JSON object built by jq: quoting-safe, and the only form
  # that carries nested settings (tokenizer revision, edge exclusion).
  local backend tok data seedj prof cons outj
  backend=$(jq -nc --arg t "$target" --arg m "$model" '{kind:"openai_http", target:$t, model:$m}')
  tok=$(jq -nc --arg m "$TOKENIZER_REPO" --arg r "$TOKENIZER_REV" \
        '{kind:"hf_auto", model:$m} + (if $r == "" then {} else {load_kwargs:{revision:$r}} end)')
  data=$(jq -nc --argjson p "$prompt" --argjson o "$output" \
        '{kind:"synthetic_text", prompt_tokens:$p, output_tokens:$o}')
  seedj=$(jq -nc --argjson s "$seed" '{kind:"static", value:$s}')
  prof=$(jq -nc --argjson c "$c" --argjson w "$EDGE_START_S" --argjson e "$EDGE_END_S" \
        '{kind:"concurrent", streams:[$c], warmup:{value:$w, mode:"duration"}, cooldown:{value:$e, mode:"duration"}}')
  cons=$(jq -nc --argjson s "$total" '{kind:"max_duration", seconds:$s}')
  outj=$(jq -nc --arg p "$dir/guidellm.json" '{kind:"json", path:$p}')

  local envp=()
  [ "$TOKENIZER_OFFLINE" = 1 ] && envp=(env HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1)

  metrics_dump "$pod" > "$dir/metrics-before.txt" 2>/dev/null || log "  WARN: metrics-before failed"
  gauge_sampler "$pod" "$dir/gauges.csv" &
  local gpid=$!
  "$SIDECAR" gpu-sample "$dir/gpu.csv" &
  local npid=$!

  local t0 t1 rc
  t0=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  "${envp[@]}" uv run --locked guidellm run \
    --backend "$backend" --tokenizer "$tok" --data "$data" --seed "$seedj" \
    --profile "$prof" --constraint "$cons" --output "$outj" \
    --disable-console-interactive > "$dir/guidellm.log" 2>&1
  rc=$?
  t1=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  kill "$gpid" "$npid" 2>/dev/null; wait "$gpid" "$npid" 2>/dev/null
  metrics_dump "$pod" > "$dir/metrics-after.txt" 2>/dev/null || log "  WARN: metrics-after failed"
  "$SIDECAR" gpu-summary "$dir/gpu.csv" "$dir/gpu-summary.json"

  # Exit 0 is not enough: a run where every request errored also exits 0.
  local ok=0 succ errd
  succ=$(jq -r '.benchmarks[0].metrics.request_totals.successful // 0' "$dir/guidellm.json" 2>/dev/null || echo 0)
  errd=$(jq -r '.benchmarks[0].metrics.request_totals.errored // 0' "$dir/guidellm.json" 2>/dev/null || echo 0)
  [ "$rc" -eq 0 ] && [ "${succ:-0}" -gt 0 ] && ok=1

  jq -n --arg leg "$leg" --arg model "$model" --arg shape "$shape" --arg target "$target" \
        --argjson c "$c" --argjson seed "$seed" --argjson prompt "$prompt" --argjson output "$output" \
        --argjson meas "$meas" --argjson es "$EDGE_START_S" --argjson ee "$EDGE_END_S" \
        --arg trepo "$TOKENIZER_REPO" --arg trev "${TOKENIZER_REV:-n/a:unpinned (kind)}" \
        --arg toff "$TOKENIZER_OFFLINE" --arg t0 "$t0" --arg t1 "$t1" --argjson rc "$rc" \
        --argjson succ "${succ:-0}" --argjson errd "${errd:-0}" --argjson ok "$ok" \
        --arg warm "$([ "$(basename "$dir")" = warmup ] && echo true || echo false)" \
    '{leg:$leg, model:$model, shape:$shape, concurrency:$c, seed:$seed,
      prompt_tokens:$prompt, output_tokens:$output,
      measured_s:$meas, edge_start_s:$es, edge_end_s:$ee, target:$target,
      tokenizer:{repo:$trepo, revision:$trev, offline:($toff == "1")},
      warmup_discarded:($warm == "true"), started_at:$t0, ended_at:$t1,
      guidellm_exit:$rc, requests_successful:$succ, requests_errored:$errd,
      status:(if $ok == 1 then "ok" else "failed" end)}' > "$dir/point.json"

  [ "$ok" -eq 1 ] || { log "  point FAILED (exit $rc, successful $succ) - see $dir/guidellm.log"; return 1; }
  [ "$errd" -gt 0 ] && log "  WARN: $errd errored requests"
  return 0
}

# --------------------------------------------------------------- one leg ---
leg_failed() {   # leg_failed <dir> <msg>: keep evidence for the post-mortem
  log "  LEG FAILED: $2"
  { kubectl get isvc,pods -n "$NAMESPACE" -o wide; kubectl describe isvc -n "$NAMESPACE"; } \
    > "$1/failure.txt" 2>&1
  return 1
}

run_leg() {   # run_leg <leg line> <dir> <full|anchor>
  local id isvc prefix size dir=$2 mode=$3
  IFS='|' read -r id isvc prefix size <<<"$1"
  if [ -f "$dir/DONE" ]; then log "$(basename "$dir"): DONE earlier, skipping"; return 0; fi
  if [ -d "$dir" ]; then
    local aside; aside="$dir.failed-$(date -u +%Y%m%dT%H%M%SZ)"
    mv "$dir" "$aside"; log "$(basename "$dir"): partial results moved to $(basename "$aside")"
  fi
  mkdir -p "$dir"
  log "$(basename "$dir"): leg $id -> $isvc (s3 .../$prefix, ${size} GiB)"

  clear_namespace || { leg_failed "$dir" "previous predictor pod did not go away"; return 1; }
  preflight "$size" || die 3 "disk preflight refused leg $id - see the SETTLED disk decision"
  apply_leg_isvc "$isvc" "$prefix" "$dir/isvc.yaml" || { leg_failed "$dir" "render/apply failed"; return 1; }

  local t0=$SECONDS
  kubectl wait --for=condition=Ready "isvc/$isvc" -n "$NAMESPACE" --timeout="${READY_TIMEOUT_S}s" >/dev/null 2>&1 \
    || { leg_failed "$dir" "not Ready within ${READY_TIMEOUT_S}s"; return 1; }
  log "  Ready after $((SECONDS - t0)) s"

  "$SIDECAR" leg "$dir/env-leg.json" "$isvc" "$NAMESPACE"
  local pod target
  pod=$(pod_of "$isvc"); target=$(target_url "$isvc")
  if [ -z "$pod" ] || [ -z "$target" ]; then
    leg_failed "$dir" "no pod or no target URL"; return 1
  fi

  run_point "$dir/warmup" "$id" "$pod" "$target" "$isvc" primary "$WARMUP_C" "$WARMUP_SEED" "$WARMUP_S" \
    || { leg_failed "$dir" "warmup failed"; return 1; }

  local shape c points=()
  if [ "$mode" = anchor ]; then
    points=("$ANCHOR_SHAPE:$ANCHOR_C")
  else
    for c in "${PRIMARY_LADDER[@]}"; do points+=("primary:$c"); done
    for c in "${SHAPE2_LADDER[@]}"; do points+=("shape2:$c"); done
  fi
  local p seed
  for p in "${points[@]}"; do
    shape=${p%%:*} c=${p##*:}
    seed=$(seed_for "$shape" "$c") || { leg_failed "$dir" "c=$c not in the $shape ladder"; return 1; }
    run_point "$dir/$(printf '%s-c%03d' "$shape" "$c")" "$id" "$pod" "$target" "$isvc" \
              "$shape" "$c" "$seed" "$(measured_s "$shape" "$c")" \
      || { leg_failed "$dir" "point $shape c=$c failed"; return 1; }
  done

  date -u +%Y-%m-%dT%H:%M:%SZ > "$dir/DONE"
  log "$(basename "$dir"): DONE"
}

# ------------------------------------------------------------------ main ---
log "run $RUN_ID | config $CONFIG | platform $PLATFORM"

# One session record per invocation: a resumed run may be on a different boot
# and therefore a different physical GPU. A6 compares them.
"$SIDECAR" session "$RESULTS/env-session-$(date -u +%Y%m%dT%H%M%SZ).json"
uuids=$(jq -r '.gpu.uuid' "$RESULTS"/env-session-*.json | sort -u | wc -l)
[ "$uuids" -gt 1 ] && log "WARNING: this run now spans $uuids different GPUs - the anchor is the cross-card check"

failed=0
for leg in "${LEGS[@]}"; do
  run_leg "$leg" "$RESULTS/${leg%%|*}" full || failed=$((failed + 1))
done

anchor=""
for leg in "${LEGS[@]}"; do [ "${leg%%|*}" = "$ANCHOR_LEG" ] && anchor=$leg; done
[ -n "$anchor" ] || die 2 "ANCHOR_LEG '$ANCHOR_LEG' is not in LEGS"
run_leg "$anchor" "$RESULTS/anchor" anchor || failed=$((failed + 1))

if [ "$failed" -eq 0 ]; then
  log "COMPLETE: every leg and the anchor are DONE - $RESULTS"
  exit 0
fi
log "INCOMPLETE: $failed failed. Fix, then: scripts/benchmark.sh $CONFIG $RUN_ID"
exit 1
