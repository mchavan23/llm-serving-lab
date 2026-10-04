#!/usr/bin/env bash
#
# scripts/teardown-watch.sh - laptop-side auto-teardown for a paid GPU session.
# Week 5 A0. Session 4 idled 77 min after its sweep finished (EUR 1.90; at the
# two-GPU rate it would have been EUR 3.80).
#
#   setsid nohup scripts/teardown-watch.sh --max-hours H [--run RUN_ID] [--poll S] \
#       >/dev/null 2>&1 </dev/null & disown
#   tail -f .teardown-watch.log
#
# Calls `session.sh end` (API power-off, verified) when EITHER:
#   - --run RUN_ID is given and that run's harness is no longer alive on the VM -
#     finished OR crashed. Uses scripts/run-alive.sh (the run's flock), so it works
#     for any harness that takes the lock, with or without a COMPLETE marker; or
#   - --max-hours have passed since this watcher started. The hard ceiling covers
#     what the lock cannot: a hung harness, an orphaned child holding the lock,
#     a lost SSH path.
# Before ending it pulls the run's results to the laptop (best effort, 10 min
# cap). A failed pull loses nothing: results live on the VM's root volume, which
# survives power-off.
#
# Exits quietly if the session is closed by anyone else first. Only one watcher
# runs at a time: starting another replaces it (e.g. re-arm from ceiling-only at
# boot to a specific run later).
#
# Why on the LAPTOP: an OS-level `poweroff` puts a Scaleway Instance in STANDBY,
# which is billed as running (Scaleway docs, checked 2026-10-04). Only the API
# power-off stops compute billing, and the API key lives only on the laptop.
# Consequence: the laptop must stay awake, and WSL running, for the session.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${WATCH_STATE:-$REPO_ROOT/.session-active}"   # written by session.sh start
CONF="$REPO_ROOT/scripts/.session.env"
PIDF="$REPO_ROOT/.teardown-watch.pid"
LOGF="$REPO_ROOT/.teardown-watch.log"
VM_REPO="${WATCH_VM_REPO:-/root/llm-serving-lab}"
DST="${WATCH_RESULTS_DST:-$REPO_ROOT/benchmarks/results}"
# Test seams (unset in real use): WATCH_REMOTE replaces the ssh prefix,
# WATCH_END_CMD replaces `session.sh end`.

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$LOGF"; }
die() { echo "teardown-watch: $*" >&2; log "REFUSED: $*"; exit 2; }

max_h="" run="" poll=60
while [ $# -gt 0 ]; do
  case $1 in
    --max-hours) max_h=${2:-}; shift 2 ;;
    --run)       run=${2:-};   shift 2 ;;
    --poll)      poll=${2:-};  shift 2 ;;
    *) sed -n '2,24p' "$0"; exit 2 ;;
  esac
done
[[ $max_h =~ ^[0-9]+(\.[0-9]+)?$ ]] || die "--max-hours is required (a number)"
[[ $poll  =~ ^[0-9]+$ ]]            || die "--poll must be whole seconds"
[ -f "$STATE" ] || die "no open session ($STATE missing) - run session.sh start first"

# One watcher at a time. kill -0 = "is that pid alive"; the replaced watcher's
# EXIT trap leaves the pidfile alone because it no longer holds our pid.
if [ -f "$PIDF" ]; then
  old=$(cat "$PIDF" 2>/dev/null)
  if [ -n "$old" ] && [ "$old" != $$ ] && kill -0 "$old" 2>/dev/null; then
    kill "$old" && log "replaced watcher pid $old"
  fi
fi
echo $$ > "$PIDF"
trap '[ "$(cat "$PIDF" 2>/dev/null)" = "$$" ] && rm -f "$PIDF"' EXIT

deadline=$(awk -v n="$(date +%s)" -v h="$max_h" 'BEGIN{printf "%d", n + h*3600}')

