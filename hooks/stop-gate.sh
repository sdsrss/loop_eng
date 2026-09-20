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
# TIMEOUT / FAIL CLOSED: the contract runs under an internal budget
# (LOOP_ENG_GATE_TIMEOUT, default 100s) kept below the hook timeout in
# hooks.json (120s). If it overruns we block deliberately rather than let the
# platform kill an overrunning hook (a killed Stop hook does not reliably
# block, which would let an UNVERIFIED contract stop). Keep criteria.tsv fast.
#
# Stop-hook contract: exit 0 = allow stop; exit 2 = block stop, stderr is
# fed back to the model as the reason.

set -u
cat > /dev/null # consume hook stdin JSON; all state we need is on disk

LOOP_DIR=".loop"
ACTIVE="$LOOP_DIR/active"
VERIFY="$LOOP_DIR/verify.sh"
CRIT="$LOOP_DIR/criteria.tsv"
SHA_LOCK="$LOOP_DIR/criteria.sha256"
COUNT_FILE="$LOOP_DIR/gate-count"
MAX_BLOCKS=3 # keep < 8: see PLATFORM CEILING above

# No active loop -> allow stop.
[ -f "$ACTIVE" ] || exit 0

# Same-stop-attempt replay — the double-registration guard.
#
# A project that registers this hook in its own .claude/settings.json while
# loop-eng is ALSO installed as a plugin gets the gate fired twice for one stop
# attempt, serially: each invocation read the counter the previous one had just
# written, so one attempt cost two blocks and the 3-block ceiling arrived on the
# second attempt instead of the third. The half nobody had written down is
# worse: the ceiling clears gate-count on its way to allowing, so the twin of
# that allow read 0, re-ran the red contract and exited 2 — under double
# registration the ceiling never actually released the stop.
#
# The twin follows within milliseconds; a genuine next attempt needs a model
# turn first. That gap is the whole signal. gate-last records <epoch> <verdict>
# at every decision below, and an invocation arriving within
# LOOP_ENG_GATE_DEDUP_WINDOW seconds of one replays that verdict verbatim — no
# contract re-run, no counter increment.
#
# Bounded on purpose, because a cache in front of a fail-closed gate is only
# safe while it cannot be aimed: a marker that is unparseable, dated in the
# FUTURE, or older than the window is IGNORED, never honoured, and the window is
# seconds wide. It is deliberately NOT in the evidence-gate's protected set —
# forging one buys a couple of seconds of silence, strictly less than the plain
# `rm .loop/active` this gate has always documented as out of scope. Setting the
# window to 0 disables the replay entirely.
#
# The default is 1 second, which is the smallest window that works rather than a
# guess: `date +%s` has one-second resolution, so two invocations milliseconds
# apart can still land on consecutive integers. 1 covers that straddle and
# nothing more. Narrow is the safe direction — an over-wide window swallows a
# real block, and while that stays fail-closed (the gate keeps blocking; the
# platform's own 8-block force-allow is still the outer bound), the gate's
# ceiling message would never print.
DEDUP_FILE="$LOOP_DIR/gate-last"
DEDUP_WINDOW="${LOOP_ENG_GATE_DEDUP_WINDOW:-1}"
# 10#: "00"/"08" are digit strings too; force base-10 so the arithmetic below
# never sees a bad octal token (same guard as GATE_TIMEOUT further down).
case "$DEDUP_WINDOW" in *[!0-9]* | "") DEDUP_WINDOW=1 ;; esac
DEDUP_WINDOW=$((10#$DEDUP_WINDOW))

record_verdict() { # $1 = allow|block — what this invocation decided, and when
  [ "$DEDUP_WINDOW" -gt 0 ] || return 0
  printf '%s %s\n' "$(date +%s 2>/dev/null || echo 0)" "$1" > "$DEDUP_FILE" 2>/dev/null || :
  return 0
}

if [ "$DEDUP_WINDOW" -gt 0 ] && [ -f "$DEDUP_FILE" ]; then
  LAST_AT=""
  LAST_VERDICT=""
  read -r LAST_AT LAST_VERDICT < "$DEDUP_FILE" 2>/dev/null || :
  NOW=$(date +%s 2>/dev/null || echo 0)
  case "$LAST_AT" in *[!0-9]* | "") LAST_AT="" ;; esac
  # NOW >= LAST_AT rejects a future-dated marker; the subtraction then bounds it
  # to the window. A clock that cannot be read leaves NOW=0, which fails the
  # first test and simply counts the block — the fail-closed direction.
  if [ -n "$LAST_AT" ] && [ "$NOW" -ge "$LAST_AT" ] \
     && [ "$((NOW - LAST_AT))" -le "$DEDUP_WINDOW" ]; then
    case "$LAST_VERDICT" in
      allow)
        echo "loop-eng stop-gate: this hook already ran for the same stop attempt (${DEDUP_WINDOW}s window) and allowed it; replaying that decision instead of re-running the contract. Registered twice? Remove the duplicate Stop hook from .claude/settings.json — the plugin registers its own." >&2
        exit 0 ;;
      block)
        echo "loop-eng stop-gate: this hook already ran for the same stop attempt (${DEDUP_WINDOW}s window) and BLOCKED it; replaying that block without counting it twice. See the reason it printed above. Registered twice? Remove the duplicate Stop hook from .claude/settings.json — the plugin registers its own." >&2
        exit 2 ;;
    esac
  fi
