#!/usr/bin/env bash
# stop-gate: criteria.tsv runner path, legacy verify.sh fallback, block ceiling.
set -u
. "$(dirname "$0")/lib.sh"

GATE="$PLUGIN_ROOT/hooks/stop-gate.sh"
SB=$(mk_sandbox_repo); trap 'rm -rf "$SB"' EXIT
cd "$SB"
mkdir -p .loop

run_gate() { echo '{}' | bash "$GATE" 2>"$1"; }

# --- no active marker -> allow ---
run_gate /dev/null; assert_eq 0 $? "no marker allows stop"

# --- criteria path, red contract: blocks, writes results.json ---
printf '1\tred\tfalse\n' > .loop/criteria.tsv
touch .loop/active
run_gate .loop/err1; assert_eq 2 $? "red criteria blocks stop"
assert_file_contains .loop/results.json '"all_green": false' "gate refreshed results.json"
assert_file_contains .loop/err1 'BLOCKED' "block reason on stderr"

# --- ceiling: blocks 2 and 3, then 4th attempt allows ---
run_gate /dev/null; assert_eq 2 $? "block 2"
run_gate /dev/null; assert_eq 2 $? "block 3"
run_gate .loop/err4; assert_eq 0 $? "4th attempt allows (ceiling)"
assert_file_contains .loop/err4 'ceiling' "ceiling message on stderr"
assert_file_contains .loop/err4 'rm .loop/active' "ceiling message gives the manual disarm command (audit M5)"

# --- green criteria: allows and lifts the gate ---
rm -f .loop/gate-count; touch .loop/active
printf '1\tgreen\ttrue\n' > .loop/criteria.tsv
run_gate /dev/null; assert_eq 0 $? "green criteria allows"
[ ! -f .loop/active ]; assert_eq 0 $? "gate lifted (.loop/active removed)"

# --- timeout: a contract slower than the budget fails CLOSED (blocks) ---
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  rm -f .loop/gate-count .loop/results.json
  printf '1\tslow\tsleep 5\n' > .loop/criteria.tsv
  touch .loop/active
  echo '{}' | LOOP_ENG_GATE_TIMEOUT=1 bash "$GATE" 2>.loop/errT; assert_eq 2 $? "slow contract fails closed (blocks)"
  assert_file_contains .loop/errT 'did not finish within' "timeout block names the budget overrun"
  [ -f .loop/active ]; assert_eq 0 $? "timeout block does NOT lift the gate"
  rm -f .loop/active .loop/gate-count
else
  echo "  SKIP: no timeout(1)/gtimeout — cannot exercise fail-closed timeout" >&2
fi

# --- legacy verify.sh fallback (no criteria.tsv) ---
rm -f .loop/criteria.tsv .loop/results.json
printf '#!/usr/bin/env bash\nexit 1\n' > .loop/verify.sh
touch .loop/active
run_gate /dev/null; assert_eq 2 $? "legacy verify.sh still blocks"
rm -f .loop/active .loop/gate-count

# --- armed but contract-less: active marker, NO criteria.tsv, NO verify.sh ---
# Reachable in production (arm-contract.sh arms even without criteria.tsv);
# falling through to a block here would deadlock a legitimately armed loop.
rm -f .loop/criteria.tsv .loop/verify.sh .loop/results.json .loop/gate-count
touch .loop/active
run_gate .loop/errC; assert_eq 0 $? "armed without contract allows stop"
assert_file_contains .loop/errC 'allowing stop' "contract-less allow notice on stderr"
rm -f .loop/active

report "test-stop-gate"
