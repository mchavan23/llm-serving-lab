#!/usr/bin/env bash
# =============================================================================
# session.sh -- start / status / end a paid GPU session, and keep the log that
# the week 6 cost section is written from.
#
#   scripts/session.sh start    # assert running, begin timing
#   scripts/session.sh status   # elapsed + euros so far, live state from API
#   scripts/session.sh end [note]  # POWER OFF, verify it, then write the log row
#
# The guarantee this script exists to provide: a session cannot be closed
# without the Scaleway API confirming the instance is no longer running.
# A wrapper that prints "stopped" without checking is worse than no wrapper.
#
# Credentials are NOT handled here. Run `scw init` yourself once; this script
# only calls the CLI and never reads, prints or stores the key.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_MD="${REPO_ROOT}/docs/session-log.md"
STATE="${REPO_ROOT}/.session-active"          # gitignored; one line, written by `start`
CONF="${REPO_ROOT}/scripts/.session.env"      # gitignored; SERVER_ID / ZONE / VOLUME_GB

# ---- rates: must match benchmarks/cost-model.md -----------------------------
RATE_GPU_HOUR=1.47          # EUR, L40S-1-48G
RATE_BLOCK_GB_HOUR=0.000118 # EUR, Block Storage 5K
RATE_IP_HOUR=0.004          # EUR, flexible IPv4 (bills while powered off)
KILL_EUR=60                 # stop-and-reassess threshold
WARN_EUR=40

say() { printf '\n==> %s\n' "$*"; }
ok()  { printf '    [ok] %s\n' "$*"; }
die() { printf '\n!!! %s\n' "$*" >&2; exit 1; }

# Usage BEFORE the config check: `session.sh` with no args must print help,
# not complain about a missing config file.
case "${1:-}" in
  start|status|end) ;;
  *) sed -n '3,9p' "$0"; exit 2 ;;
esac

[[ -f "$CONF" ]] || die "missing ${CONF}. Create it with:
    SERVER_ID=<uuid from: scw instance server list>
    ZONE=fr-par-2
    VOLUME_GB=150"
# shellcheck disable=SC1090
. "$CONF"
: "${SERVER_ID:?SERVER_ID unset in $CONF}"
: "${ZONE:?ZONE unset in $CONF}"
: "${VOLUME_GB:=150}"

command -v scw >/dev/null || die "scw CLI not found. Install it, then run: scw init"
command -v jq  >/dev/null || die "jq not found"

# ---- helpers ----------------------------------------------------------------
server_state() {
  # "running" | "stopped" | "stopping" | "starting" | "stopped in place"
  scw instance server get "$SERVER_ID" zone="$ZONE" -o json 2>/dev/null | jq -r '.state'
}

eur() { printf '%.2f' "$1"; }

# Sum the EUR column of every completed row already in the log.
project_total() {
  [[ -f "$LOG_MD" ]] || { echo 0; return; }
  awk -F'|' '/^\| [0-9]{4}-/ { gsub(/ /,"",$8); s += $8 } END { printf "%.2f", s+0 }' "$LOG_MD"
}

# ---- commands ---------------------------------------------------------------
cmd_start() {
  [[ -f "$STATE" ]] && die "a session is already open (started $(cut -d' ' -f2 "$STATE")). Run: $0 end"
  local st; st="$(server_state)"
  [[ "$st" == "running" ]] || die "instance is '${st}', not running. Power it on first (scw instance server start ${SERVER_ID} zone=${ZONE})."
  printf '%s %s\n' "$SERVER_ID" "$(date -u +%s)" > "$STATE"
  say "session started $(date -u '+%Y-%m-%d %H:%M:%SZ')  server=${SERVER_ID}"
  ok "project total so far: EUR $(project_total)"
  printf '    METER IS RUNNING at EUR %s/hour. Close with: %s end\n' "$RATE_GPU_HOUR" "$0"
}

