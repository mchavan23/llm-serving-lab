#!/usr/bin/env bash
#
# scripts/sidecar.sh - the environment record written beside every result.
# Week 4 A4. Numbers are only comparable if we can show WHAT produced them.
#
#   sidecar.sh session     <out.json>                      once per session
#   sidecar.sh leg         <out.json> <isvc> [namespace]   once per leg, after Ready
#   sidecar.sh gpu-sample  <samples.csv> [interval_ms]     during a point; runs until killed
#   sidecar.sh gpu-summary <samples.csv> <out.json>        after the point (per GPU)
#
# Every field holds one of three things:
#   a value           - collected
#   "n/a:<why>"       - absent BY DESIGN (e.g. GPU fields on kind)
#   "ERROR:<what>"    - collection failed
# The A7 gate is: no "ERROR:" anywhere. A failed FIELD never makes this script
# exit non-zero - in an unattended sweep a missing field must not kill the run;
# it must be visible in the file instead.

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2
# shellcheck source=scripts/variants.sh
. "$REPO_ROOT/scripts/variants.sh"
. "$REPO_ROOT/scripts/lib-pods.sh"

# Platform: nvidia-smi present = the GPU VM (k3s), absent = kind on the laptop.
if command -v nvidia-smi >/dev/null 2>&1; then
  PLATFORM=gpu
  export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
else
  PLATFORM=kind
fi
NA_GPU="n/a:no GPU on $PLATFORM"

# try LABEL CMD... : print CMD's output, or "ERROR:LABEL" if it fails or is empty.
try() {
  local label=$1 out; shift
  if out=$("$@" 2>/dev/null) && [ -n "$out" ]; then printf '%s' "$out"
  else printf 'ERROR:%s' "$label"; fi
}

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# ---------------------------------------------------------------- session ---
repo_commit() {
  # On the VM the repo arrives by `git archive` (no .git), so .deployed-commit
  # is the record. On the laptop, ask git, and say so if the tree is dirty:
  # results from uncommitted code are not reproducible from the commit alone.
  if [ -f .deployed-commit ]; then cat .deployed-commit; return; fi
  local c; c=$(git rev-parse HEAD) || return 1
  git diff --quiet HEAD || c="$c-dirty"
  echo "$c"
}
k8s_version()     { kubectl version -o json | jq -re '.serverVersion.gitVersion'; }
client_python()   { uv run --locked python -c 'import platform; print(platform.python_version())'; }
client_guidellm() { uv run --locked guidellm --version | awk '{print $NF}'; }

cmd_session() {
  local out=$1 uuid name serial driver plimit smax stack gpus_json
  if [ "$PLATFORM" = gpu ]; then
    local row
    row=$(try nvidia-smi nvidia-smi --query-gpu=uuid,name,serial,driver_version,power.limit,clocks.max.sm \
          --format=csv,noheader,nounits)
    if [[ $row == ERROR:* ]]; then
      uuid=$row name=$row serial=$row driver=$row plimit=$row smax=$row
    else
      # sed, not ${row//, /,}: the regex ", *" takes ANY number of spaces.
      # shellcheck disable=SC2001
      IFS=',' read -r uuid name serial driver plimit smax <<<"$(sed 's/, */,/g' <<<"$row")"
    fi
    stack=device-plugin
    # Every GPU, not only the first (week 5 runs two). `gpu` above stays GPU 0
    # because parse_results.py reads it.
    gpus_json=$(nvidia-smi --query-gpu=index,uuid,name,serial,driver_version,power.limit,clocks.max.sm \
        --format=csv,noheader,nounits 2>/dev/null | sed 's/, */,/g' \
      | jq -R -s 'split("\n") | map(select(length > 0) | split(",")
          | {index: (.[0] | tonumber), uuid: .[1], name: .[2], serial: .[3],
             driver_version: .[4], power_limit_w: .[5], clocks_max_sm_mhz: .[6]})') \
      || gpus_json='"ERROR:nvidia-smi gpus"'
    [ "$gpus_json" = "[]" ] && gpus_json='"ERROR:nvidia-smi gpus"'
  else
    uuid=$NA_GPU name=$NA_GPU serial=$NA_GPU driver=$NA_GPU plimit=$NA_GPU smax=$NA_GPU
    stack=$NA_GPU
    gpus_json=$(jq -n --arg v "$NA_GPU" '$v')
  fi
  jq -n \
    --arg at "$(now_utc)" --arg platform "$PLATFORM" \
    --arg kernel "$(try kernel uname -r)" \
    --arg uuid "$uuid" --arg name "$name" --arg serial "$serial" --arg driver "$driver" \
    --arg plimit "$plimit" --arg smax "$smax" --arg stack "$stack" \
    --arg k8s "$(try k8s-version k8s_version)" \
    --arg commit "$(try repo-commit repo_commit)" \
    --arg py "$(try client-python client_python)" \
    --arg gl "$(try client-guidellm client_guidellm)" \
    --argjson gpus "$gpus_json" \
    '{captured_at: $at, platform: $platform, kernel: $kernel,
      gpu: {uuid: $uuid, name: $name, serial: $serial, driver_version: $driver,
            power_limit_w: $plimit, clocks_max_sm_mhz: $smax},
      gpu_count: (if ($gpus | type) == "array" then ($gpus | length) else $gpus end),
      gpus: $gpus,
      gpu_stack: $stack, k8s_version: $k8s, repo_commit: $commit,
      client: {python: $py, guidellm: $gl}}' > "$out"
}

