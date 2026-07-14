#!/usr/bin/env bash
# arm-contract.sh: pins criteria.tsv hash, arms the stop-gate, clears stale count.
set -u
. "$(dirname "$0")/lib.sh"

ARM="$PLUGIN_ROOT/skills/loop-eng/scripts/arm-contract.sh"
RUNNER="$PLUGIN_ROOT/skills/loop-eng/scripts/run-contract.sh"
SB=$(mk_sandbox_repo); trap 'rm -rf "$SB"' EXIT
cd "$SB"
mkdir -p .loop

# --- arm pins the hash, creates active, clears a stale gate-count ---
printf '1\tok\ttrue\n' > .loop/criteria.tsv
echo 2 > .loop/gate-count   # stale counter from a previous loop
bash "$ARM" 2>/dev/null
assert_eq 0 $? "arm exits 0"
assert_eq "1" "$([ -f .loop/active ] && echo 1)" "arm creates .loop/active"
assert_eq "" "$([ -f .loop/gate-count ] && echo 1)" "arm clears stale gate-count"
assert_eq "$(sha_of .loop/criteria.tsv)" "$(cut -d' ' -f1 < .loop/criteria.sha256)" "arm pins the correct sha256"

# --- armed contract runs green through run-contract ---
bash "$RUNNER"; assert_eq 0 $? "armed matching contract runs green"

# --- tampering criteria after arm makes run-contract fail closed ---
printf '1\tok\ttrue\n2\tsmuggled\ttrue\n' > .loop/criteria.tsv
bash "$RUNNER" 2>/dev/null; assert_eq 77 $? "post-arm tamper fails closed via the pinned hash"

# --- vacuous criteria.tsv: arm warns but still exits 0 (run-contract fails closed) ---
rm -f .loop/criteria.tsv .loop/criteria.sha256 .loop/active
printf '# just a comment, no runnable criteria\n\n' > .loop/criteria.tsv
bash "$ARM" 2>.loop/armwarn; assert_eq 0 $? "arm on vacuous contract still exits 0"
assert_file_contains .loop/armwarn 'no runnable criteria' "arm warns about vacuous contract"
rm -f .loop/active .loop/criteria.sha256 .loop/gate-count .loop/armwarn

# --- pre-arm red-check: an ALREADY-green criterion warns but arm still succeeds ---
rm -f .loop/criteria.tsv .loop/criteria.sha256 .loop/active .loop/gate-count
printf 'baseline\talready passes\ttrue\n' > .loop/criteria.tsv
bash "$ARM" 2>.loop/armwarn; assert_eq 0 $? "arm with an already-green criterion still exits 0"
assert_eq "1" "$([ -f .loop/active ] && echo 1)" "arm still creates .loop/active despite red-check warning"
assert_file_contains .loop/armwarn 'already green' "arm red-check warns on a criterion green at arm time"
assert_file_contains .loop/armwarn 'baseline' "arm red-check names the offending criterion id"
rm -f .loop/active .loop/criteria.sha256 .loop/gate-count .loop/armwarn

# --- red-check kill switch: LOOP_ENG_ARM_REDCHECK=0 executes ZERO criterion commands ---
# The criterion is green (touch exits 0) AND has an observable side effect: with
# the red-check disabled it must neither warn nor leave the marker behind.
rm -f .loop/criteria.tsv .loop/criteria.sha256 .loop/active .loop/gate-count
printf 'green\tside-effect probe\ttouch redcheck-ran.marker\n' > .loop/criteria.tsv
LOOP_ENG_ARM_REDCHECK=0 bash "$ARM" 2>.loop/armwarn; assert_eq 0 $? "arm with red-check disabled still exits 0"
assert_eq "1" "$([ -f .loop/active ] && echo 1)" "disabled red-check still creates .loop/active"
assert_eq "" "$(grep -F 'already green' .loop/armwarn)" "disabled red-check emits no already-green warning"
assert_eq "" "$([ -f redcheck-ran.marker ] && echo 1)" "disabled red-check runs ZERO criterion commands (no marker)"
rm -f .loop/active .loop/criteria.sha256 .loop/gate-count .loop/armwarn redcheck-ran.marker

# --- red-check timeout: a slow criterion is UNKNOWN (timeout exit 124), not green ---
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  rm -f .loop/criteria.tsv .loop/criteria.sha256 .loop/active .loop/gate-count
  printf 'slow\toverruns the budget\tsleep 2\n' > .loop/criteria.tsv
  LOOP_ENG_ARM_REDCHECK_TIMEOUT=1 bash "$ARM" 2>.loop/armwarn; assert_eq 0 $? "arm with a timed-out criterion still exits 0"
  assert_eq "1" "$([ -f .loop/active ] && echo 1)" "timed-out red-check still creates .loop/active"
  assert_eq "" "$(grep -F 'already green' .loop/armwarn)" "timed-out criterion does not warn already-green"
  rm -f .loop/active .loop/criteria.sha256 .loop/gate-count .loop/armwarn
else
  echo "  SKIP: no timeout(1)/gtimeout — cannot exercise the red-check timeout" >&2
fi

# --- no criteria.tsv: arms without a hash-lock, does not error ---
rm -f .loop/criteria.tsv .loop/criteria.sha256 .loop/active
bash "$ARM" 2>/dev/null; assert_eq 0 $? "arm with no criteria.tsv still exits 0"
assert_eq "1" "$([ -f .loop/active ] && echo 1)" "arm still creates .loop/active without criteria"
assert_eq "" "$([ -f .loop/criteria.sha256 ] && echo 1)" "arm writes no hash-lock without criteria"

# --- provenance line: arm reports the path it was invoked as (cache-vs-repo
#     divergence guard). The armed-from path must be the exact $ARM path. ---
rm -f .loop/criteria.tsv .loop/criteria.sha256 .loop/active .loop/gate-count
bash "$ARM" 2>.loop/armwarn
assert_file_contains .loop/armwarn 'armed from' "arm prints the provenance (armed-from) line"
assert_file_contains .loop/armwarn "$ARM" "provenance line names the exact invoked script path"
rm -f .loop/active .loop/armwarn

report "test-arm-contract"
