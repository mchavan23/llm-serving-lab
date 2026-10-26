#!/usr/bin/env bash
#
# scripts/coldpath.sh - boot the stopped GPU VM and time the cold path to the
# first token. Week 5 A5. Design: NOTES "Week 5 A5 design" + "A5 correction".
#
#   scripts/coldpath.sh --keep --label <name> [--watch-hours H]   (default H 3.5)
#   scripts/coldpath.sh --end  --label <name> [--watch-hours H]   (default H 0.75)
#
#   --keep  session 5's first boot: measure, then leave the session OPEN for the
#           rest of session 5 (the ceiling watcher stays armed).
#   --end   a restart boot: measure, then `session.sh end` (API power-off,
#           verified), the stop timed to the API's "stopped".
#
# EVERY BOOT IS ITS OWN SESSION: the VM is never stopped inside an open session,
# so session.sh and teardown-watch.sh keep their proven semantics.
#
# Laptop side (this script, laptop clock): scw start -> API "running" (2 s polls)
# -> session.sh start -> ceiling watcher -> SSH up (2 s polls) -> clock offset
# -> ship scripts/coldpath-vm.sh and start its prober detached on the VM ->
# wait for PROBE_DONE -> `coldpath-vm.sh collect` (the VM's own timestamps:
# kernel, systemd, Kubernetes) -> pull -> clock offset again -> [--end: stop].
# Results: benchmarks/results/coldpath-<label>-<UTC>/ (laptop-events.jsonl,
# coldpath.json, vm/ = what the VM side wrote).
#
# Safety, whatever ends the script: --end always ends the session it opened; a VM
# started but never given a session is powered off here (nothing else would).
# --keep never ends the session: you are there and the watcher is armed.
# Exit: 0 measured | 1 a step failed (see coldpath.json "status") | 2 refused.
#
# Test seams (unset in real use): COLD_SCW replaces `scw`, COLD_REMOTE the ssh
# prefix, COLD_SESSION session.sh, COLD_WATCH the watcher launch, COLD_STATE the
# session state file, COLD_VM_ROOT the VM directory, COLD_VM_SCRIPT the VM-side
# script; COLD_*_TIMEOUT_S / COLD_POLL_S shorten waits.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2
CONF="$REPO_ROOT/scripts/.session.env"
STATE="${COLD_STATE:-$REPO_ROOT/.session-active}"
SESSION="${COLD_SESSION:-$REPO_ROOT/scripts/session.sh}"
VM_SCRIPT="${COLD_VM_SCRIPT:-$REPO_ROOT/scripts/coldpath-vm.sh}"
VM_ROOT="${COLD_VM_ROOT:-/root/coldpath}"
POLL_S=${COLD_POLL_S:-2}
RUNNING_TIMEOUT_S=${COLD_RUNNING_TIMEOUT_S:-900}
SSH_TIMEOUT_S=${COLD_SSH_TIMEOUT_S:-600}
PROBE_WAIT_S=${COLD_PROBE_WAIT_S:-1800}   # the prober gives up at 1500 s by itself
STOP_TIMEOUT_S=${COLD_STOP_TIMEOUT_S:-700}

LOG=/dev/null
log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$LOG" >&2; }
refuse() { log "REFUSED: $*"; exit 2; }

MODE="" LABEL="" WATCH_H=""
while [ $# -gt 0 ]; do
  case $1 in
    --keep|--end)  MODE=${1#--}; shift ;;
    --label)       LABEL=${2:-}; shift 2 ;;
    --watch-hours) WATCH_H=${2:-}; shift 2 ;;
    *) sed -n '5,10p' "$0"; exit 2 ;;
  esac
done
[ -n "$MODE" ] || { sed -n '5,10p' "$0"; exit 2; }
[[ $LABEL =~ ^[a-z0-9][a-z0-9-]*$ ]] || refuse "--label: lowercase letters, digits, dashes"
[ -n "$WATCH_H" ] || { [ "$MODE" = keep ] && WATCH_H=3.5 || WATCH_H=0.75; }
[[ $WATCH_H =~ ^[0-9]+(\.[0-9]+)?$ ]] || refuse "--watch-hours must be a number"

