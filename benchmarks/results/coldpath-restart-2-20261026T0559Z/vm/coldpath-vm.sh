#!/usr/bin/env bash
#
# scripts/coldpath-vm.sh - VM side of the cold-path measurement. Week 5 A5.
# Shipped over SSH by scripts/coldpath.sh and run from its own directory; it
# uses NO repo files (the VM may still run an older checkout at boot).
#
#   coldpath-vm.sh probe   <dir>   detached: wait for the first token, then 2 more
#   coldpath-vm.sh collect <dir>   afterwards: the VM's own records, raw
#
# probe writes <dir>/probe.jsonl (VM clock, epoch s) and, when finished,
# <dir>/PROBE_DONE = "ok first_token" | "no_isvc" | "timeout <stage>".
# Request: POST /v1/completions, max_tokens 1, NOT streamed - its total time is
# the time to first token (a streamed response sends headers before the first
# token, so curl would time the headers).
# collect writes <dir>/vm-facts.json (boot time, systemd unit times, GPUs) and
# <dir>/k8s/ (nodes, pods, ISVCs, events as JSON; predictor logs; k3s journal).
# Interpretation is the parser's job (scripts/parse_coldpath.py).
#
# Test seams: COLD_TARGET (base URL instead of the predictor ClusterIP),
# COLD_KUBECONFIG, COLD_ISVC (which ISVC, if several), COLD_PROBE_MAX_S,
# COLD_NO_ISVC_S (grace before "no_isvc", default 180).
set -uo pipefail
cmd=${1:-}; dir=${2:-}
if [ -z "$dir" ] || ! mkdir -p "$dir"; then echo "usage: $0 probe|collect <dir>" >&2; exit 2; fi
if [ -n "${COLD_KUBECONFIG:-}" ]; then export KUBECONFIG=$COLD_KUBECONFIG
elif [ -f /etc/rancher/k3s/k3s.yaml ]; then export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; fi

now() { date +%s.%N; }
ev() {   # ev <event> [json fields]
  printf '{"t":%s,"event":"%s"%s}\n' "$(now)" "$1" "${2:+,$2}" >> "$dir/probe.jsonl"
}
flush_errors() {   # one line per run of identical failures, written when the run ends
  [ -n "$last_err" ] && ev attempt_errors "\"error\":\"$last_err\",\"count\":$n_err"
  last_err=""; n_err=0
}
fail() {   # fail <error class>: count it, starting a new run if the class changed
  [ "$1" != "$last_err" ] && flush_errors
  last_err=$1; n_err=$((n_err + 1))
}

probe() {
  local max=${COLD_PROBE_MAX_S:-1500} start end stage="k8s_api" isvc="" url="${COLD_TARGET:-}" model=""
  local ok=0 api_at="" code body t0 t1 out
  last_err="" n_err=0
  start=$(date +%s); end=$((start + max))
  ev probe_start "\"target_override\":\"${COLD_TARGET:-}\""
  local before
  while [ "$(date +%s)" -lt "$end" ]; do
    before=$stage
    case $stage in
      k8s_api)
        if kubectl get --raw=/readyz >/dev/null 2>&1; then
          ev k8s_api_up; api_at=$(date +%s); stage=isvc
        fi ;;
      isvc)
        isvc=$(kubectl get isvc -A -o json 2>/dev/null | jq -r --arg want "${COLD_ISVC:-}" \
               '[.items[] | select($want == "" or .metadata.name == $want)][0] // empty
                | "\(.metadata.namespace)/\(.metadata.name)"')
        if [ -n "$isvc" ]; then
          ev isvc_found "\"isvc\":\"$isvc\""; stage=target
        elif [ $(( $(date +%s) - api_at )) -ge "${COLD_NO_ISVC_S:-180}" ]; then
          ev no_isvc; echo "no_isvc" > "$dir/PROBE_DONE"; return 0
        fi ;;
      target)
        if [ -z "$url" ]; then
          local hp
          hp=$(kubectl get svc -n "${isvc%/*}" "${isvc#*/}-predictor" \
               -o jsonpath='{.spec.clusterIP}:{.spec.ports[0].port}' 2>/dev/null)
          [ -n "$hp" ] && [ "${hp%:*}" != "" ] && url="http://$hp"
        fi
        [ -n "$url" ] && { ev target "\"url\":\"$url\""; stage=models; } ;;
      models)
        out=$(curl -s --max-time 5 -w '\n%{http_code}' "$url/v1/models" 2>&1)
        code=${out##*$'\n'}; body=${out%$'\n'*}
        if [ "$code" = 200 ] && model=$(jq -r '.data[0].id // empty' <<<"$body" 2>/dev/null) && [ -n "$model" ]; then
          flush_errors; ev models_ok "\"model\":\"$model\""; stage=requests
        else
          fail "models:${code:-000}"
        fi ;;
      requests)
        t0=$(now)
        out=$(curl -s --max-time 300 -o /dev/null -w '%{http_code} %{time_total}' \
              -H 'Content-Type: application/json' \
              -d "{\"model\":\"$model\",\"prompt\":\"Hello\",\"max_tokens\":1,\"stream\":false}" \
              "$url/v1/completions" 2>&1)
        t1=$(now); code=${out%% *}
        if [ "$code" = 200 ]; then
          flush_errors; ok=$((ok + 1))
          ev request "\"n\":$ok,\"sent\":$t0,\"done\":$t1,\"total_s\":${out#* },\"code\":200"
          [ "$ok" -ge 3 ] && { echo "ok first_token" > "$dir/PROBE_DONE"; return 0; }
        else
          fail "completions:${code:-000}"
        fi ;;
    esac
    # Sleep only while waiting; a stage that just advanced goes straight on.
    # The request stage always paces itself at 1 s.
    if [ "$stage" = "$before" ] || [ "$stage" = requests ]; then sleep 1; fi
  done
  flush_errors
  ev probe_timeout "\"stage\":\"$stage\""
  echo "timeout $stage" > "$dir/PROBE_DONE"
}

