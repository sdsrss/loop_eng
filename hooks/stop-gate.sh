#!/usr/bin/env bash
# loop-eng stop-gate — mechanism-layer enforcement for /autoloop.
#
# While .loop/active exists, a session cannot stop unless the loop contract
# passes. This turns "the model promises to keep looping" into "the harness
# refuses to let it quit early".
#
# Contract sources, in order of preference:
#   1. .loop/criteria.tsv  -> executed via the plugin-owned run-contract.sh
#      (also refreshes .loop/results.json + .loop/evidence/ on every stop
#      attempt, so the evidence ledger is never staler than the last stop)
#   2. .loop/verify.sh     -> legacy path (pre-0.2 loops)
#
# Never blocks forever: a block counter (MAX_BLOCKS) is the hard ceiling,
# and the orchestrator removes .loop/active on any legitimate end
# (ALL GREEN or a stop-rule escalation).
#
# PLATFORM CEILING: Claude Code force-allows the stop after 8 consecutive
# Stop-hook blocks (documented in code.claude.com/docs/en/best-practices).
# MAX_BLOCKS MUST stay < 8 or the last blocks silently never fire.
#
# Stop-hook contract: exit 0 = allow stop; exit 2 = block stop, stderr is
# fed back to the model as the reason.

set -u
cat > /dev/null # consume hook stdin JSON; all state we need is on disk

LOOP_DIR=".loop"
ACTIVE="$LOOP_DIR/active"
VERIFY="$LOOP_DIR/verify.sh"
CRIT="$LOOP_DIR/criteria.tsv"
COUNT_FILE="$LOOP_DIR/gate-count"
MAX_BLOCKS=3 # keep < 8: see PLATFORM CEILING above

# No active loop -> allow stop.
[ -f "$ACTIVE" ] || exit 0

RUNNER="$(cd "$(dirname "$0")" && pwd)/../skills/loop-eng/scripts/run-contract.sh"

if [ -f "$CRIT" ] && [ -f "$RUNNER" ]; then
  CHECK_CMD=(bash "$RUNNER")
  CHECK_DESC="contract criteria ($CRIT via run-contract.sh)"
elif [ -f "$VERIFY" ]; then
  CHECK_CMD=(bash "$VERIFY")
  CHECK_DESC="verify script ($VERIFY)"
else
  echo "loop-eng stop-gate: .loop/active present but no criteria.tsv or verify.sh; allowing stop." >&2
  exit 0
fi

COUNT=0
if [ -f "$COUNT_FILE" ]; then
  COUNT=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
fi
case "$COUNT" in *[!0-9]* | "") COUNT=0 ;; esac

if [ "$COUNT" -ge "$MAX_BLOCKS" ]; then
  echo "loop-eng stop-gate: block ceiling ($MAX_BLOCKS) reached; allowing stop. Contract remains UNSATISFIED — see $LOOP_DIR/state.md." >&2
  exit 0
fi

OUT=$("${CHECK_CMD[@]}" 2>&1)
STATUS=$?

if [ "$STATUS" -eq 0 ]; then
  # Contract satisfied: lift the gate so future stops are free.
  rm -f "$ACTIVE" "$COUNT_FILE"
  exit 0
fi

echo $((COUNT + 1)) > "$COUNT_FILE"
{
  echo "loop-eng stop-gate BLOCKED this stop ($((COUNT + 1))/$MAX_BLOCKS): the loop contract is not satisfied."
  echo "$CHECK_DESC failed with exit $STATUS. Output tail:"
  printf '%s\n' "$OUT" | tail -15
  echo "Continue the loop: fix per the checker report, or end it legitimately"
  echo "via a stop rule (record it in .loop/state.md and remove .loop/active)."
} >&2
exit 2