fi

RUNNER="$(cd "$(dirname "$0")" && pwd)/../skills/loop-eng/scripts/run-contract.sh"

MISSING_RUNNER=0
if [ -f "$CRIT" ] && [ -f "$RUNNER" ]; then
  CHECK_CMD=(bash "$RUNNER")
  CHECK_DESC="contract criteria ($CRIT via run-contract.sh)"
elif [ -f "$VERIFY" ]; then
  CHECK_CMD=(bash "$VERIFY")
  CHECK_DESC="verify script ($VERIFY)"
elif [ -f "$CRIT" ]; then
  # A contract EXISTS and we have no way to execute it — that is an UNVERIFIED
  # contract, not an absent one. Handled below, after the block counter is read,
  # so the MAX_BLOCKS ceiling still bounds it (a broken install must not be able
  # to deadlock a session either).
  MISSING_RUNNER=1
else
  # Genuinely contract-less: armed with neither criteria.tsv nor verify.sh.
  # arm-contract.sh arms even without criteria.tsv (legacy verify.sh loops), so
  # blocking here would deadlock a legitimately armed loop with nothing to run.
  echo "loop-eng stop-gate: .loop/active present but no criteria.tsv or verify.sh; allowing stop." >&2
  exit 0
fi

COUNT=0
if [ -f "$COUNT_FILE" ]; then
  COUNT=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)
fi
case "$COUNT" in *[!0-9]* | "") COUNT=0 ;; esac

if [ "$COUNT" -ge "$MAX_BLOCKS" ]; then
  # Reaching the ceiling usually means the orchestrator failed to disarm — tell
  # the human how, or every future stop eats another 3 blocks (audit M5).
  echo "loop-eng stop-gate: block ceiling ($MAX_BLOCKS) reached; allowing stop. Contract remains UNSATISFIED — see $LOOP_DIR/state.md. To disarm manually: rm $ACTIVE" >&2
  # Clear the counter so a stale gate-count can't leave a re-armed loop instantly
  # inert (COUNT>=MAX). .loop/active stays until the orchestrator disarms.
  rm -f "$COUNT_FILE"
  record_verdict allow
  exit 0
fi

# criteria.tsv is right here and its runner is not, so nothing verified this
# contract. Fail CLOSED: an unverifiable contract is not a satisfied one, and
# letting it stop is the exact false green this gate is the last defence
# against. Pre-fix this fell through to the contract-less "allowing stop"
# branch, which both allowed a RED contract to end the session AND said "no
# criteria.tsv" about a file sitting in front of it. Reachable from an
# interrupted /plugin update (hooks/ present, skills/ not yet) or the README's
# manual settings.json registration when <plugin-root> resolves outside the
# plugin tree — in both cases the gate LOOKS armed while enforcing nothing.
if [ "$MISSING_RUNNER" -eq 1 ]; then
  echo $((COUNT + 1)) > "$COUNT_FILE"
  record_verdict block
  {
    echo "loop-eng stop-gate BLOCKED this stop ($((COUNT + 1))/$MAX_BLOCKS): $CRIT exists but its runner does not, so the contract was never verified (fail closed)."
    echo "Looked for the runner at:"
    echo "  $RUNNER"
    echo "The loop-eng install looks incomplete (skills/loop-eng/scripts/ missing), or"
    echo "a manually registered Stop hook points outside the plugin root. Re-run"
    echo "/plugin update loop-eng, or register the hook by the plugin's own path."
    echo "To end this loop without verifying it: rm $ACTIVE"
  } >&2
  exit 2