[ -f "$CONF" ] || refuse "missing $CONF"
# shellcheck source=/dev/null
. "$CONF"
: "${SERVER_ID:?SERVER_ID unset in $CONF}" "${ZONE:?ZONE unset in $CONF}"
[ -f "$VM_SCRIPT" ] || refuse "missing $VM_SCRIPT"
if [ -n "${COLD_SCW:-}" ]; then SCW=$COLD_SCW; else SCW=scw; fi

RUN_ID="coldpath-$LABEL-$(date -u +%Y%m%dT%H%MZ)"
RESULTS="$REPO_ROOT/benchmarks/results/$RUN_ID"
VM_DIR="$VM_ROOT/$RUN_ID"
EV="$RESULTS/laptop-events.jsonl"

now() { date +%s.%N; }
event() {   # event <name> <epoch> [extra json fields] - one line, laptop clock
  printf '{"event":"%s","t":%s%s}\n' "$1" "$2" "${3:+,$3}" >> "$EV"
  log "  $1${3:+ ($3)}"
}
server_json() { $SCW instance server get "$SERVER_ID" zone="$ZONE" -o json 2>/dev/null; }
state() { server_json | jq -r '.state // empty'; }

IP=""
remote() {   # remote <command> [<stdin]; time-boxed like the watcher's
  local t=${REMOTE_TIMEOUT:-60}
  # shellcheck disable=SC2086  # test seam: a command with arguments, split on purpose
  if [ -n "${COLD_REMOTE:-}" ]; then timeout "$t" $COLD_REMOTE "$1"; return; fi
  timeout "$t" ssh -i ~/.ssh/id_ed25519 -o BatchMode=yes -o ConnectTimeout=3 \
      -o StrictHostKeyChecking=accept-new "root@$IP" "$1"
}

offset() {   # offset <event>: VM clock minus laptop clock, best of 5 by round trip
  local a v b best="" line
  for _ in 1 2 3 4 5; do
    a=$(now); v=$(REMOTE_TIMEOUT=10 remote 'date +%s.%N') || continue; b=$(now)
    line=$(awk -v a="$a" -v v="$v" -v b="$b" 'BEGIN {printf "%.4f %.4f", b - a, v - (a + b) / 2}')
    if [ -z "$best" ] || awk -v x="${line% *}" -v y="${best% *}" 'BEGIN {exit !(x < y)}'; then best=$line; fi
  done
  [ -n "$best" ] || { log "  WARN: clock offset not measured"; return 1; }
  event "$1" "$(now)" "\"rtt_s\":${best% *},\"vm_minus_laptop_s\":${best#* }"
}

# ------------------------------------------------------------ preconditions ---
[ -f "$STATE" ] && refuse "a session is already open ($STATE) - this script opens its own"
st0=$(state)
[ "$st0" = stopped ] || refuse "instance is '${st0:-unknown}', not stopped"
ctype=$(server_json | jq -r '.commercial_type // "unknown"')
mkdir -p "$RESULTS" || exit 2
LOG="$RESULTS/coldpath.log"
log "cold path $RUN_ID: mode $MODE, $ctype, watcher ceiling $WATCH_H h"

