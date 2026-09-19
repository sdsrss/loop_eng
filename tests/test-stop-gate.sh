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

# --- the block reason must name WHICH criterion failed ---
# exit 2 feeds this stderr back to the model as the sole in-band reason; an
# "Output tail:" with nothing under it tells it the contract is unsatisfied but
# not what to fix (run-contract writes its detail to results.json + evidence/).
rm -f .loop/gate-count
printf 'typecheck\ttsc noEmit clean\tsh -c "echo boom-evidence >&2; exit 3"\n' > .loop/criteria.tsv
touch .loop/active
run_gate .loop/err1b; assert_eq 2 $? "red criteria blocks stop (named-criterion case)"
assert_file_contains .loop/err1b 'typecheck' "block reason names the failing criterion id"
assert_file_contains .loop/err1b 'tsc noEmit clean' "block reason names the failing criterion description"
assert_file_contains .loop/err1b 'boom-evidence' "block reason carries the failing criterion's evidence"
rm -f .loop/gate-count
printf '1\tred\tfalse\n' > .loop/criteria.tsv
touch .loop/active
run_gate /dev/null   # restore "one block recorded" so the ceiling test below still counts 1->3

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

# --- LOOP_ENG_GATE_TIMEOUT=0 must not silently DISABLE the fail-closed budget ---
# "0" passes the digits-only check, and GNU `timeout 0` means NO limit — so the
# guard that exists to block deliberately before the platform kills an
# overrunning Stop hook (a killed Stop hook does not reliably block) was simply
# gone. arm-contract.sh and both unattended runners already reject 0 for exactly
# this reason; the gate was the one that let it through.
rm -f .loop/gate-count .loop/results.json
printf '1\tred\tfalse\n' > .loop/criteria.tsv
touch .loop/active
echo '{}' | LOOP_ENG_GATE_TIMEOUT=0 bash "$GATE" 2>.loop/err0 >/dev/null
assert_eq 2 $? "GATE_TIMEOUT=0 still blocks a red contract"
assert_file_contains .loop/err0 'would disable' "GATE_TIMEOUT=0 warns that 0 removes the fail-closed budget"
rm -f .loop/gate-count
echo '{}' | LOOP_ENG_GATE_TIMEOUT=00 bash "$GATE" 2>.loop/err00 >/dev/null
assert_file_contains .loop/err00 'would disable' "GATE_TIMEOUT=00 (leading zero) hits the same guard"
rm -f .loop/gate-count
echo '{}' | LOOP_ENG_GATE_TIMEOUT=100 bash "$GATE" 2>.loop/errOK >/dev/null
if grep -q 'would disable' .loop/errOK; then
  assert_eq "quiet" "warned" "a valid GATE_TIMEOUT does not warn"
else
  assert_eq 0 0 "a valid GATE_TIMEOUT does not warn"
fi
rm -f .loop/active .loop/gate-count

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

# --- criteria.tsv present but the RUNNER missing must BLOCK, not allow ---
# Distinct from the contract-less case above: here a contract exists and we
# simply cannot execute it. Pre-fix both landed in the same branch, so a RED
# contract was allowed to stop under the notice "no criteria.tsv or verify.sh"
# — about a file sitting right there. Reachable from an interrupted /plugin
# update, or the README's manual settings.json registration when <plugin-root>
# resolves somewhere the skills/ tree isn't.
rm -f .loop/results.json .loop/gate-count .loop/verify.sh
mkdir -p lonelyhooks
cp "$GATE" lonelyhooks/stop-gate.sh   # no sibling ../skills/loop-eng/scripts/
printf '1\tred\tfalse\n' > .loop/criteria.tsv
touch .loop/active
echo '{}' | bash lonelyhooks/stop-gate.sh 2>.loop/errD
assert_eq 2 $? "criteria present but runner missing BLOCKS the stop"
assert_file_contains .loop/errD 'BLOCKED' "missing-runner block reason on stderr"
assert_file_contains .loop/errD 'run-contract.sh' "missing-runner reason names the path it looked for"
assert_eq "" "$(grep -c 'no criteria.tsv' .loop/errD 2>/dev/null | grep -v '^0$')" "missing-runner reason does not claim criteria.tsv is absent"
# bounded by the same ceiling, so a broken install cannot deadlock a session
echo '{}' | bash lonelyhooks/stop-gate.sh 2>/dev/null; assert_eq 2 $? "missing-runner block 2"
echo '{}' | bash lonelyhooks/stop-gate.sh 2>/dev/null; assert_eq 2 $? "missing-runner block 3"
echo '{}' | bash lonelyhooks/stop-gate.sh 2>.loop/errE; assert_eq 0 $? "missing-runner respects the block ceiling"
assert_file_contains .loop/errE 'ceiling' "ceiling notice ends the missing-runner blocks"
rm -rf lonelyhooks; rm -f .loop/active .loop/gate-count .loop/errD .loop/errE

report "test-stop-gate"
