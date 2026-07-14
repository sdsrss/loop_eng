#!/usr/bin/env bash
# loop-eng unattended autoloop driver — cross-session fresh-context orchestration.
# Requires bash >= 4.4 (empty-array expansion under set -u; macOS system bash 3.2 is too old).
#
# Pattern (Anthropic, effective-harnesses-for-long-running-agents): one backlog
# item per FRESH session — context compaction is not a recovery strategy —
# with .loop/state.md + git log as the dual handoff record, and an OUTER
# circuit breaker keyed to actual commits, not to the model's own claims.
#
# Safety:
#   - requires LOOP_ENG_ALLOW_AUTOBUILD=1 (this driver WRITES code unattended;
#     mirrors LOOP_ENG_ALLOW_AUTOFIX in unattended-polish.sh)
#   - refuses dirty trees; every session starts from a committed state
#   - circuit breaker: 2 consecutive sessions with no new commit -> OPEN, stop
#   - session cap (arg 2, default 8) + wall-clock budget (LOOP_ENG_MAX_MINUTES,
#     default 240) checked between sessions; each session is additionally run
#     under `timeout` bounded by the remaining budget, so a hung session cannot
#     stall the driver past the deadline
#   - provider-limit aware: a failed session whose log mentions a usage/rate
#     limit waits once (LOOP_ENG_LIMIT_WAIT_MIN, default 60) and retries;
#     a second hit stops the driver with exit 75 (EX_TEMPFAIL)
#
# Usage: unattended-autoloop.sh <repo-dir> [max-sessions]
# Backlog: .loop/backlog.md, one "- [ ] item" line each (top item runs first;
# /autoloop marks a line "- [x]" when its round ends ALL GREEN).

set -euo pipefail

REPO="${1:?usage: unattended-autoloop.sh <repo-dir> [max-sessions]}"
MAX_SESSIONS="${2:-8}"
CLAUDE_BIN="${LOOP_ENG_CLAUDE_BIN:-claude}"
MAX_MINUTES="${LOOP_ENG_MAX_MINUTES:-240}"
LIMIT_WAIT_MIN="${LOOP_ENG_LIMIT_WAIT_MIN:-60}"

# Validate numeric knobs before they reach arithmetic / [ -ge ] tests: a garbage
# value crashes the driver ("xyz: unbound variable" in $(( )) under set -u) or
# silently disables a guard ([ 0 -ge abc ] errors -> cap never fires). This is an
# UNATTENDED entry point, so warn and fall back to the default rather than die.
_num_or_default() { # $1=name $2=value $3=default -> echoes a base-10 integer
  case "$2" in
    ''|*[!0-9]*) echo "warning: $1='$2' is not a non-negative integer; using $3" >&2; echo "$3" ;;
    # Force base-10: a leading-zero value like 08/09 is a valid digit string but
    # crashes bash arithmetic ($((08*60)) -> "value too great for base"). 10#
    # strips the leading zeros so downstream $(( )) never sees a bad octal token.
    *) echo $((10#$2)) ;;
  esac
}
MAX_SESSIONS=$(_num_or_default max-sessions "$MAX_SESSIONS" 8)
MAX_MINUTES=$(_num_or_default LOOP_ENG_MAX_MINUTES "$MAX_MINUTES" 240)
LIMIT_WAIT_MIN=$(_num_or_default LOOP_ENG_LIMIT_WAIT_MIN "$LIMIT_WAIT_MIN" 60)
# 0 is a valid digit string but means "no budget at all": DEADLINE=now, and —
# worse — a 0-second per-session `timeout` DISABLES the timeout entirely (GNU
# semantics), the exact opposite of what a budget knob should do on its lowest
# value. Treat it as a config error and fall back, like the non-numeric case.
if [ "$MAX_MINUTES" -eq 0 ]; then
  echo "warning: LOOP_ENG_MAX_MINUTES=0 would disable the wall-clock budget (timeout 0 = no limit); using 240" >&2
  MAX_MINUTES=240
fi

if [ "${LOOP_ENG_ALLOW_AUTOBUILD:-0}" != "1" ]; then
  echo "refusing: unattended building requires LOOP_ENG_ALLOW_AUTOBUILD=1" >&2
  exit 1
fi

cd "$REPO"
BACKLOG=".loop/backlog.md"
if [ ! -f "$BACKLOG" ]; then
  echo "no $BACKLOG — write a '- [ ] item' backlog first" >&2
  exit 78
fi
mkdir -p .loop
LOG_MAIN=".loop/unattended.log"

# Log rotation, before anything else appends: under a years-long systemd timer
# every run adds a timestamped per-session log and the rolling log only ever
# grows, so an unattended host fills .loop/ (eventually the disk) without
# bound. Per-session logs (unattended-session-<stamp>.log — the dash in the
# glob excludes the rolling unattended.log) are dropped after 30 days; the
# rolling log is capped at 1MB by keeping its tail. cat-back into the same
# inode (not mv) so a concurrent appender keeps writing to the live file —
# best effort: lines appended between the tail snapshot and the cat-back are
# lost.
find .loop -maxdepth 1 -name 'unattended-*.log' -mtime +30 -exec rm -f {} + || true
if [ -f "$LOG_MAIN" ] && [ "$(wc -c < "$LOG_MAIN")" -gt 1048576 ]; then
  tail -c 524288 "$LOG_MAIN" > "$LOG_MAIN.tmp" && cat "$LOG_MAIN.tmp" > "$LOG_MAIN"
  rm -f "$LOG_MAIN.tmp"
fi
DEADLINE=$(( $(date +%s) + MAX_MINUTES * 60 ))
no_progress=0
limit_hits=0
session=0

note() { echo "$(date +%Y%m%d-%H%M%S) autoloop-driver $*" | tee -a "$LOG_MAIN" >&2; }

count_pending() {
  # A missing/unreadable backlog (e.g. a session deleted it mid-run) must count
  # as 0 pending, not as an empty string — `[ "" -eq 0 ]` errors and the if
  # swallows it as false, which would SKIP the "backlog empty" stop and keep
  # launching sessions against a backlog that no longer exists.
  local n
  n=$(grep -c '^- \[ \]' "$BACKLOG" 2>/dev/null) || true
  case "$n" in '' | *[!0-9]*) n=0 ;; esac
  echo "$n"
}

