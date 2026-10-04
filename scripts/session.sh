#!/usr/bin/env bash
# =============================================================================
# session.sh -- start / status / end a paid GPU session, and keep the log that
# the week 6 cost section is written from.
#
#   scripts/session.sh start    # assert running, begin timing
#   scripts/session.sh status   # elapsed + euros so far, live state from API
#   scripts/session.sh end [note]  # POWER OFF, verify it, then write the log row
#   scripts/session.sh ssh-rule    # point the port-22 rule at this machine's current IP
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
# Block Storage and IPv4 are the RECONCILED rates (billing API, 2026-09-27),
# not the list prices: ~10% and 25% higher respectively.
# Compute rate: NOT a constant. Looked up from the API at every `start` for the
# instance's CURRENT commercial type (week 5 moved L40S-1-48G 1.47 -> L40S-2-48G
# 2.94; a constant would have halved every cost line and the kill check).
# RATE_GPU_HOUR in .session.env is only a fallback if the lookup fails.
RATE_BLOCK_GB_HOUR=0.00013  # EUR, Block Storage 5K (list: 0.000118)
RATE_IP_HOUR=0.005          # EUR, flexible IPv4, bills while powered off (list: 0.004)
PROJECT_START_MONTH=2026-09 # first billing period with any spend
KILL_EUR=60                 # stop-and-reassess threshold
WARN_EUR=40

say() { printf '\n==> %s\n' "$*"; }
ok()  { printf '    [ok] %s\n' "$*"; }
die() { printf '\n!!! %s\n' "$*" >&2; exit 1; }

# Usage BEFORE the config check: `session.sh` with no args must print help,
# not complain about a missing config file.
case "${1:-}" in
  start|status|end|ssh-rule) ;;
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

# "<commercial_type> <EUR per hour>" for this instance, from the API. Works
# whether the instance is running or stopped.
compute_rate() {
  local t
  t="$(scw instance server get "$SERVER_ID" zone="$ZONE" -o json 2>/dev/null | jq -r '.commercial_type // empty')"
  [[ -n "$t" ]] || return 1
  scw instance server-type list zone="$ZONE" -o json 2>/dev/null \
    | jq -r --arg t "$t" '.[] | select(.name == $t)
        | "\(.name) \(((.hourly_price.units + .hourly_price.nanos / 1e9) * 100000 | round) / 100000)"' \
    | grep .
}

# Rate for the open session: from the state file, else the API now, else the
# .session.env fallback. Prints "<type> <rate>" or fails.
session_rate() {
  local t r
  t="$(cut -d' ' -f4 "$STATE" 2>/dev/null)"; r="$(cut -d' ' -f5 "$STATE" 2>/dev/null)"
  if [[ "$r" =~ ^[0-9.]+$ ]]; then echo "$t $r"; return 0; fi
  compute_rate && return 0
  [[ -n "${RATE_GPU_HOUR:-}" ]] && { echo "unknown-type ${RATE_GPU_HOUR}"; return 0; }
  return 1
}

# Sum the EUR column of every completed row already in the log.
# COMPUTE ONLY - it feeds the log's own `running EUR` column. Never use it for
# the kill criterion: storage + IPv4 are about half the real bill.
log_compute_total() {
  [[ -f "$LOG_MD" ]] || { echo 0; return; }
  awk -F'|' '/^\| [0-9]{4}-/ { gsub(/ /,"",$8); s += $8 } END { printf "%.2f", s+0 }' "$LOG_MD"
}

# The TRUE project spend, from the Scaleway billing API: every billing period
# from PROJECT_START_MONTH to now, filtered to this instance's project.
# Prints a number on success. On ANY doubt it prints nothing and returns 1 -
# a wrong-but-plausible number is worse than none for a kill criterion.
billed_total() {
  local pid m now json n total=0 part
  pid="$(scw instance server get "$SERVER_ID" zone="$ZONE" -o json | jq -r '.project')" || return 1
  [[ "$pid" =~ ^[0-9a-f-]{36}$ ]] || { echo "billing: could not read project id" >&2; return 1; }
  m="$PROJECT_START_MONTH"; now="$(date -u +%Y-%m)"
  while [[ ! "$m" > "$now" ]]; do
    json="$(scw billing consumption list billing-period="$m" project-id="$pid" -o json)" \
      || { echo "billing: API call failed for $m" >&2; return 1; }
    n="$(jq 'length' <<<"$json")"
    if (( n == 0 )); then
      # Storage bills every hour the volume exists, so a closed month cannot
      # be empty. The current month can be, for a few hours after it opens.
      if [[ "$m" == "$now" ]]; then
        echo "billing: $m has no entries yet (billing lag at month start)" >&2
      else
        echo "billing: CLOSED month $m returned nothing - refusing to under-count" >&2
        return 1
      fi
    fi
    # Each amount is whole euros + billionths: units + nanos/1e9.
    part="$(jq '[.[] | .value.units + .value.nanos/1e9] | add // 0' <<<"$json")"
    total="$(awk -v a="$total" -v b="$part" 'BEGIN{printf "%.2f",a+b}')"
    m="$(date -u -d "${m}-01 +1 month" +%Y-%m)"
  done
  printf '%s' "$total"
}

