#!/usr/bin/env bash
# loop-eng unattended polish runner — cron/scheduler entry point.
# Requires bash >= 4.4 (empty-array expansion under set -u; macOS system bash 3.2 is too old).
#
# Discipline built in:
#   - default is report-only (find + adversarially verify, change nothing):
#     prove finding quality is stable BEFORE granting auto-fix
#   - auto-fix requires BOTH the --auto-fix flag AND LOOP_ENG_ALLOW_AUTOFIX=1,
#     so a stray flag alone can never enable writes
#   - refuses to run on a dirty tree (unattended changes must be attributable)
#   - wall-clock budget: LOOP_ENG_MAX_MINUTES (default 120) via `timeout`,
#     or `gtimeout` (the macOS coreutils name); with neither on PATH the run
#     is uncapped and says so on stderr rather than dropping the cap silently
#   - provider-limit aware: a failed run whose log mentions a usage/rate
#     limit exits 75 (EX_TEMPFAIL) and is marked in .loop/unattended.log,
#     so schedulers can distinguish "try again later" from real failures
#
# Cron example (nightly report-only at 03:00):
#   0 3 * * * /path/to/unattended-polish.sh /path/to/repo src/ >/dev/null 2>&1
#
# Permissions: headless runs cannot answer prompts. Either maintain a project
# allowlist in .claude/settings.json (preferred for auto-fix), or rely on this
# script's bypass mode which is capped to report-only unless explicitly opted in.

# The bash >= 4.4 requirement in the header is CHECKED, not just stated, and it
# is checked HERE — above `set -euo pipefail` — on purpose.
#
# Pre-fix the requirement was a comment: on stock macOS bash 3.2 this driver
# STARTED, did real work, and only then died on the first empty-array expansion
# under `set -u` — the worst shape for an unattended writer, which may already
# have let a session touch the repo. 78 = EX_CONFIG, the code these scripts use
# for every other unrunnable configuration.
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
  echo "unattended-polish: needs bash >= 4.4 and is not running under bash at all. Re-run it as \`bash unattended-polish.sh …\` (or let its shebang do it)." >&2
  exit 78
fi
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] \
   || { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 4 ]; }; then
  echo "unattended-polish: needs bash >= 4.4, got ${BASH_VERSION:-non-bash shell}. Stock macOS ships 3.2; install a newer bash (brew install bash) and run this script with it. Refusing now rather than failing partway through an unattended run." >&2
  exit 78
fi

set -euo pipefail

USAGE="usage: unattended-polish.sh <repo-dir> [scope] [--auto-fix]"
REPO="${1:?$USAGE}"
SCOPE="${2:-src/}"
FLAG="${3:-}"

# Validate the argument SHAPE before anything else. Positional args accepted on
# faith made two typos indistinguishable from a working write-mode run — and an
# unattended entry point has nobody watching the first trigger:
#   unattended-polish.sh <repo> --auto-fix       scope omitted, so the flag became
#     the SCOPE: the run stayed report-only (looked fine, exit 0) AND reviewed a
#     scope that does not exist, so it found nothing, nightly, indefinitely.
#   unattended-polish.sh <repo> src/ --auto-fixx unknown flag silently ignored:
#     report-only while the operator believed fixes were landing.
# Exit 64 = EX_USAGE, matching the sysexits codes this runner already speaks
# (75 EX_TEMPFAIL for provider limits; 78 EX_CONFIG in the autoloop driver).
case "$SCOPE" in
  -*) echo "unattended-polish: '$SCOPE' is a flag, not a scope — the scope comes first. $USAGE" >&2; exit 64 ;;
esac
case "$FLAG" in
  ''|--auto-fix) ;;
  *) echo "unattended-polish: unknown option '$FLAG' — the only flag is --auto-fix. $USAGE" >&2; exit 64 ;;
esac
if [ "$#" -gt 3 ]; then
  echo "unattended-polish: too many arguments (got $#). $USAGE" >&2; exit 64
fi
CLAUDE_BIN="${LOOP_ENG_CLAUDE_BIN:-claude}"
MAX_MINUTES="${LOOP_ENG_MAX_MINUTES:-120}"
# A non-numeric budget would reach `timeout "${MAX_MINUTES}m"` and fail opaquely
# ("invalid time interval"). This is an unattended entry point — warn and fall
# back to the default rather than abort the scheduled run on a typo'd env var.
case "$MAX_MINUTES" in
  ''|*[!0-9]*) echo "warning: LOOP_ENG_MAX_MINUTES='$MAX_MINUTES' is not a non-negative integer; using 120" >&2; MAX_MINUTES=120 ;;
esac
# 0 passes the digit check but `timeout 0m` DISABLES the timeout (GNU semantics)
# — the opposite of what a budget knob should mean at its lowest value. Config
# error: warn and fall back. (10#: "00" and "08" are digit strings too; force
# base-10 so the arithmetic never sees a bad octal token.)
if [ "$((10#$MAX_MINUTES))" -eq 0 ]; then
  echo "warning: LOOP_ENG_MAX_MINUTES=0 would disable the timeout (timeout 0m = no limit); using 120" >&2
  MAX_MINUTES=120