fi

# Bound the contract run below the hook's own timeout so WE decide the outcome.
# Claude Code kills a Stop hook that overruns its configured timeout (120s, see
# hooks.json), and a killed Stop hook does NOT reliably block — the session
# could then stop with the contract UNVERIFIED. So run the check under a shorter
# internal budget and, if it overruns, block deliberately (fail closed) instead
# of gambling on the platform's kill behavior. Keep LOOP_ENG_GATE_TIMEOUT < the
# hook timeout in hooks.json.
GATE_TIMEOUT="${LOOP_ENG_GATE_TIMEOUT:-100}"
case "$GATE_TIMEOUT" in *[!0-9]* | "") GATE_TIMEOUT=100 ;; esac
# 0 is all-digits, so the check above passes it through — but GNU `timeout 0`
# means NO limit, which removes the very fail-closed guard this budget exists to
# provide: the contract would then run past the hook's own 120s timeout and be
# killed by the platform, and a killed Stop hook does not reliably block, so an
# UNVERIFIED contract could stop. Config error: warn and fall back, exactly as
# arm-contract.sh and both unattended runners already do for their own budgets.
# (10#: "00"/"08" are digit strings too; force base-10 so the arithmetic never
# sees a bad octal token.)
if [ "$((10#$GATE_TIMEOUT))" -eq 0 ]; then
  echo "loop-eng stop-gate: LOOP_ENG_GATE_TIMEOUT=$GATE_TIMEOUT would disable the fail-closed contract budget (timeout 0 = no limit); using 100." >&2
  GATE_TIMEOUT=100
fi
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout"; fi

if [ -n "$TIMEOUT_BIN" ]; then
  OUT=$("$TIMEOUT_BIN" -k 5 "$GATE_TIMEOUT" "${CHECK_CMD[@]}" 2>&1)
  STATUS=$?
else
  echo "loop-eng stop-gate: no timeout(1)/gtimeout available; running the contract UNBOUNDED (near-timeout fail-closed guard inactive — keep criteria.tsv fast)." >&2
  OUT=$("${CHECK_CMD[@]}" 2>&1)
  STATUS=$?
fi

# timeout(1) exits 124 when it had to signal the command: the contract did not
# finish within our budget. An unverified contract must not pass -> fail closed.
if [ -n "$TIMEOUT_BIN" ] && [ "$STATUS" -eq 124 ]; then
  echo $((COUNT + 1)) > "$COUNT_FILE"
  record_verdict block
  {
    echo "loop-eng stop-gate BLOCKED this stop ($((COUNT + 1))/$MAX_BLOCKS): the contract did not finish within ${GATE_TIMEOUT}s (fail closed)."
    echo "criteria.tsv is too slow for the Stop-hook budget. Make it a FAST subset"
    echo "(run the full suite in the final manual round), or raise both"
    echo "LOOP_ENG_GATE_TIMEOUT and the hook timeout in hooks.json if you must."
  } >&2
  exit 2
fi

if [ "$STATUS" -eq 0 ]; then
  # Contract satisfied: lift the gate so future stops are free. The dedup marker
  # goes with the rest of the gate's state — the twin invocation finds no
  # .loop/active and allows on its own, and a verdict left behind would be
  # handed to whatever loop is armed in this tree next.
  rm -f "$ACTIVE" "$COUNT_FILE" "$SHA_LOCK" "$DEDUP_FILE"
  exit 0
fi

echo $((COUNT + 1)) > "$COUNT_FILE"
record_verdict block
{
  echo "loop-eng stop-gate BLOCKED this stop ($((COUNT + 1))/$MAX_BLOCKS): the loop contract is not satisfied."
  echo "$CHECK_DESC failed with exit $STATUS. Output tail:"
  # 40, not 15: run-contract's failure summary is ~4 lines per red criterion
  # (name + up to 3 evidence lines) under a "N of M criteria FAILED" header, so
  # a 15-line window dropped the header — and on a multi-criterion contract the
  # earlier failures with it. run-contract bounds its own summary (3 log lines
  # per criterion, 200 columns each), so this stays a small payload.
  printf '%s\n' "$OUT" | tail -40
  echo "Continue the loop: fix per the checker report, or end it legitimately"
  echo "via a stop rule (record it in .loop/state.md and remove .loop/active)."
} >&2
exit 2
