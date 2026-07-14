#!/usr/bin/env bash
# loop-eng arm-contract — machine-arm the stop-gate for /autoloop.
#
# Replaces the manual `touch .loop/active`. Records the SHA-256 of the
# just-authored criteria.tsv into .loop/criteria.sha256, then arms the loop
# (.loop/active) and clears any stale block counter. run-contract.sh verifies
# that hash on every stop attempt and fails CLOSED if criteria.tsv no longer
# matches — so weakening an armed contract can never pass silently, whatever
# write path is used (Write/Edit tool OR Bash verbs the evidence-gate regex
# can't see). The hash is captured at arm time, right after the human/orchestrator
# authors the contract and before the builder runs.
#
# Honest scope: a fully adversarial model with arbitrary Bash could rewrite BOTH
# criteria.tsv and criteria.sha256 to a matching weakened pair. That residual is
# covered by the red lines in the command prompts and human review of the diff —
# note that .loop/ is gitignored, so a weakened contract is invisible in git.
set -u

# LOOP_ENG_LOOP_DIR is a TEST-ONLY knob (the plugin's own suite sandboxes with
# it). The stop-gate and evidence-gate are fixed to .loop/ — arming a custom
# dir in production means NEITHER hook watches it (silently disarmed loop).
LOOP_DIR="${LOOP_ENG_LOOP_DIR:-.loop}"
CRIT="$LOOP_DIR/criteria.tsv"
SHA_LOCK="$LOOP_DIR/criteria.sha256"
ACTIVE="$LOOP_DIR/active"
COUNT_FILE="$LOOP_DIR/gate-count"

mkdir -p "$LOOP_DIR"

loop_sha256() { # portable SHA-256 of a file -> stdout (empty if no tool)
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | awk '{print $NF}'
  fi
}

if [ -f "$CRIT" ]; then
  # Warn early (fail-fast) if the contract verifies nothing: a criteria.tsv with
  # zero runnable lines (empty / all-comment / all-malformed) makes run-contract
  # fail CLOSED on every stop. Catch it at arm time rather than at first block.
  # Runnable = non-empty id that isn't a #comment, with a non-empty command col.
  runnable=$(awk -F'\t' '$1 != "" && $1 !~ /^#/ && $3 != "" {n++} END{print n+0}' "$CRIT" 2>/dev/null || echo 0)
  if [ "${runnable:-0}" -eq 0 ]; then
    echo "loop-eng arm-contract: WARNING — criteria.tsv has no runnable criteria (need <id>TAB<description>TAB<command> lines). run-contract will FAIL CLOSED on every stop until you add at least one; a contract that verifies nothing can never be 'done'." >&2
  fi
  hash=$(loop_sha256 "$CRIT")
  if [ -n "$hash" ]; then
    printf '%s\n' "$hash" > "$SHA_LOCK"
    echo "loop-eng arm-contract: pinned criteria.tsv @ $hash" >&2
  else
    rm -f "$SHA_LOCK"
    echo "loop-eng arm-contract: no SHA-256 tool available; contract armed WITHOUT a hash-lock (drift will not fail closed)." >&2
  fi
else
  rm -f "$SHA_LOCK"
  echo "loop-eng arm-contract: no $CRIT (legacy verify.sh loop?); armed without a hash-lock." >&2
fi

# Pre-arm RED-CHECK (pilot retro finding): a verify criterion that is ALREADY
# green before any work has been done is untrustworthy — like a test that has
# never failed, it may be vacuously satisfied (e.g. a grep matching a
# pre-existing comment, a file-exists check on a file that predates the task).
# Surface it here so the human can judge whether it can actually go RED.
# ADVISORY ONLY: this loop never changes the arm outcome — the contract is
# already pinned above and .loop/active is still created below regardless. A
# criterion that is legitimately green at arm (e.g. a baseline "suite passes")
# also warns; that is acceptable, the human decides. Same TSV parse shape as
# run-contract.sh (skip blanks + #comments, strip a trailing CR). Each command
# runs read-only with stdout+stderr silenced so arm's own output stays clean.
#
# Knobs (arming must stay instant even when a criterion is the full test suite):
#   LOOP_ENG_ARM_REDCHECK=0          skip the red-check entirely — ZERO criterion
#                                    commands executed (guarded before the loop).
#   LOOP_ENG_ARM_REDCHECK_TIMEOUT=N  per-criterion budget in seconds (default 10;
#                                    non-numeric or 0 falls back to 10). A command
#                                    that times out exits 124 via timeout(1): it is
#                                    UNKNOWN, not green, so it never warns.
if [ -f "$CRIT" ] && [ "${LOOP_ENG_ARM_REDCHECK:-1}" != "0" ]; then
  REDCHECK_TIMEOUT="${LOOP_ENG_ARM_REDCHECK_TIMEOUT:-10}"
  case "$REDCHECK_TIMEOUT" in ''|*[!0-9]*) REDCHECK_TIMEOUT=10 ;; esac
  # 10#: "00"/"08" are digit strings too; force base-10 so the arithmetic never
  # sees a bad octal token. 0 would DISABLE timeout(1) (GNU semantics) — the
  # opposite of a budget at its lowest value — so it also falls back to 10.
  if [ "$((10#$REDCHECK_TIMEOUT))" -eq 0 ]; then REDCHECK_TIMEOUT=10; fi
  # Same detection as stop-gate.sh (bash 3.2-safe): prefer timeout(1), else
  # gtimeout (macOS coreutils), else run unbounded rather than fail — advisory.
  REDCHECK_TIMEOUT_BIN=""
  if command -v timeout >/dev/null 2>&1; then REDCHECK_TIMEOUT_BIN="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then REDCHECK_TIMEOUT_BIN="gtimeout"; fi
  while IFS=$'\t' read -r id desc cmd || [ -n "$id" ]; do
    [ -z "${id:-}" ] && continue
    case "$id" in \#*) continue ;; esac
    cmd="${cmd%$'\r'}"
    [ -z "${cmd:-}" ] && continue
    if [ -n "$REDCHECK_TIMEOUT_BIN" ]; then
      "$REDCHECK_TIMEOUT_BIN" "$REDCHECK_TIMEOUT" bash -c "$cmd" >/dev/null 2>&1
    else
      bash -c "$cmd" >/dev/null 2>&1
    fi
    redcheck_status=$?
    if [ "$redcheck_status" -eq 0 ]; then
      echo "loop-eng arm-contract: WARNING — criterion '$id' is already green at arm time (passed before any work). A criterion that never had to go RED may be vacuously satisfied — verify it actually tests the change. Advisory only; the loop is still armed." >&2
    fi
  done < "$CRIT"
fi

: > "$ACTIVE"
rm -f "$COUNT_FILE"
echo "loop-eng arm-contract: stop-gate armed ($ACTIVE)." >&2
