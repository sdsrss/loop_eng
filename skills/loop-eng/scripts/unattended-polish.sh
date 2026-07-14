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
#   - wall-clock budget: LOOP_ENG_MAX_MINUTES (default 120) via `timeout`
#     when available (GNU coreutils; absent on stock macOS -> no hard cap)
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

set -euo pipefail

REPO="${1:?usage: unattended-polish.sh <repo-dir> [scope] [--auto-fix]}"
SCOPE="${2:-src/}"
FLAG="${3:-}"
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
LOG_DIR=".loop"
mkdir -p "$LOG_DIR"

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

TIMEOUT_CMD=()
if command -v timeout >/dev/null 2>&1; then
  TIMEOUT_CMD=(timeout "${MAX_MINUTES}m")
fi

STATUS=0
"${TIMEOUT_CMD[@]}" "$CLAUDE_BIN" -p "/polish $SCOPE $MODE" \
  --permission-mode bypassPermissions \
  --max-turns 120 \
  > "$LOG" 2>&1 || STATUS=$?

# Broad phrases are safe here because the grep only runs on FAILED runs
# (STATUS != 0), which bounds the false-positive surface.
if [ "$STATUS" -ne 0 ] && grep -qiE 'usage limit|rate.?limit(ed)?|quota|overloaded|too many requests' "$LOG"; then
  echo "$STAMP mode=${MODE:-auto-fix} scope=$SCOPE exit=$STATUS rate-limited log=$LOG" >> "$LOG_DIR/unattended.log"
  tail -40 "$LOG"
  exit 75
fi

echo "$STAMP mode=${MODE:-auto-fix} scope=$SCOPE exit=$STATUS log=$LOG" >> "$LOG_DIR/unattended.log"
tail -40 "$LOG"
exit "$STATUS"
