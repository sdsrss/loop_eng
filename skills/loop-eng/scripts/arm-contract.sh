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

: > "$ACTIVE"
rm -f "$COUNT_FILE"
echo "loop-eng arm-contract: stop-gate armed ($ACTIVE)." >&2