cmd_status() {
  local st; st="$(server_state)"
  printf '    instance state : %s\n' "$st"
  if [[ -f "$STATE" ]]; then
    local t0 now hrs cost
    t0="$(cut -d' ' -f2 "$STATE")"; now="$(date -u +%s)"
    hrs="$(awk -v a="$now" -v b="$t0" 'BEGIN{printf "%.3f",(a-b)/3600}')"
    cost="$(awk -v h="$hrs" -v r="$RATE_GPU_HOUR" 'BEGIN{printf "%.2f",h*r}')"
    printf '    open session   : %s h, EUR %s so far\n' "$hrs" "$cost"
  else
    printf '    open session   : none\n'
  fi
  printf '    project total  : EUR %s of %s\n' "$(project_total)" "$KILL_EUR"
}

cmd_end() {
  [[ -f "$STATE" ]] || die "no open session. (Instance state right now: $(server_state))"
  local t0 t1 hrs gpu_cost note
  t0="$(cut -d' ' -f2 "$STATE")"; t1="$(date -u +%s)"
  hrs="$(awk -v a="$t1" -v b="$t0" 'BEGIN{printf "%.2f",(a-b)/3600}')"
  gpu_cost="$(awk -v h="$hrs" -v r="$RATE_GPU_HOUR" 'BEGIN{printf "%.2f",h*r}')"

  say "powering off ${SERVER_ID}"
  scw instance server stop "$SERVER_ID" zone="$ZONE" >/dev/null

  # VERIFY. The whole point of the script. Poll until the API agrees.
  local st=""
  for _ in $(seq 1 60); do
    st="$(server_state)"
    [[ "$st" == "stopped" ]] && break
    sleep 10
  done
  [[ "$st" == "stopped" ]] || die "instance is still '${st}' after 10 minutes -- CHECK THE CONSOLE NOW, the meter may still be running."
  ok "confirmed stopped (compute billing paused; storage and IPv4 continue)"

  # The note is the evidence the week 6 cost section is written from, so it
  # must survive non-interactive callers. Take it from the command line; fall
  # back to prompting ONLY when a human is actually at a terminal. A bare
  # `read` here made every scripted run exit non-zero on a successful close.
  note="$*"
  if [[ -z "$note" && -t 0 ]]; then
    read -r -p "    one line on what this session did: " note || note=""
  fi
  [[ -f "$LOG_MD" ]] || init_log
  printf '| %s | %s | %s | %s | %s | %s | %s | %s | stopped |\n' \
    "$(date -u +%Y-%m-%d)" "${SERVER_ID:0:8}" \
    "$(date -u -d "@$t0" +%H:%M)" "$(date -u -d "@$t1" +%H:%M)" \
    "$hrs" "${note:-(none)}" "$gpu_cost" \
    "$(awk -v a="$(project_total)" -v b="$gpu_cost" 'BEGIN{printf "%.2f",a+b}')" >> "$LOG_MD"
  rm -f "$STATE"

  local total; total="$(project_total)"
  say "session: ${hrs} h, EUR ${gpu_cost}    project total: EUR ${total}"
  awk -v t="$total" -v k="$KILL_EUR" -v w="$WARN_EUR" 'BEGIN{
    if (t+0 >= k) print "\n!!! KILL CRITERION REACHED (EUR " k "). Stop and reassess before the next session.";
    else if (t+0 >= w) print "\n    WARNING: past EUR " w ". Kill criterion is EUR " k ".";
  }'
  printf '    Storage + IPv4 keep billing while stopped: ~EUR %s/day.\n' \
    "$(awk -v g="$VOLUME_GB" -v b="$RATE_BLOCK_GB_HOUR" -v i="$RATE_IP_HOUR" 'BEGIN{printf "%.2f",(g*b+i)*24}')"
}

init_log() {
  mkdir -p "$(dirname "$LOG_MD")"
  cat > "$LOG_MD" <<'EOF'
# GPU session log

Written by `scripts/session.sh`. One row per paid session. `EUR` is compute
only (EUR 1.47/h); storage and the flexible IPv4 accrue continuously and are
accounted separately in `benchmarks/cost-model.md`.

The `left as` column is the evidence for the week 6 idle-cost claim: on
Scaleway, powering off pauses compute billing but NOT storage or IP.

| date | server | start (UTC) | end (UTC) | GPU h | what was done | EUR | running EUR | left as |
|---|---|---|---|---|---|---|---|---|
EOF
}

case "${1:-}" in
  start)  cmd_start ;;
  status) cmd_status ;;
  end)    shift; cmd_end "$@" ;;
  *) sed -n '3,9p' "$0"; exit 2 ;;
esac