unit_epoch() {   # unit_epoch <unit> <property>: wall time from systemd's monotonic stamp
  local mono
  mono=$(systemctl show -p "$2" --value "$1" 2>/dev/null)
  if [[ $mono =~ ^[0-9]+$ ]] && [ "$mono" -gt 0 ]; then
    awk -v b="$boot" -v m="$mono" 'BEGIN {printf "%.3f", b + m / 1e6}'
  else echo null; fi
}

collect() {
  local k="$dir/k8s" boot units u gpus
  mkdir -p "$k"
  # Boot time to sub-second: wall clock now minus seconds since boot.
  boot=$(awk -v n="$(now)" '{printf "%.3f", n - $1}' /proc/uptime)
  units="{}"
  for u in k3s.service ssh.service ssh.socket sshd.service multi-user.target \
           network-online.target chrony.service systemd-timesyncd.service; do
    units=$(jq -c --arg u "$u" --argjson a "$(unit_epoch "$u" ActiveEnterTimestampMonotonic)" \
                  --argjson s "$(unit_epoch "$u" ExecMainStartTimestampMonotonic)" \
             '. + {($u): {active: $a, main_started: $s}}' <<<"$units")
  done
  gpus=$(nvidia-smi --query-gpu=index,uuid,name --format=csv,noheader 2>/dev/null | jq -R -s -c 'split("\n") | map(select(length > 0))')
  jq -n --argjson boot "$boot" --argjson units "$units" --argjson gpus "${gpus:-[]}" \
        --arg analyze "$(systemd-analyze 2>/dev/null | head -1)" --arg host "$(hostname)" \
        --arg kernel "$(uname -r)" --argjson at "$(now)" \
    '{collected_at: $at, boot_epoch: $boot, hostname: $host, kernel: $kernel,
      systemd_analyze: $analyze, units: $units, gpus: $gpus,
      clock: "VM epoch s (convert with coldpath.json vm_minus_laptop_s)"}' > "$dir/vm-facts.json"

  {
    kubectl get nodes -o json > "$k/nodes.json"
    kubectl get pods -A -o json > "$k/pods.json"
    kubectl get isvc -A -o json > "$k/isvc.json"
    kubectl get events -A -o json > "$k/events.json"
  } 2>> "$k/errors.txt"
  local ns p c
  while read -r ns p; do
    [ -n "$p" ] || continue
    for c in storage-initializer kserve-container; do
      kubectl logs -n "$ns" "$p" -c "$c" --timestamps > "$k/$p.$c.log" 2>> "$k/errors.txt"
    done
  done < <(jq -r '.items[] | select(.metadata.labels["serving.kserve.io/inferenceservice"]) | "\(.metadata.namespace) \(.metadata.name)"' "$k/pods.json" 2>/dev/null)
  journalctl -b -u k3s -o short-iso-precise --no-pager 2>/dev/null | gzip > "$k/k3s-journal.txt.gz"
  echo "collected"
}

case $cmd in
  probe)   probe ;;
  collect) collect ;;
  *) echo "usage: $0 probe|collect <dir>" >&2; exit 2 ;;
esac