if [ -z "${WATCH_REMOTE:-}" ]; then
  # shellcheck source=/dev/null
  . "$CONF"
  vm_ip() {
    scw instance server get "$SERVER_ID" zone="$ZONE" -o json 2>/dev/null \
      | jq -r '((.public_ips // [])[0].address) // .public_ip.address // empty'
  }
fi
IP=""
# Every remote call is time-boxed: ConnectTimeout only bounds the connect, and a
# hung ssh would otherwise freeze the loop and with it the ceiling check.
# REMOTE_TIMEOUT=0 would disable it; the pull raises it to 600.
remote() {
  local t=${REMOTE_TIMEOUT:-60}
  if [ -n "${WATCH_REMOTE:-}" ]; then timeout "$t" $WATCH_REMOTE "$1"; return; fi
  [ -n "$IP" ] || IP=$(vm_ip)
  [ -n "$IP" ] || { echo "no public IP from the Scaleway API"; return 255; }
  timeout "$t" ssh -i ~/.ssh/id_ed25519 -o BatchMode=yes -o ConnectTimeout=10 \
      -o StrictHostKeyChecking=accept-new "root@$IP" "$1"
}

pull_results() {
  mkdir -p "$DST"
  if REMOTE_TIMEOUT=600 remote "tar -C '$VM_REPO/benchmarks/results' -cf - '$run'" | tar -C "$DST" -xf -; then
    log "pulled $run -> $DST/$run"
  else
    log "pull of $run FAILED or timed out - results remain on the VM root volume"
  fi
}

end_session() {
  local why=$1 try rc
  log "TEARDOWN: $why"
  for try in 1 2 3; do
    [ -f "$STATE" ] || { log "session already closed"; exit 0; }
    if [ -n "${WATCH_END_CMD:-}" ]; then $WATCH_END_CMD "watcher: $why" >> "$LOGF" 2>&1
    else "$REPO_ROOT/scripts/session.sh" end "watcher: $why" >> "$LOGF" 2>&1; fi
    rc=$?
    [ $rc -eq 0 ] && { log "session.sh end OK"; exit 0; }
    log "session.sh end FAILED (rc $rc, attempt $try/3) - CHECK THE CONSOLE"
    sleep 60
  done
  log "GAVE UP after 3 attempts. THE INSTANCE MAY STILL BE BILLING. Power it off in the console."
  exit 1
}

log "armed: max ${max_h} h (deadline $(date -u -d "@$deadline" +%H:%MZ)), run=${run:-none (ceiling only)}, poll ${poll}s, pid $$"
fails=0
while :; do
  [ -f "$STATE" ] || { log "session closed elsewhere; watcher exits"; exit 0; }
  [ "$(date +%s)" -ge "$deadline" ] && end_session "max ${max_h} h reached"
  if [ -n "$run" ]; then
    out=$(remote "cd '$VM_REPO' && scripts/run-alive.sh 'benchmarks/results/$run'" 2>&1); rc=$?
    case $rc in
      0) [ $fails -gt 0 ] && log "poll recovered after $fails failure(s)"; fails=0 ;;
      1) # -w: whole word, so INCOMPLETE does not count as COMPLETE.
         status=$(remote "grep -hwE 'COMPLETE|INCOMPLETE' '$VM_REPO/benchmarks/results/$run'/*.log 2>/dev/null | tail -1")
         log "run $run: harness STOPPED; last status line: ${status:-none}"
         pull_results
         case $status in
           *INCOMPLETE*) end_session "run $run stopped INCOMPLETE" ;;
           *COMPLETE*)   end_session "run $run COMPLETE" ;;
           *)            end_session "run $run stopped (no COMPLETE marker)" ;;
         esac ;;
      2) log "run $run has no .lock yet (not started, or wrong RUN_ID?) - waiting" ;;
      *) fails=$((fails + 1)); IP=""; log "poll failed (rc $rc, $fails in a row): $(tail -1 <<<"$out")" ;;
    esac
  fi
  sleep "$poll"
done
