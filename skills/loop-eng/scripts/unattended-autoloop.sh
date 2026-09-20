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

# The bash >= 4.4 requirement in the header is CHECKED, not just stated, and it
# is checked HERE — above `set -euo pipefail` — on purpose.
#
# Pre-fix the requirement was a comment: on stock macOS bash 3.2 this driver
# STARTED, did real work, and only then died on the first empty-array expansion
# under `set -u` — the worst shape for an unattended writer, which for THIS one
# may already have let a session commit. 78 = EX_CONFIG, the code these scripts
# use for every other unrunnable configuration.
#
# ORDER IS LOAD-BEARING, and this is the second thing that bit it. `set -o
# pipefail` is not POSIX: some `sh` implementations accept it, others answer
# "Illegal option -o pipefail" and exit 2. Debian/Ubuntu both ship dash as
# /bin/sh and they do NOT agree with each other — a local dash accepted it while
# the GitHub ubuntu-latest runner's rejected it, which is how a guard that was
# green on this machine went red in CI. Below `set -euo pipefail` the non-bash
# arm is unreachable on exactly the shells it exists to catch. Above it, the two
# ifs are plain POSIX every shell can run, so the refusal is the same everywhere.
#
# They run without `-e`, which is fine and deliberate: each is self-contained and
# exits explicitly. The BASH_VERSION test also has to precede the BASH_VERSINFO
# one, because a non-bash shell dies on the ARRAY SUBSCRIPT in that test with a
# bare "Bad substitution" — the `:-0` default never applies, since the failure is
# in the subscript syntax rather than the value.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "unattended-autoloop: needs bash >= 4.4 and is not running under bash at all. Re-run it as \`bash unattended-autoloop.sh …\` (or let its shebang do it)." >&2
  exit 78
fi
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] \
   || { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 4 ]; }; then
  echo "unattended-autoloop: needs bash >= 4.4, got ${BASH_VERSION:-non-bash shell}. Stock macOS ships 3.2; install a newer bash (brew install bash) and run this script with it. Refusing now rather than failing partway through an unattended run." >&2
  exit 78
fi

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

# Same fail-open as unattended-polish.sh: the in-loop `git status --porcelain`
# dirty check reads EMPTY in a non-repo (git's fatal goes to stderr), so the
# guard passed and the driver only stopped further down, when `git rev-parse
# HEAD` died under `set -e` — exit 128 and a pile of raw git fatals instead of
# the one fact the operator needs. Establish the work tree up front.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "not a git repository (or no work tree): $REPO — refusing unattended run. Unattended changes must be attributable and revertable." >&2
  exit 1
fi

BACKLOG=".loop/backlog.md"
if [ ! -f "$BACKLOG" ]; then
  echo "no $BACKLOG — write a '- [ ] item' backlog first" >&2
  exit 78
fi
mkdir -p .loop
LOG_MAIN=".loop/unattended.log"

# Mutual exclusion, one driver per repo — see the long note in
# unattended-polish.sh, which carries the same block. Short version: nothing
# enforced it, two drivers on one tree both passed the dirty-tree check and both
# started a `bypassPermissions` session, and `install-timer.sh` defaults BOTH
# modes to `--time 03:00`, so installing both timers on one repo is the
# documented way to get there. `flock` where it exists (the kernel releases it
# however the process dies), atomic `mkdir` with a pid-staleness check where it
# does not (stock macOS). 69 = EX_UNAVAILABLE, kept distinct from the 75 these
# drivers already use for provider limits.
LOCK_DIR=".loop/driver.lock"
LOCK_HELD=0
if command -v flock >/dev/null 2>&1; then
  exec 9>".loop/driver.lock.fd"
  if ! flock -n 9; then
    echo "$(date +%Y%m%d-%H%M%S) autoloop-driver another unattended driver is already running in $REPO — refusing to run a second session against the same tree" \
      | tee -a "$LOG_MAIN" >&2
    exit 69
  fi
else
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_HELD=1
  else
    lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
    case "$lock_pid" in ''|*[!0-9]*) lock_pid="" ;; esac
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      echo "$(date +%Y%m%d-%H%M%S) autoloop-driver another unattended driver (pid $lock_pid) is already running in $REPO — refusing to run a second session against the same tree" \
        | tee -a "$LOG_MAIN" >&2
      exit 69
    fi
    rm -rf "${LOCK_DIR:?}"
    if mkdir "$LOCK_DIR" 2>/dev/null; then LOCK_HELD=1; else
      echo "$(date +%Y%m%d-%H%M%S) autoloop-driver could not take the driver lock in $REPO — refusing" \
        | tee -a "$LOG_MAIN" >&2
      exit 69
    fi
  fi
  echo $$ > "$LOCK_DIR/pid"