fi

MODE="report-only"
if [ "$FLAG" = "--auto-fix" ]; then
  if [ "${LOOP_ENG_ALLOW_AUTOFIX:-0}" = "1" ]; then
    MODE=""
  else
    echo "refusing --auto-fix without LOOP_ENG_ALLOW_AUTOFIX=1" >&2
    exit 1
  fi
fi

cd "$REPO"

# The dirty-tree guard below reads `git status --porcelain`, which in a non-repo
# prints its fatal to STDERR and leaves stdout EMPTY — so `grep -vq` saw no line,
# concluded "not dirty", and let the run proceed. That failed the guard OPEN in
# the one case it matters most: an unattended `--permission-mode bypassPermissions`
# session editing a directory with no version control, so nothing is attributable
# and nothing can be reverted. Establish that git can speak for this tree FIRST;
# only then is an empty porcelain trustworthy as "clean".
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "not a git repository (or no work tree): $REPO — refusing unattended run. Unattended changes must be attributable and revertable." >&2
  exit 1
fi

LOG_DIR=".loop"
mkdir -p "$LOG_DIR"

# Mutual exclusion, one driver per repo. Nothing enforced it: two drivers
# launched against the same tree both passed the dirty-tree check (the tree IS
# clean at that moment) and both started a session — two `bypassPermissions`
# claudes editing one working copy, interleaving edits and commits. This is not
# hypothetical: `install-timer.sh` defaults BOTH modes to `--time 03:00`, so
# installing a polish timer and an autoloop timer on one repo is the documented
# way to produce it. Reproduced with two concurrent drivers: 2 sessions started.
#
# Two mechanisms because there is no one portable lock. `flock` is the better
# one — the kernel drops the lock when the process dies, however it dies — but
# stock macOS does not ship it. `mkdir` is atomic on every POSIX filesystem and
# is the fallback; it needs its own staleness check, because a driver killed
# with SIGKILL runs no trap and leaves the directory behind. The pid inside is
# what distinguishes "held" from "abandoned", and `mkdir` stays the arbiter when
# two drivers reclaim the same stale lock at once.
#
# 69 = EX_UNAVAILABLE: the repo is busy. Deliberately NOT 75/EX_TEMPFAIL, which
# these drivers already use for provider limits — a scheduler that alerts on 75
# must not start alerting about its own second timer.
LOCK_DIR="$LOG_DIR/driver.lock"
LOCK_HELD=0
if command -v flock >/dev/null 2>&1; then
  exec 9>"$LOG_DIR/driver.lock.fd"
  if ! flock -n 9; then
    echo "$(date +%Y%m%d-%H%M%S) another unattended driver is already running in $REPO — refusing to run a second session against the same tree" \
      | tee -a "$LOG_DIR/unattended.log" >&2
    exit 69
  fi
else
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCK_HELD=1
  else
    lock_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
    case "$lock_pid" in ''|*[!0-9]*) lock_pid="" ;; esac
    if [ -n "$lock_pid" ] && kill -0 "$lock_pid" 2>/dev/null; then
      echo "$(date +%Y%m%d-%H%M%S) another unattended driver (pid $lock_pid) is already running in $REPO — refusing to run a second session against the same tree" \
        | tee -a "$LOG_DIR/unattended.log" >&2
      exit 69
    fi
    rm -rf "${LOCK_DIR:?}"
    if mkdir "$LOCK_DIR" 2>/dev/null; then LOCK_HELD=1; else
      echo "$(date +%Y%m%d-%H%M%S) could not take the driver lock in $REPO — refusing" \
        | tee -a "$LOG_DIR/unattended.log" >&2
      exit 69
    fi
  fi
  echo $$ > "$LOCK_DIR/pid"
fi
_release_lock() { [ "$LOCK_HELD" -eq 1 ] && rm -rf "${LOCK_DIR:?}"; return 0; }
trap _release_lock EXIT

# Log rotation, before anything else appends: under a years-long systemd timer
# every run adds a timestamped per-run log and the rolling log only ever grows,
# so an unattended host fills .loop/ (eventually the disk) without bound.
# Per-run logs (unattended-<stamp>.log — NOT the rolling unattended.log, which
# the dash in the glob excludes) are dropped after 30 days; the rolling log is
# capped at 1MB by keeping its tail. cat-back into the same inode (not mv) so a
# concurrent appender keeps writing to the live file — best effort: lines
# appended between the tail snapshot and the cat-back are lost.
find "$LOG_DIR" -maxdepth 1 -name 'unattended-*.log' -mtime +30 -exec rm -f {} + || true
ROLLING="$LOG_DIR/unattended.log"
if [ -f "$ROLLING" ] && [ "$(wc -c < "$ROLLING")" -gt 1048576 ]; then
  tail -c 524288 "$ROLLING" > "$ROLLING.tmp" && cat "$ROLLING.tmp" > "$ROLLING"
  rm -f "$ROLLING.tmp"
fi

STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$LOG_DIR/unattended-$STAMP.log"

# Dirty tree (ignoring .loop/ bookkeeping) -> refuse.
if git status --porcelain | grep -vq '^?? \.loop/'; then
  echo "$STAMP dirty tree, refusing unattended run" | tee -a "$LOG_DIR/unattended.log" >&2
  exit 1
fi

# `timeout` is GNU coreutils; on macOS with Homebrew coreutils the binary is
# installed as `gtimeout`. Probing only the one name made this driver the sole
# budget-wrapping script in the plugin that ran UNBOUNDED on that host — its
# autoloop sibling and the stop-gate both fall back — and it did so silently,
# which is how the gap survived long enough to be documented instead of fixed.
# Absence still degrades rather than refuses (a scheduled report-only review is
# worth running uncapped), but it is now said out loud on stderr, where the
# scheduler's own log will keep it.
#
# `-k 30` matches the autoloop driver: plain `timeout` sends TERM and then waits
# forever if the child ignores it, so a wedged session with a TERM handler made
# the budget advisory. The follow-up KILL 30s later makes it a budget.
TIMEOUT_CMD=()
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD=(timeout -k 30 "${MAX_MINUTES}m")
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_CMD=(gtimeout -k 30 "${MAX_MINUTES}m")
else
  # tee, not a bare >&2: this file's own cron example (line 19) ends `>/dev/null
  # 2>&1`, so a stderr-only warning is discarded by exactly the invocation it is
  # written for, leaving `.loop/unattended.log` showing a plain `exit=0` for an
  # uncapped run. Same idiom as the dirty-tree refusal below.
  echo "$STAMP warning: no timeout(1)/gtimeout — this run is UNBOUNDED; LOOP_ENG_MAX_MINUTES=$MAX_MINUTES cannot be enforced" \
    | tee -a "$LOG_DIR/unattended.log" >&2
fi

# Signal handling. Without it, a SIGTERM to this driver — `systemctl stop` on a
# host whose unit does not cgroup-kill, a cron `kill <pid>`, a hand-typed Ctrl-C
# — killed the driver and LEFT THE SESSION RUNNING: a `bypassPermissions`
# claude with nobody watching it, working to its own budget. Reproduced with a
# sleeping stub: driver dead, stub alive. Only systemd's cgroup kill cleaned up.
#
# The session therefore runs in the BACKGROUND with an explicit `wait`. A
# foreground child blocks trap dispatch until it exits, so a trap installed
# around one is a trap that fires too late to do anything. On a signal, TERM the
# session and give it a grace period before KILL; `timeout(1)` forwards TERM to
# its own child, so one TERM reaches claude whether or not a wrapper is in play.
#
# 143 = 128 + SIGTERM, the conventional "terminated by signal" status, so a
# scheduler can tell an interrupted run from a failed one.
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
  echo "$STAMP interrupted by signal — session terminated" | tee -a "$LOG_DIR/unattended.log" >&2
  exit 143
}
trap _terminate TERM INT HUP

STATUS=0
"${TIMEOUT_CMD[@]}" "$CLAUDE_BIN" -p "/polish $SCOPE $MODE" \
  --permission-mode bypassPermissions \
  --max-turns 120 \
  > "$LOG" 2>&1 &
SESSION_PID=$!
wait "$SESSION_PID" || STATUS=$?
SESSION_PID=""

# Provider-limit detection, narrowed twice.
#
# "Only runs on FAILED runs" was thought to bound the false-positive surface,
# and does not: a polish session REVIEWS CODE, so its log is full of the
# reviewed text. A run that failed for any real reason while reviewing a file
# that mentions `quota` or a rate limiter was reported as EX_TEMPFAIL 75 — "try
# again later" — and the actual failure never surfaced. Reproduced: a stub
# printing `checkQuota() { /* the quota is never reset */ }` and exiting 2 came
# back as exit 75, `rate-limited`.
#
#   - Phrases, not words: the phrases providers actually emit, rather than any
#     appearance of `quota` or `overloaded` anywhere in a code review.
#   - The TAIL, not the whole log: a limit ends the run, so it is the last thing
#     written; matching the body means matching the material under review.
#   - Not on 124: that is our own wall-clock kill, and the partial log it leaves
#     may well contain anything. 0.14.0's release notes recorded this exact
#     misreport as a known consequence of enforcing the cap on macOS.
if [ "$STATUS" -ne 0 ] && [ "$STATUS" -ne 124 ] \
   && tail -n 40 "$LOG" | grep -qiE 'usage limit reached|quota exceeded|rate limit exceeded|rate_limit_error|overloaded_error|too many requests'; then
  echo "$STAMP mode=${MODE:-auto-fix} scope=$SCOPE exit=$STATUS rate-limited log=$LOG" >> "$LOG_DIR/unattended.log"
  tail -40 "$LOG"
  exit 75
fi

echo "$STAMP mode=${MODE:-auto-fix} scope=$SCOPE exit=$STATUS log=$LOG" >> "$LOG_DIR/unattended.log"
tail -40 "$LOG"
exit "$STATUS"
