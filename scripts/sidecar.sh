#!/usr/bin/env bash
#
# scripts/sidecar.sh - the environment record written beside every result.
# Week 4 A4. Numbers are only comparable if we can show WHAT produced them.
#
#   sidecar.sh session     <out.json>                      once per session
#   sidecar.sh leg         <out.json> <isvc> [namespace]   once per leg, after Ready
#   sidecar.sh gpu-sample  <samples.csv>                   during a point; runs until killed
#   sidecar.sh gpu-summary <samples.csv> <out.json>        after the point
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
  local out=$1 uuid name serial driver plimit smax stack
  if [ "$PLATFORM" = gpu ]; then
    local row
    row=$(try nvidia-smi nvidia-smi --query-gpu=uuid,name,serial,driver_version,power.limit,clocks.max.sm \
          --format=csv,noheader,nounits)
    if [[ $row == ERROR:* ]]; then
      uuid=$row name=$row serial=$row driver=$row plimit=$row smax=$row
    else
      IFS=',' read -r uuid name serial driver plimit smax <<<"$(sed 's/, */,/g' <<<"$row")"
    fi
    stack=device-plugin
  else
    uuid=$NA_GPU name=$NA_GPU serial=$NA_GPU driver=$NA_GPU plimit=$NA_GPU smax=$NA_GPU
    stack=$NA_GPU
  fi
  jq -n \
    --arg at "$(now_utc)" --arg platform "$PLATFORM" \
    --arg uuid "$uuid" --arg name "$name" --arg serial "$serial" --arg driver "$driver" \
    --arg plimit "$plimit" --arg smax "$smax" --arg stack "$stack" \
    --arg k8s "$(try k8s-version k8s_version)" \
    --arg commit "$(try repo-commit repo_commit)" \
    --arg py "$(try client-python client_python)" \
    --arg gl "$(try client-guidellm client_guidellm)" \
    '{captured_at: $at, platform: $platform,
      gpu: {uuid: $uuid, name: $name, serial: $serial, driver_version: $driver,
            power_limit_w: $plimit, clocks_max_sm_mhz: $smax},
      gpu_stack: $stack, k8s_version: $k8s, repo_commit: $commit,
      client: {python: $py, guidellm: $gl}}' > "$out"
}

# -------------------------------------------------------------------- leg ---
cmd_leg() {
  local out=$1 isvc=$2 ns=${3:-llm-serving}
  local pod podjson uri prefix repo rev metrics cci vllm_ver

  pod=$(kubectl get pod -n "$ns" -l "serving.kserve.io/inferenceservice=$isvc" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  podjson=$(kubectl get pod -n "$ns" "$pod" -o json 2>/dev/null) || podjson='{}'
  pod_get() { kubectl get --raw "/api/v1/namespaces/$ns/pods/$pod:8080/proxy/$1"; }

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
    --argjson p "$podjson" \
    'def kc: [ $p.spec.containers[]? | select(.name=="kserve-container") ] | first;
     def kcs: [ $p.status.containerStatuses[]? | select(.name=="kserve-container") ] | first;
     def secs(a; b): if (a != null and b != null)
                     then ((b | fromdateiso8601) - (a | fromdateiso8601)) else null end;
     def or_err(msg): if . == null then "ERROR:" + msg else . end;
     {captured_at: $at, isvc: $isvc, pod: $pod,
      model: {storage_uri: $uri, hf_repo: $repo, hf_revision: $rev},
      vllm: {version: $vllm,
             image: (kcs.image | or_err("image")),
             image_id: (kcs.imageID | or_err("imageID")),
             command: (kc.command // "n/a:image entrypoint"),
             args: (kc.args | or_err("args"))},
      kv_cache: {size_tokens: $kv_tokens, block_size: $block, dtype: $kv_dtype,
                 prefix_caching: $prefix_cache, gpu_memory_utilization: $gmu},
      timings_s: {
        storage_copy: ([ $p.status.initContainerStatuses[]?
                         | select(.name=="storage-initializer") | .state.terminated
                         | secs(.startedAt; .finishedAt) ] | first | or_err("storage-initializer times")),
        pod_created_to_ready: ([ $p.status.conditions[]? | select(.type=="Ready")
                                 | secs($p.metadata.creationTimestamp; .lastTransitionTime) ]
                               | first | or_err("Ready condition"))}}' > "$out"
}

# -------------------------------------------------------------- gpu-sample ---
cmd_gpu_sample() {
  local f=$1
  if [ "$PLATFORM" != gpu ]; then echo "$NA_GPU" > "$f"; return 0; fi
  echo "timestamp,clocks_sm_mhz,temperature_c,power_draw_w" > "$f"
  # exec REPLACES this shell with nvidia-smi, so the PID the harness records
  # IS nvidia-smi. Without exec, killing that PID would kill only bash and
  # leave nvidia-smi sampling forever in the background.
  exec nvidia-smi --query-gpu=timestamp,clocks.sm,temperature.gpu,power.draw \
       --format=csv,noheader,nounits -lms 2000 >> "$f"
}

# ------------------------------------------------------------- gpu-summary ---
cmd_gpu_summary() {
  local f=$1 out=$2
  if [ ! -s "$f" ]; then
    jq -n '{gpu_samples: "ERROR:no samples file"}' > "$out"; return 0
  fi
  if [[ $(head -1 "$f") == n/a:* ]]; then
    jq -n --arg v "$(head -1 "$f")" '{gpu_samples: $v}' > "$out"; return 0
  fi
  # Mean/min/max per column. Rows with a non-numeric value (nvidia-smi can
  # print "[N/A]") are skipped rather than counted as zero.
  awk -F', *' '
    NR > 1 && $2 ~ /^[0-9.]+$/ && $3 ~ /^[0-9.]+$/ && $4 ~ /^[0-9.]+$/ {
      n++
      for (i = 2; i <= 4; i++) {
        s[i] += $i
        if (n == 1 || $i < lo[i]) lo[i] = $i
        if (n == 1 || $i > hi[i]) hi[i] = $i
      }
    }
    END {
      if (n == 0) { print "{\"gpu_samples\": \"ERROR:no numeric samples\"}"; exit }
      printf "{\"gpu_samples\": %d", n
      split("clocks_sm_mhz temperature_c power_draw_w", name, " ")
      for (i = 2; i <= 4; i++)
        printf ", \"%s\": {\"mean\": %.1f, \"min\": %s, \"max\": %s}", name[i-1], s[i]/n, lo[i], hi[i]
      print "}"
    }' "$f" | jq . > "$out"
}

case "${1:-}" in
  session)     shift; cmd_session "$@" ;;
  leg)         shift; cmd_leg "$@" ;;
  gpu-sample)  shift; cmd_gpu_sample "$@" ;;
  gpu-summary) shift; cmd_gpu_summary "$@" ;;
  *) sed -n '3,10p' "$0"; exit 2 ;;
esac
