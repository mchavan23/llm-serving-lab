#!/usr/bin/env bash
# gpu-stock-watch.sh - poll Scaleway GPU stock; raise a loud, on-top Windows alert
# when a wanted type is no longer in `shortage`.
#
# Free: `server-type list` is a read-only API call; only running instances bill.
# It ALERTS ONLY - it never starts the instance (starting = billing, a human call).
# "available" is not a reservation: act fast, it can vanish again.
#
# Usage: gpu-stock-watch.sh start | stop | status | test-alert | run
# Env:   ZONE (fr-par-2)  TYPES ("L40S-2-48G", space-separated)
#        INTERVAL (180 s) REALERT (900 s, repeat while still in stock)
# Dies with WSL/Windows shutdown or sleep: re-run `start` after a reboot.
set -u
ZONE="${ZONE:-fr-par-2}"
TYPES="${TYPES:-L40S-2-48G}"
INTERVAL="${INTERVAL:-180}"
REALERT="${REALERT:-900}"
MAXFAIL=5
DIR="${HOME}/.gpu-stock-watch"
LOG="$DIR/stock.log"; LOCK="$DIR/.lock"; PIDF="$DIR/pid"
PS=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe
SELF="$(readlink -f "$0")"
mkdir -p "$DIR"

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Topmost modal box + looping alarm until OK is clicked. Blocks until then.
alert() {
  local msg="${1//\'/}"   # strip single quotes (PowerShell string below)
  local ps="Add-Type -AssemblyName System.Windows.Forms
\$p = New-Object System.Media.SoundPlayer 'C:\\Windows\\Media\\Alarm01.wav'
try { \$p.PlayLooping() } catch { [System.Media.SystemSounds]::Exclamation.Play() }
[void][System.Windows.Forms.MessageBox]::Show('${msg}', 'GPU STOCK WATCH', 'OK', 'Warning', 'Button1', 'DefaultDesktopOnly')
\$p.Stop()"
  local enc; enc="$(printf '%s' "$ps" | iconv -t UTF-16LE | base64 -w0)"
  "$PS" -NoProfile -STA -EncodedCommand "$enc" >/dev/null 2>>"$DIR/err.log"
  echo "$(ts) alert acknowledged" >>"$LOG"
}

poll() {  # prints "name=availability ..." for GPU types, or fails
  scw instance server-type list zone="$ZONE" -o json 2>>"$DIR/err.log" \
  | jq -er '[.[] | select((.gpu // 0) > 0) | "\(.name)=\(.availability)"] | join(" ")'
}

run() {
  exec 9>"$LOCK"
  flock -n 9 || { echo "already running"; exit 1; }
  echo $$ >"$PIDF"
  echo "$(ts) START zone=$ZONE types=[$TYPES] every ${INTERVAL}s" >>"$LOG"
  local fails=0 last_alert=0 line hit t st now
  while :; do
    if line="$(poll)" && [ -n "$line" ]; then
      fails=0; hit=""
      for t in $TYPES; do
        st="$(tr ' ' '\n' <<<"$line" | awk -F= -v t="$t" '$1==t{print $2}')"
        [ -n "$st" ] && [ "$st" != "shortage" ] && hit+="$t=$st "
      done
      echo "$(ts) ${hit:+HIT[$hit] }$line" >>"$LOG"
      now=$(date +%s)
      if [ -n "$hit" ] && [ $((now - last_alert)) -ge "$REALERT" ]; then
        last_alert=$now
        alert "GPU stock in $ZONE: ${hit}- NOT a reservation, it can vanish. The instance is NOT started. Click OK to stop the alarm (repeats every $((REALERT/60)) min while stock lasts)."
      fi
    else
      fails=$((fails + 1))
      echo "$(ts) API-ERROR ($fails in a row; see err.log)" >>"$LOG"
      if [ "$fails" -eq "$MAXFAIL" ]; then
        alert "GPU stock watch: Scaleway API failed $MAXFAIL times in a row. The watcher is still running but BLIND. Check ~/.gpu-stock-watch/err.log (scw credentials?)."
      fi
    fi
    sleep "$INTERVAL"
  done
}

case "${1:-}" in
  run)        run ;;
  start)      setsid nohup "$SELF" run >>"$DIR/nohup.out" 2>&1 </dev/null &
              sleep 2; "$SELF" status ;;
  stop)       if [ -s "$PIDF" ] && kill "$(cat "$PIDF")" 2>/dev/null; then
                echo "$(ts) STOP" >>"$LOG"; rm -f "$PIDF"; echo stopped
              else echo "not running"; fi ;;
  status)     if [ -e "$LOCK" ] && ! flock -n "$LOCK" true; then
                echo "RUNNING (pid $(cat "$PIDF" 2>/dev/null))"
              else echo "NOT running"; fi
              tail -n 3 "$LOG" 2>/dev/null ;;
  test-alert) alert "TEST - GPU stock watch can reach this screen. Click OK." ;;
  *)          sed -n '2,13p' "$SELF"; exit 2 ;;
esac
