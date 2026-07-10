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

# --- no criteria.tsv: arms without a hash-lock, does not error ---
rm -f .loop/criteria.tsv .loop/criteria.sha256 .loop/active
bash "$ARM" 2>/dev/null; assert_eq 0 $? "arm with no criteria.tsv still exits 0"
assert_eq "1" "$([ -f .loop/active ] && echo 1)" "arm still creates .loop/active without criteria"
assert_eq "" "$([ -f .loop/criteria.sha256 ] && echo 1)" "arm writes no hash-lock without criteria"

report "test-arm-contract"