# ---- commands ---------------------------------------------------------------
# The security group allows SSH from exactly one /32. A home broadband address
# moves between sessions, and discovering that on a machine already billing at
# a GPU rate is the expensive way to find out. Runs before every start; also
# callable on its own. Fails OPEN (leaves the rule alone) rather than guessing.
sync_ssh_rule() {
  if [[ -z "${SG_ID:-}" ]]; then
    printf '    [warn] SG_ID not set in .session.env - skipping the SSH rule check\n'
    return 0
  fi
  local myip rules rule cur
  myip="$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  if [[ ! "$myip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    printf '    [warn] could not determine this machine public IP - SSH rule left untouched\n'
    return 0
  fi
  rules="$(scw instance security-group list-rules security-group-id="$SG_ID" zone="$ZONE" -o json 2>/dev/null)"
  rule="$(printf '%s' "$rules" | jq -r '[.[] | select(.direction=="inbound" and .protocol=="TCP" and .dest_port_from==22)][0].id // empty')"
  if [[ -z "$rule" ]]; then
    printf '    [warn] no inbound TCP/22 rule in %s - left untouched\n' "$SG_ID"
    return 0
  fi
  cur="$(printf '%s' "$rules" | jq -r --arg id "$rule" '.[] | select(.id==$id) | .ip_range')"
  if [[ "$cur" == "${myip}/32" ]]; then
    ok "ssh rule already matches this machine (${myip}/32)"
    return 0
  fi
  scw instance security-group update-rule security-group-id="$SG_ID" \
      security-group-rule-id="$rule" ip-range="${myip}/32" zone="$ZONE" >/dev/null \
    || die "could not update the SSH rule (was ${cur}); fix it BEFORE powering on"
  ok "ssh rule moved ${cur} -> ${myip}/32"
}

cmd_start() {
  [[ -f "$STATE" ]] && die "a session is already open (started $(cut -d' ' -f2 "$STATE")). Run: $0 end"
  sync_ssh_rule
  local st; st="$(server_state)"
  [[ "$st" == "running" ]] || die "instance is '${st}', not running. Power it on first (scw instance server start ${SERVER_ID} zone=${ZONE})."
  local t0 b0 tr ctype rate; t0="$(date -u +%s)"
  # Rate of the CURRENT type. Never die here: the instance is already running,
  # and a session that is not recorded cannot be closed by `end` or the watcher.
  if tr="$(compute_rate)"; then read -r ctype rate <<<"$tr"
  elif [[ -n "${RATE_GPU_HOUR:-}" ]]; then ctype=unknown-type rate=$RATE_GPU_HOUR
    printf '    [warn] rate lookup failed - using RATE_GPU_HOUR=%s from .session.env\n' "$rate"
  else ctype=unknown-type rate=unknown
    printf '    [WARN] rate lookup failed and no RATE_GPU_HOUR fallback - costs will read UNKNOWN\n'
  fi
  # Billed total at start = the baseline `end` uses to tell whether the billing
  # API has already counted this session (recipe fix 5, NOTES 2026-10-04).
  b0="$(billed_total)" || b0=unknown
  printf '%s %s %s %s %s\n' "$SERVER_ID" "$t0" "$b0" "$ctype" "$rate" > "$STATE"
  say "session started $(date -u -d "@$t0" '+%Y-%m-%d %H:%M:%SZ')  server=${SERVER_ID}"
  ok "project total so far (billed): EUR ${b0/unknown/UNKNOWN - check the console}"
  printf '    METER IS RUNNING: %s at EUR %s/hour. Close with: %s end\n' "$ctype" "$rate" "$0"
}

cmd_status() {
  local st; st="$(server_state)"
  printf '    instance state : %s\n' "$st"
  if [[ -f "$STATE" ]]; then
    local t0 now hrs cost tr ctype rate
    t0="$(cut -d' ' -f2 "$STATE")"; now="$(date -u +%s)"
    hrs="$(awk -v a="$now" -v b="$t0" 'BEGIN{printf "%.3f",(a-b)/3600}')"
    if tr="$(session_rate)"; then read -r ctype rate <<<"$tr"
      cost="$(awk -v h="$hrs" -v r="$rate" 'BEGIN{printf "%.2f",h*r}')"
    else ctype=unknown-type rate=? cost=UNKNOWN; fi
    printf '    open session   : %s h, EUR %s so far (%s at %s/h)\n' "$hrs" "$cost" "$ctype" "$rate"
  else
    printf '    open session   : none\n'
  fi
  printf '    project total  : EUR %s of %s (billed)\n' "$(billed_total || echo 'UNKNOWN')" "$KILL_EUR"
}

