#!/usr/bin/env bash
# loop-eng unattended polish runner — cron/scheduler entry point.
#
# Discipline built in:
#   - default is report-only (find + adversarially verify, change nothing):
#     prove finding quality is stable BEFORE granting auto-fix
#   - auto-fix requires BOTH the --auto-fix flag AND LOOP_ENG_ALLOW_AUTOFIX=1,
#     so a stray flag alone can never enable writes
#   - refuses to run on a dirty tree (unattended changes must be attributable)
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
STAMP=$(date +%Y%m%d-%H%M%S)
LOG="$LOG_DIR/unattended-$STAMP.log"

# Dirty tree (ignoring .loop/ bookkeeping) -> refuse.
if git status --porcelain | grep -vq '^?? \.loop/'; then
  echo "$STAMP dirty tree, refusing unattended run" | tee -a "$LOG_DIR/unattended.log" >&2
  exit 1
fi

claude -p "/polish $SCOPE $MODE" \
  --permission-mode bypassPermissions \
  --max-turns 120 \
  > "$LOG" 2>&1
STATUS=$?

echo "$STAMP mode=${MODE:-auto-fix} scope=$SCOPE exit=$STATUS log=$LOG" >> "$LOG_DIR/unattended.log"
tail -40 "$LOG"
exit "$STATUS"