# Per-session hard cap: without it, MAX_MINUTES is only checked BETWEEN sessions,
# so a single hung `claude -p` (network stall, wedged tool) blocks the driver
# forever — under a systemd oneshot unit, potentially for days. Mirror the
# stop-gate's timeout/gtimeout fallback; if neither exists, warn once and run
# unbounded (same degradation unattended-polish.sh already accepts).
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout"; fi
[ -n "$TIMEOUT_BIN" ] || note "warning: no timeout(1)/gtimeout — sessions run UNBOUNDED; a hung session will stall the driver"

while :; do
  remaining=$(count_pending)
  if [ "$remaining" -eq 0 ]; then note "backlog empty — done"; break; fi
  if [ "$session" -ge "$MAX_SESSIONS" ]; then
    note "session cap ($MAX_SESSIONS) reached, $remaining item(s) left"; break; fi
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    note "wall-clock budget (${MAX_MINUTES}m) exhausted, $remaining item(s) left"; break; fi
  if [ "$no_progress" -ge 2 ]; then
    note "circuit breaker OPEN: 2 consecutive sessions with no new commits"; break; fi
  if git status --porcelain | grep -vq '^?? \.loop/'; then
    note "dirty tree, refusing to continue"; exit 1; fi

  session=$((session + 1))
  head_before=$(git rev-parse HEAD)
  item=$(grep -m1 '^- \[ \]' "$BACKLOG" | sed 's/^- \[ \] //')
  STAMP=$(date +%Y%m%d-%H%M%S)
  SLOG=".loop/unattended-session-$STAMP.log"
  note "session $session/$MAX_SESSIONS starting: $item"

  # Bound the session to the REMAINING wall-clock budget (floor 1s: the deadline
  # check above guarantees it was positive moments ago; never hand `timeout` a 0,
  # which would disable it).
  budget_left=$(( DEADLINE - $(date +%s) ))
  [ "$budget_left" -ge 1 ] || budget_left=1
  SESSION_WRAP=()
  [ -n "$TIMEOUT_BIN" ] && SESSION_WRAP=("$TIMEOUT_BIN" -k 30 "$budget_left")

  STATUS=0
  "${SESSION_WRAP[@]}" "$CLAUDE_BIN" -p "/autoloop Take exactly ONE backlog item — the first unchecked '- [ ]' line in .loop/backlog.md: \"$item\". Before writing the contract, read .loop/state.md (if present) and run 'git log --oneline -10' for handoff context from previous sessions. On ALL GREEN, mark that backlog line '- [x]'. Do not start any other backlog item." \
    --permission-mode bypassPermissions \
    --max-turns 150 \
    > "$SLOG" 2>&1 || STATUS=$?

  if [ -n "$TIMEOUT_BIN" ] && [ "$STATUS" -eq 124 ]; then
    note "session $session TIMED OUT after ${budget_left}s (wall-clock budget) — killed, counts toward no-progress unless it committed"
  fi

  head_after=$(git rev-parse HEAD)
  if [ "$head_before" = "$head_after" ]; then
    no_progress=$((no_progress + 1))
    note "session $session exit=$STATUS NO new commits (no-progress $no_progress/2) log=$SLOG"
  else
    no_progress=0
    note "session $session exit=$STATUS commits=$(git rev-list --count "$head_before..$head_after") log=$SLOG"
  fi

  if [ "$STATUS" -ne 0 ] && grep -qiE 'usage limit|rate.?limit(ed)?' "$SLOG"; then
    limit_hits=$((limit_hits + 1))
    if [ "$limit_hits" -ge 2 ]; then
      note "provider limit hit twice — stopping"; exit 75; fi
    note "provider limit detected — waiting ${LIMIT_WAIT_MIN}m before retrying"
    sleep $((LIMIT_WAIT_MIN * 60))
  fi
done

# Exit code must reflect the REMAINING backlog, not merely "the loop ended":
# of the four break paths only "backlog empty" is completion — session cap,
# wall-clock budget, and circuit breaker all give up with items pending. A
# uniform exit 0 keeps `systemctl status` green forever and exit-code alerting
# blind while a stuck backlog rots for weeks. 0 = drained; 1 = gave up.
remaining_final=$(count_pending)
note "driver done: sessions=$session remaining=$remaining_final"
if [ "$remaining_final" -gt 0 ]; then
  note "exit 1: backlog not drained ($remaining_final item(s) pending) — stop reason above"
  exit 1
fi