# STATUS stays "failed:incomplete" unless the script reaches its end: an
# unexpected exit can never read as success.
STARTED=0 OPENED=0 STATUS="failed:incomplete" PROBE_FAIL=""
# shellcheck disable=SC2317  # runs from the EXIT trap, which shellcheck cannot follow
finish() {
  local rc=$?
  trap - EXIT INT TERM
  if [ "$MODE" = end ] && [ "$OPENED" = 1 ] && [ -f "$STATE" ]; then
    stop_session
  elif [ "$STARTED" = 1 ] && [ "$OPENED" = 0 ]; then
    # Started but no session: no watcher can see it, so stop it here.
    log "VM started without a session - powering it off via the API"
    $SCW instance server stop "$SERVER_ID" zone="$ZONE" >> "$LOG" 2>&1
    local s=""
    for _ in $(seq 1 $((STOP_TIMEOUT_S / 10))); do s=$(state); [ "$s" = stopped ] && break; sleep 10; done
    if [ "$s" = stopped ]; then log "confirmed stopped"
    else log "!!! instance is '$s' - CHECK THE CONSOLE NOW, it may be billing"; fi
  elif [ "$MODE" = keep ] && [ "$OPENED" = 1 ]; then
    log "session LEFT OPEN (--keep); the ceiling watcher is armed. End with: scripts/session.sh end"
  fi
  jq -s --arg run "$RUN_ID" --arg mode "$MODE" --arg label "$LABEL" --arg ctype "$ctype" \
        --arg status "$STATUS" --arg vmdir "$VM_DIR" \
    '{run:$run, mode:$mode, label:$label, commercial_type:$ctype, status:$status, vm_dir:$vmdir,
      clock:"laptop epoch s; VM-side times are converted with vm_minus_laptop_s",
      events: .}' "$EV" > "$RESULTS/coldpath.json" 2>/dev/null
  log "status: $STATUS -> $RESULTS"
  [ "$STATUS" = ok ] && exit 0
  exit $((rc == 2 ? 2 : 1))
}
trap finish EXIT
trap 'STATUS="failed:interrupted"; exit 1' INT TERM

# shellcheck disable=SC2317  # called from finish (EXIT trap)
stop_session() {   # session.sh end, with our own 2 s poll for "stopped"
  local t mark="$RESULTS/.stopped-at"
  t=$(now); event stop_command "$t"
  ( end=$(( $(date +%s) + STOP_TIMEOUT_S ))
    while [ "$(date +%s)" -lt "$end" ]; do
      [ "$(state)" = stopped ] && { now > "$mark"; exit 0; }
      sleep "$POLL_S"; done ) &
  local pp=$!
  if "$SESSION" end "coldpath $RUN_ID ($LABEL)" >> "$LOG" 2>&1; then
    log "  session.sh end OK"
  else
    log "!!! session.sh end FAILED - CHECK THE CONSOLE"; STATUS="failed:end"
  fi
  wait "$pp"
  if [ -s "$mark" ]; then event api_stopped "$(cat "$mark")"; rm -f "$mark"
  else log "  WARN: 'stopped' not seen by the 2 s poll"; fi
}

# --------------------------------------------------------------------- boot ---
t=$(now); event start_command "$t" "\"commercial_type\":\"$ctype\""
$SCW instance server start "$SERVER_ID" zone="$ZONE" >> "$LOG" 2>&1 \
  || { STATUS="failed:scw start"; exit 1; }
STARTED=1
event start_command_returned "$(now)"

last="" deadline=$(( $(date +%s) + RUNNING_TIMEOUT_S ))
while :; do
  s=$(state); t=$(now)
  [ "$s" != "$last" ] && { event "api_state" "$t" "\"state\":\"$s\""; last=$s; }
  [ "$s" = running ] && break
  [ "$(date +%s)" -ge "$deadline" ] && { STATUS="failed:not running after ${RUNNING_TIMEOUT_S}s"; exit 1; }
  sleep "$POLL_S"
done

# Meter and safety net before anything else: if the laptop dies from here on,
# the watcher still ends the session at the ceiling.
"$SESSION" start >> "$LOG" 2>&1 || { STATUS="failed:session.sh start"; exit 1; }
[ -f "$STATE" ] || { STATUS="failed:session.sh start wrote no state"; exit 1; }
OPENED=1
event session_started "$(now)"
if [ -n "${COLD_WATCH:-}" ]; then $COLD_WATCH --max-hours "$WATCH_H" >> "$LOG" 2>&1
else
  setsid nohup "$REPO_ROOT/scripts/teardown-watch.sh" --max-hours "$WATCH_H" >/dev/null 2>&1 </dev/null &
  disown
  sleep 2
  if ! { [ -s "$REPO_ROOT/.teardown-watch.pid" ] && kill -0 "$(cat "$REPO_ROOT/.teardown-watch.pid")" 2>/dev/null; }; then
    STATUS="failed:watcher did not start"; exit 1
  fi