fi
_release_lock() { [ "$LOCK_HELD" -eq 1 ] && rm -rf "${LOCK_DIR:?}"; return 0; }
trap _release_lock EXIT

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

# Signal handling. Without it, a SIGTERM to this driver — `systemctl stop` on a
# host whose unit does not cgroup-kill, a cron `kill <pid>`, a hand-typed Ctrl-C
# — killed the driver and LEFT THE SESSION RUNNING: a `bypassPermissions`
# claude that WRITES CODE, with nobody watching it, working to its own budget.
# Reproduced with a sleeping stub: driver dead, stub alive.
#
# Each session therefore runs in the BACKGROUND with an explicit `wait`. A
# foreground child blocks trap dispatch until it exits, so a trap installed
# around one fires too late to do anything. On a signal, TERM the session and
# give it a grace period before KILL; `timeout(1)` forwards TERM to its own
# child, so one TERM reaches claude whether or not a wrapper is in play.
#
# 143 = 128 + SIGTERM, so a scheduler can tell an interrupted run from a failure.
SESSION_PID=""
_terminate() {
  trap '' TERM INT HUP   # a second signal must not re-enter this handler
  if [ -n "$SESSION_PID" ] && kill -0 "$SESSION_PID" 2>/dev/null; then
    kill -TERM "$SESSION_PID" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$SESSION_PID" 2>/dev/null || break
      sleep 1
    done
    kill -KILL "$SESSION_PID" 2>/dev/null || true
  fi
  note "interrupted by signal — session terminated, $(count_pending) item(s) still pending"
  exit 143
}

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

# Installed here, not beside _terminate: the handler reports the pending count,
# so it must not be reachable before count_pending exists.
trap _terminate TERM INT HUP

# Reclaim a stop-gate left armed by a previous session.
#
# .loop/active is lifted by the stop-gate ONLY when the contract goes green. A
# session that was killed (this driver's own timeout, a TERM, a crash) or that
# hit the 3-block ceiling leaves it on disk with a clean tree. The next session
# then tries to write its own criteria.tsv and the evidence-gate DENIES it —
# through Write and through Bash, since the file is the armed contract — so that
# session arms nothing, verifies nothing and commits nothing. Two of those and
# the circuit breaker opens, with only `NO new commits` in the log to explain a
# backlog that stopped moving. Reproduced: DENIED on both write paths, then
# `circuit breaker OPEN`.
#
# The driver is the human-authorized OUTER layer — "the model must not disarm
# its own gate" is a rule about the session inside, not about the scheduler that
# started it — so reclaiming here is correct where doing it from the prompt
# would not be. All three files go: a lone criteria.sha256 would make the next
# arm's own criteria.tsv read as tampered, and a lone gate-count would start it
# partway to the ceiling.
reclaim_stale_gate() {
  [ -f .loop/active ] || return 0
  note "previous session left the gate armed (.loop/active) — disarming so the next session can write its own contract"
  rm -f .loop/active .loop/gate-count .loop/criteria.sha256
}
reclaim_stale_gate

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
    > "$SLOG" 2>&1 &
  SESSION_PID=$!
  wait "$SESSION_PID" || STATUS=$?
  SESSION_PID=""

  if [ -n "$TIMEOUT_BIN" ] && [ "$STATUS" -eq 124 ]; then
    note "session $session TIMED OUT after ${budget_left}s (wall-clock budget) — killed, counts toward no-progress unless it committed"
  fi

  # Again after the session, not only before the first one: this is where a
  # killed or ceilinged session's leftover actually appears, and leaving it
  # until the next driver run would cost this run every remaining session.
  reclaim_stale_gate

  head_after=$(git rev-parse HEAD)
  if [ "$head_before" = "$head_after" ]; then
    no_progress=$((no_progress + 1))
    note "session $session exit=$STATUS NO new commits (no-progress $no_progress/2) log=$SLOG"
  else
    no_progress=0
    note "session $session exit=$STATUS commits=$(git rev-list --count "$head_before..$head_after") log=$SLOG"
  fi

  # Broad phrases are safe here because the grep only runs on FAILED sessions
  # (STATUS != 0), which bounds the false-positive surface.
  if [ "$STATUS" -ne 0 ] && grep -qiE 'usage limit|rate.?limit(ed)?|quota|overloaded|too many requests' "$SLOG"; then
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