cmd_end() {
  [[ -f "$STATE" ]] || die "no open session. (Instance state right now: $(server_state))"
  local t0 t1 hrs gpu_cost note tr ctype rate
  t0="$(cut -d' ' -f2 "$STATE")"; t1="$(date -u +%s)"
  local b0; b0="$(cut -d' ' -f3 "$STATE")"; [[ -n "$b0" ]] || b0=unknown   # pre-fix state files have 2 fields
  hrs="$(awk -v a="$t1" -v b="$t0" 'BEGIN{printf "%.2f",(a-b)/3600}')"
  if tr="$(session_rate)"; then read -r ctype rate <<<"$tr"
  else ctype=unknown-type rate=0
    printf '    [WARN] compute rate unknown - session cost below reads 0. CHECK THE CONSOLE.\n'
  fi
  gpu_cost="$(awk -v h="$hrs" -v r="$rate" 'BEGIN{printf "%.2f",h*r}')"

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
    "$hrs" "${note:-(none)} [${ctype} @ ${rate}/h]" "$gpu_cost" \
    "$(awk -v a="$(log_compute_total)" -v b="$gpu_cost" 'BEGIN{printf "%.2f",a+b}')" >> "$LOG_MD"
  rm -f "$STATE"

  # Kill check on the BILLED total plus this session's compute. Billing lags, so
  # the session just closed may or may not be in it yet: adding it can only
  # over-count, which is the safe direction for a stop threshold.
  local billed total
  if ! billed="$(billed_total)"; then
    say "session: ${hrs} h, EUR ${gpu_cost}"
    printf '\n!!! Could not read the billing API. Check spend in the console before the next session.\n'
    return 0
  fi
  local basis
  read -r total basis < <(billing_basis "$hrs" "$gpu_cost" "$b0" "$billed")
  say "session: ${hrs} h, EUR ${gpu_cost}    project total: EUR ${total}"
  printf '    %s\n' "$basis"
  awk -v t="$total" -v k="$KILL_EUR" -v w="$WARN_EUR" 'BEGIN{
    if (t+0 >= k) print "\n!!! KILL CRITERION REACHED (EUR " k "). Stop and reassess before the next session.";
    else if (t+0 >= w) print "\n    WARNING: past EUR " w ". Kill criterion is EUR " k ".";
  }'
  printf '    Storage + IPv4 keep billing while stopped: ~EUR %s/day.\n' \
    "$(awk -v g="$VOLUME_GB" -v b="$RATE_BLOCK_GB_HOUR" -v i="$RATE_IP_HOUR" 'BEGIN{printf "%.2f",(g*b+i)*24}')"
}

# billing_basis HRS GPU_COST BILLED_AT_START BILLED_NOW
#   -> "<project total> <one-line explanation>"
# Session 4 printed EUR 26.57 against a true ~19: it always added this session's
# compute to the billed total, but by the time `end` ran the billing API had
# already counted most of it. Growth of the billed total since `start`, minus the
# storage + IPv4 that accrue anyway, is compute the API has already seen; only
# the remainder is added. Charges of any other kind during the session would be
# mistaken for compute and make the total slightly LOW - acceptable here, and
# the line says which case applied so the console can be checked.
billing_basis() {
  local hrs=$1 gpu=$2 b0=$3 now=$4
  if [[ "$b0" == unknown ]]; then
    awk -v n="$now" -v g="$gpu" 'BEGIN{printf "%.2f basis: billed %.2f + this session %.2f. No start baseline, so if the API already counts part of this session it is DOUBLE-COUNTED here (upper bound).\n", n+g, n, g}'
    return
  fi
  awk -v h="$hrs" -v g="$gpu" -v s="$b0" -v n="$now" \
      -v vol="$VOLUME_GB" -v rb="$RATE_BLOCK_GB_HOUR" -v ri="$RATE_IP_HOUR" 'BEGIN{
    other = h * (vol*rb + ri)                 # storage + IPv4 during the session
    seen  = (n - s) - other; if (seen < 0) seen = 0; if (seen > g) seen = g
    add   = g - seen
    if (add < 0.005)      why = sprintf("billing API already includes this session (+%.2f since start); nothing added", n - s)
    else if (seen < 0.005) why = sprintf("this session is not in the billing API yet; added its %.2f", g)
    else                   why = sprintf("billing API already includes %.2f of this session; added the remaining %.2f", seen, add)
    printf "%.2f basis: billed %.2f; %s.\n", n + add, n, why
  }'
}

init_log() {
  mkdir -p "$(dirname "$LOG_MD")"
  cat > "$LOG_MD" <<'EOF'
# GPU session log

Written by `scripts/session.sh`. One row per paid session. `EUR` is compute
only, at the instance type's hourly rate (looked up at `start`, shown in the
`what was done` column since 2026-10-04; EUR 1.47/h for L40S-1-48G); storage and the flexible IPv4 accrue continuously and are
accounted separately in `benchmarks/cost-model.md`.

The `left as` column is the evidence for the week 6 idle-cost claim: on
Scaleway, powering off pauses compute billing but NOT storage or IP.

| date | server | start (UTC) | end (UTC) | GPU h | what was done | EUR | running EUR | left as |
|---|---|---|---|---|---|---|---|---|
EOF
}

case "${1:-}" in
  start)    cmd_start ;;
  ssh-rule) sync_ssh_rule ;;
  status) cmd_status ;;
  end)    shift; cmd_end "$@" ;;
  *) sed -n '3,9p' "$0"; exit 2 ;;
esac