fi
event watcher_armed "$(now)" "\"max_hours\":$WATCH_H"

# ---------------------------------------------------------------------- ssh ---
if [ -z "${COLD_REMOTE:-}" ]; then
  IP=$(server_json | jq -r '((.public_ips // [])[0].address) // .public_ip.address // empty')
  [ -n "$IP" ] || { STATUS="failed:no public IP"; exit 1; }
fi
tries=0 deadline=$(( $(date +%s) + SSH_TIMEOUT_S ))
while :; do
  tries=$((tries + 1)); t=$(now)
  REMOTE_TIMEOUT=8 remote true >/dev/null 2>&1 && break
  [ "$(date +%s)" -ge "$deadline" ] && { STATUS="failed:no SSH after ${SSH_TIMEOUT_S}s"; exit 1; }
  sleep "$POLL_S"
done
# Polling starts only after session.sh start; if the FIRST try succeeds, SSH was
# up earlier and this time is an upper bound.
event ssh_up "$t" "\"attempts\":$tries,\"upper_bound\":$([ "$tries" = 1 ] && echo true || echo false)"
offset clock_offset_start

# ---------------------------------------------------------- prober on the VM ---
remote "mkdir -p '$VM_DIR' && cat > '$VM_DIR/coldpath-vm.sh'" < "$VM_SCRIPT" \
  || { STATUS="failed:ship coldpath-vm.sh"; exit 1; }
# setsid -f: fork and return at once. The old `setsid nohup ... &` left the
# `bash -c` subshell holding ssh's stdout, so ssh waited out REMOTE_TIMEOUT and
# the launch was reported failed while the prober ran (session 5, 2026-10-26).
remote "cd '$VM_DIR' && setsid -f nohup bash coldpath-vm.sh probe '$VM_DIR' > probe.out 2>&1 < /dev/null" \
  || { STATUS="failed:start prober"; exit 1; }
event probe_launched "$(now)"

deadline=$(( $(date +%s) + PROBE_WAIT_S )) next=0
while :; do
  done_line=$(REMOTE_TIMEOUT=15 remote "cat '$VM_DIR/PROBE_DONE' 2>/dev/null")
  [ -n "$done_line" ] && break
  if [ "$(date +%s)" -ge "$next" ]; then
    log "  waiting for first token: $(REMOTE_TIMEOUT=15 remote "tail -1 '$VM_DIR/probe.jsonl' 2>/dev/null" | cut -c1-120)"
    next=$(( $(date +%s) + 60 ))
  fi
  # Still collect and pull: what the VM recorded explains why.
  [ "$(date +%s)" -ge "$deadline" ] && { PROBE_FAIL="failed:prober not done after ${PROBE_WAIT_S}s"; break; }
  sleep 10
done
event probe_done_seen "$(now)" "\"probe_status\":\"${done_line:-none}\""

# ------------------------------------------------------------ collect, pull ---
REMOTE_TIMEOUT=300 remote "cd '$VM_DIR' && bash coldpath-vm.sh collect '$VM_DIR' > collect.out 2>&1" \
  || log "  WARN: collect reported an error (see vm/collect.out)"
mkdir -p "$RESULTS/vm"
if REMOTE_TIMEOUT=300 remote "tar -C '$VM_ROOT' -cf - '$RUN_ID'" | tar -C "$RESULTS/vm" --strip-components=1 -xf -; then
  event pulled "$(now)"
else
  STATUS="failed:pull"; exit 1
fi
offset clock_offset_end
STATUS=${PROBE_FAIL:-ok}
[ "$STATUS" = ok ] || exit 1
exit 0