# -------------------------------------------------------------------- leg ---
cmd_leg() {
  local out=$1 isvc=$2 ns=${3:-llm-serving}
  local pod podjson uri prefix repo rev metrics cci vllm_ver logs

  # Not exactly one live pod -> diagnostics to the run log, pod stays empty and
  # the record degrades to '{}' as before; the harness then fails the leg.
  pod=$(one_live_pod "$ns" "serving.kserve.io/inferenceservice=$isvc") || pod=""
  podjson=$(kubectl get pod -n "$ns" "$pod" -o json 2>/dev/null) || podjson='{}'
  pod_get() { kubectl get --raw "/api/v1/namespaces/$ns/pods/$pod:8080/proxy/$1"; }
  # vLLM's own startup milestones, with the kubelet's timestamp on each line.
  # Captured NOW because they vanish with the pod (week 4 lost them). Taken
  # from the log, not inferred from pod conditions: Ready is gated by the
  # readiness-probe schedule, which hides how long the engine really took.
  logs=$(kubectl logs -n "$ns" "$pod" -c kserve-container --timestamps 2>/dev/null) || logs=""
  first_line() { grep -m1 -E "$1" <<<"$logs"; }

  # Model identity: the ISVC's storageUri prefix, looked up in variants.sh.
  uri=$(try storage-uri kubectl get isvc -n "$ns" "$isvc" -o jsonpath='{.spec.predictor.model.storageUri}')
  prefix=${uri##*/}                       # s3://models/llama-3.1-8b-fp8 -> llama-3.1-8b-fp8
  repo="" rev=""
  for v in "${VARIANTS[@]}"; do
    IFS='|' read -r r s p <<<"$v"
    [ "$p" = "$prefix" ] && repo=$r rev=$s
  done
  if [ -z "$repo" ]; then
    if [ "$PLATFORM" = kind ]; then repo="n/a:$prefix is not a benchmark leg (kind dry-run)"
    else repo="ERROR:$prefix not in variants.sh"; fi
    rev=$repo
  fi

  vllm_ver=$(try vllm-version bash -c "kubectl get --raw /api/v1/namespaces/$ns/pods/$pod:8080/proxy/version | jq -re .version")
  metrics=$(pod_get metrics 2>/dev/null) || metrics=""
  cci=$(grep '^vllm:cache_config_info{' <<<"$metrics" | head -1)
  # label NAME: one value from cache_config_info. The [{,] before the name
  # anchors it to a whole label, so "block_size" cannot match
  # "user_specified_block_size".
  label() {
    local v; v=$(grep -o "[{,]$1=\"[^\"]*\"" <<<"$cci" | head -1 | sed 's/^.*="\(.*\)"$/\1/')
    [ -n "$v" ] && printf '%s' "$v" || printf 'ERROR:cache_config_info.%s' "$1"
  }

  jq -n \
    --arg at "$(now_utc)" --arg isvc "$isvc" --arg pod "${pod:-ERROR:no pod}" \
    --arg uri "$uri" --arg repo "$repo" --arg rev "$rev" --arg vllm "$vllm_ver" \
    --arg kv_tokens "$(label kv_cache_size_tokens)" --arg block "$(label block_size)" \
    --arg kv_dtype "$(label cache_dtype)" --arg prefix_cache "$(label enable_prefix_caching)" \
    --arg gmu "$(label gpu_memory_utilization)" \
    --arg l_load  "$(first_line 'Model loading took')" \
    --arg l_init  "$(first_line 'init engine .* took')" \
    --arg l_ready "$(first_line 'Application startup complete')" \
    --argjson p "$podjson" \
    'def kc: [ $p.spec.containers[]? | select(.name=="kserve-container") ] | first;
     def kcs: [ $p.status.containerStatuses[]? | select(.name=="kserve-container") ] | first;
     def secs(a; b): if (a != null and b != null)
                     then ((b | fromdateiso8601) - (a | fromdateiso8601)) else null end;
     def or_err(msg): if . == null then "ERROR:" + msg else . end;
     # Log line -> its kubelet timestamp, cut to whole seconds: the jq builtin
     # fromdateiso8601 rejects fractional seconds, and pod conditions are
     # whole-second anyway, so differences stay like-for-like.
     def ts: if . == "" then null else (split(" ")[0] | sub("\\.[0-9]+Z$"; "Z")) end;
     def num(re): (capture(re) | .v | tonumber)? // null;
     def ready_at: [ $p.status.conditions[]? | select(.type=="Ready") | .lastTransitionTime ] | first;
     {captured_at: $at, isvc: $isvc, pod: $pod,
      model: {storage_uri: $uri, hf_repo: $repo, hf_revision: $rev},
      vllm: {version: $vllm,
             image: (kcs.image | or_err("image")),
             image_id: (kcs.imageID | or_err("imageID")),
             command: (kc.command // "n/a:image entrypoint"),
             args: (kc.args | or_err("args"))},
      kv_cache: {size_tokens: $kv_tokens, block_size: $block, dtype: $kv_dtype,
                 prefix_caching: $prefix_cache, gpu_memory_utilization: $gmu},
      startup: {
        container_started_at: (kcs.state.running.startedAt | or_err("container startedAt")),
        model_loaded_at:      ($l_load | ts | or_err("no Model loading line")),
        model_load_s:         ($l_load | num("and (?<v>[0-9.]+) seconds") | or_err("Model loading seconds")),
        engine_init_done_at:  ($l_init | ts | or_err("no init engine line")),
        engine_init_s:        ($l_init | num("took (?<v>[0-9.]+) s") | or_err("init engine seconds")),
        compile_s:            (if $l_init == "" then "ERROR:no init engine line"
                               else ($l_init | num("compilation: (?<v>[0-9.]+) s")
                                     // "n/a:this vLLM build does not log compilation time") end),
        api_ready_at:         ($l_ready | ts | or_err("no Application startup complete line")),
        pod_ready_at:         (ready_at | or_err("Ready condition"))},
      timings_s: {
        container_start_to_api_ready: (secs(kcs.state.running.startedAt; ($l_ready | ts))
                                       | or_err("container start or startup-complete time")),
        api_ready_to_pod_ready: (secs(($l_ready | ts); ready_at)
                                 | or_err("startup-complete or Ready time")),
        storage_copy: ([ $p.status.initContainerStatuses[]?
                         | select(.name=="storage-initializer") | .state.terminated
                         | secs(.startedAt; .finishedAt) ] | first | or_err("storage-initializer times")),
        pod_created_to_ready: ([ $p.status.conditions[]? | select(.type=="Ready")
                                 | secs($p.metadata.creationTimestamp; .lastTransitionTime) ]
                               | first | or_err("Ready condition"))}}' > "$out"
}

# -------------------------------------------------------------- gpu-sample ---
# One row per GPU per tick, tagged with the card's index and UUID (week 5 A4:
# with two GPUs the rows must say which card they came from). Optional second
# argument: interval in ms (default 2000, as week 4; the step harness uses 1000).
GPU_FIELDS="index,uuid,timestamp,clocks.sm,temperature.gpu,power.draw,utilization.gpu,memory.used"
GPU_HEADER="index,uuid,timestamp,clocks_sm_mhz,temperature_c,power_draw_w,utilization_gpu_pct,memory_used_mib"
cmd_gpu_sample() {
  local f=$1 ms=${2:-2000}
  if [ "$PLATFORM" != gpu ]; then echo "$NA_GPU" > "$f"; return 0; fi
  echo "$GPU_HEADER" > "$f"
  # exec REPLACES this shell with nvidia-smi, so the PID the harness records
  # IS nvidia-smi. Without exec, killing that PID would kill only bash and
  # leave nvidia-smi sampling forever in the background.
  exec nvidia-smi --query-gpu="$GPU_FIELDS" --format=csv,noheader,nounits -lms "$ms" >> "$f"
}

# ------------------------------------------------------------- gpu-summary ---
# Mean/min/max per metric, PER GPU, in "gpus": [...] - never averaged across
# cards (on two GPUs an idle card would dilute a busy one).
# The week-4 top-level fields (gpu_samples, clocks_sm_mhz, temperature_c,
# power_draw_w) are kept, identical, when exactly ONE GPU was sampled, so
# parse_results.py is unchanged. With more than one GPU they become
# "n/a:multi-gpu ..." and the parser leaves those columns empty.
# Also reads week 4's 4-column files (no index/uuid): treated as one GPU, index 0.
cmd_gpu_summary() {
  local f=$1 out=$2
  if [ ! -s "$f" ]; then
    jq -n '{gpu_samples: "ERROR:no samples file"}' > "$out"; return 0
  fi
  if [[ $(head -1 "$f") == n/a:* ]]; then
    jq -n --arg v "$(head -1 "$f")" '{gpu_samples: $v}' > "$out"; return 0
  fi
  # Non-numeric values (nvidia-smi can print "[N/A]") are skipped per metric,
  # not counted as zero. A row counts as a sample only if the three week-4
  # metrics are all numeric - the same rule as before.
  awk -F', *' '
    NR == 1 {
      old = ($1 == "timestamp")              # week-4 format: no index/uuid
      if (old) { m = 3; c0 = 2; split("clocks_sm_mhz temperature_c power_draw_w", name, " ") }
      else     { m = 5; c0 = 4; split("clocks_sm_mhz temperature_c power_draw_w utilization_gpu_pct memory_used_mib", name, " ") }
      next
    }
    {
      g = old ? 0 : $1
      if (!(g in seen)) { seen[g] = 1; order[++ng] = g; uuid[g] = old ? "n/a:week-4 format" : $2 }
      ok = 1
      for (k = 0; k < 3; k++) if ($(c0 + k) !~ /^[0-9.]+$/) ok = 0
      if (!ok) next
      n[g]++
      for (k = 0; k < m; k++) {
        v = $(c0 + k)
        if (v !~ /^[0-9.]+$/) continue
        key = g SUBSEP k
        cnt[key]++; s[key] += v
        if (cnt[key] == 1 || v + 0 < lo[key] + 0) lo[key] = v
        if (cnt[key] == 1 || v + 0 > hi[key] + 0) hi[key] = v
      }
    }
    function stats(g, k,   key) {
      key = g SUBSEP k
      if (!cnt[key]) return sprintf("\"%s\": \"ERROR:no numeric samples\"", name[k + 1])
      return sprintf("\"%s\": {\"mean\": %.1f, \"min\": %s, \"max\": %s}", name[k + 1], s[key] / cnt[key], lo[key], hi[key])
    }
    END {
      total = 0
      for (i = 1; i <= ng; i++) total += n[order[i]]
      if (total == 0) { print "{\"gpu_samples\": \"ERROR:no numeric samples\"}"; exit }
      if (ng == 1) {
        g = order[1]
        printf "{\"gpu_samples\": %d", n[g]
        for (k = 0; k < 3; k++) printf ", %s", stats(g, k)
      } else {
        printf "{\"gpu_samples\": \"n/a:multi-gpu (%d GPUs), see gpus[]\"", ng
      }
      printf ", \"gpu_count\": %d, \"gpus\": [", ng
      for (i = 1; i <= ng; i++) {
        g = order[i]
        printf "%s{\"index\": %d, \"uuid\": \"%s\", \"samples\": %d", (i > 1 ? ", " : ""), g, uuid[g], n[g] + 0
        for (k = 0; k < m; k++) printf ", %s", stats(g, k)
        printf "}"
      }
      print "]}"
    }' "$f" | jq . > "$out"
}

case "${1:-}" in
  session)     shift; cmd_session "$@" ;;
  leg)         shift; cmd_leg "$@" ;;
  gpu-sample)  shift; cmd_gpu_sample "$@" ;;
  gpu-summary) shift; cmd_gpu_summary "$@" ;;
  *) sed -n '3,10p' "$0"; exit 2 ;;
esac
