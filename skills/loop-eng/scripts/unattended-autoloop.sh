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
#     default 240) checked between sessions
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
DEADLINE=$(( $(date +%s) + MAX_MINUTES * 60 ))
no_progress=0
limit_hits=0
session=0

note() { echo "$(date +%Y%m%d-%H%M%S) autoloop-driver $*" | tee -a "$LOG_MAIN" >&2; }

count_pending() { grep -c '^- \[ \]' "$BACKLOG" 2>/dev/null || true; }

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

  STATUS=0
  "$CLAUDE_BIN" -p "/autoloop Take exactly ONE backlog item — the first unchecked '- [ ]' line in .loop/backlog.md: \"$item\". Before writing the contract, read .loop/state.md (if present) and run 'git log --oneline -10' for handoff context from previous sessions. On ALL GREEN, mark that backlog line '- [x]'. Do not start any other backlog item." \
    --permission-mode bypassPermissions \
    --max-turns 150 \
    > "$SLOG" 2>&1 || STATUS=$?

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

note "driver done: sessions=$session remaining=$(count_pending)"
