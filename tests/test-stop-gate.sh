#!/usr/bin/env bash
# stop-gate: criteria.tsv runner path, legacy verify.sh fallback, block ceiling.
set -u
. "$(dirname "$0")/lib.sh"

GATE="$PLUGIN_ROOT/hooks/stop-gate.sh"
SB=$(mk_sandbox_repo); trap 'rm -rf "$SB"' EXIT
cd "$SB" || exit 1
mkdir -p .loop

# LOOP_ENG_GATE_DEDUP_WINDOW=0 turns OFF the same-stop-attempt replay (P2-19) for
# every test that exercises the block COUNTER. Those tests fire the gate several
# times in well under a second, which is exactly the shape the replay exists to
# collapse — with it on, "block 2" and "block 3" would be read as twin
# registrations of one stop attempt and never counted. The replay has its own
# section at the end of this file, where it runs at the default window.
run_gate() { echo '{}' | LOOP_ENG_GATE_DEDUP_WINDOW=0 bash "$GATE" 2>"$1"; }

# File-presence assertions read `"$([ -f x ] && echo 1)"` rather than
# `[ -f x ]; assert_eq 0 $?`. The second form reads $? from a CONDITION, which
# any assertion helper between the two statements would overwrite — shellcheck
# SC2319, and a live trap once the gate is at `-S warning`.

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
# The green path removes THREE files and only the first had a guard: dropping
# "$SHA_LOCK" and "$COUNT_FILE" from that one `rm` left this suite at 33 passed
# / 0 failed. Both leftovers are load-bearing. A stale criteria.sha256 locks a
# contract that no longer exists, so the NEXT loop's arm writes a criteria.tsv
# the old hash does not match and every stop after it exits 77 "tampered"; a
# stale gate-count starts that loop partway to the 3-block ceiling.
#
# Both files must therefore EXIST before the green run. The first attempt at
# these assertions asserted absence over files the setup had already deleted
# (`rm -f .loop/gate-count`) or never armed — they passed against the mutation
# they were written to catch.
printf '1\tgreen\ttrue\n' > .loop/criteria.tsv
echo 2 > .loop/gate-count
touch .loop/active
GREEN_SHA=$(sha_of .loop/criteria.tsv)
if [ -n "$GREEN_SHA" ]; then
  printf '%s\n' "$GREEN_SHA" > .loop/criteria.sha256
else
  echo "  SKIP: no SHA-256 tool — the hash-lock half of the green path is not exercised" >&2
fi
run_gate /dev/null; assert_eq 0 $? "green criteria allows"
assert_eq "" "$([ -f .loop/active ] && echo 1)" "gate lifted (.loop/active removed)"
assert_eq "" "$([ -f .loop/gate-count ] && echo 1)" "green path clears the block counter (next loop starts at 0, not at 2/3)"
if [ -n "$GREEN_SHA" ]; then
  assert_eq "" "$([ -f .loop/criteria.sha256 ] && echo 1)" "green path clears the hash-lock (next loop's arm is not 'tampered')"
fi

# --- timeout: a contract slower than the budget fails CLOSED (blocks) ---
if command -v timeout >/dev/null 2>&1 || command -v gtimeout >/dev/null 2>&1; then
  rm -f .loop/gate-count .loop/results.json
  printf '1\tslow\tsleep 5\n' > .loop/criteria.tsv
  touch .loop/active
  echo '{}' | LOOP_ENG_GATE_DEDUP_WINDOW=0 LOOP_ENG_GATE_TIMEOUT=1 bash "$GATE" 2>.loop/errT; assert_eq 2 $? "slow contract fails closed (blocks)"
  assert_file_contains .loop/errT 'did not finish within' "timeout block names the budget overrun"
  assert_eq 1 "$([ -f .loop/active ] && echo 1)" "timeout block does NOT lift the gate"
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
echo '{}' | LOOP_ENG_GATE_DEDUP_WINDOW=0 LOOP_ENG_GATE_TIMEOUT=0 bash "$GATE" 2>.loop/err0 >/dev/null
assert_eq 2 $? "GATE_TIMEOUT=0 still blocks a red contract"
assert_file_contains .loop/err0 'would disable' "GATE_TIMEOUT=0 warns that 0 removes the fail-closed budget"
rm -f .loop/gate-count
echo '{}' | LOOP_ENG_GATE_DEDUP_WINDOW=0 LOOP_ENG_GATE_TIMEOUT=00 bash "$GATE" 2>.loop/err00 >/dev/null
assert_file_contains .loop/err00 'would disable' "GATE_TIMEOUT=00 (leading zero) hits the same guard"
rm -f .loop/gate-count
echo '{}' | LOOP_ENG_GATE_DEDUP_WINDOW=0 LOOP_ENG_GATE_TIMEOUT=100 bash "$GATE" 2>.loop/errOK >/dev/null
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
echo '{}' | LOOP_ENG_GATE_DEDUP_WINDOW=0 bash lonelyhooks/stop-gate.sh 2>.loop/errD
assert_eq 2 $? "criteria present but runner missing BLOCKS the stop"
assert_file_contains .loop/errD 'BLOCKED' "missing-runner block reason on stderr"
assert_file_contains .loop/errD 'run-contract.sh' "missing-runner reason names the path it looked for"
assert_eq "" "$(grep -c 'no criteria.tsv' .loop/errD 2>/dev/null | grep -v '^0$')" "missing-runner reason does not claim criteria.tsv is absent"
# bounded by the same ceiling, so a broken install cannot deadlock a session
echo '{}' | LOOP_ENG_GATE_DEDUP_WINDOW=0 bash lonelyhooks/stop-gate.sh 2>/dev/null; assert_eq 2 $? "missing-runner block 2"
echo '{}' | LOOP_ENG_GATE_DEDUP_WINDOW=0 bash lonelyhooks/stop-gate.sh 2>/dev/null; assert_eq 2 $? "missing-runner block 3"
echo '{}' | LOOP_ENG_GATE_DEDUP_WINDOW=0 bash lonelyhooks/stop-gate.sh 2>.loop/errE; assert_eq 0 $? "missing-runner respects the block ceiling"
assert_file_contains .loop/errE 'ceiling' "ceiling notice ends the missing-runner blocks"
rm -rf lonelyhooks; rm -f .loop/active .loop/gate-count .loop/errD .loop/errE

# --- P2-19: the SAME stop attempt must cost ONE block, however many times the
#     hook is registered. ---
# A project that registers this Stop hook in its own .claude/settings.json while
# loop-eng is also installed as a plugin gets the gate fired twice per stop
# attempt — serially, which is why the counter went up by 2. MAX_BLOCKS=3 then
# arrives after the SECOND attempt instead of the third, and the ceiling's
# allow is immediately re-blocked by its own twin (the ceiling clears
# gate-count, so the twin reads 0, re-runs the red contract and exits 2) — so
# under double registration the ceiling never actually released. README:204-208
# described the "~1–2 blocks" half of this; the never-releasing half was not
# described anywhere.
#
# The fix keys on the only thing that distinguishes the twin from a genuine next
# attempt: a genuine one needs a model turn, the twin follows within
# milliseconds. .loop/gate-last records <epoch> <verdict> and a second
# invocation inside LOOP_ENG_GATE_DEDUP_WINDOW seconds replays that verdict
# without re-running the contract and without counting.
rm -rf .loop; mkdir -p .loop
printf '1\tred\tfalse\n' > .loop/criteria.tsv
touch .loop/active
echo '{}' | bash "$GATE" 2>/dev/null; assert_eq 2 $? "twin registration: first invocation blocks"
assert_eq "1" "$(cat .loop/gate-count 2>/dev/null)" "twin registration: first invocation counts one block"
echo '{}' | bash "$GATE" 2>.loop/errDup; assert_eq 2 $? "twin registration: second invocation still blocks"
assert_eq "1" "$(cat .loop/gate-count 2>/dev/null)" "twin registration: second invocation does not double-count"
assert_file_contains .loop/errDup 'same stop attempt' "twin registration: the replay says what it is"
assert_eq 1 "$([ -f .loop/active ] && echo 1)" "twin registration: the replayed block does not lift the gate"

# An EXPIRED marker is not a stop attempt's twin — the next genuine attempt must
# count. Written by hand rather than slept for: the window is the unit under
# test, not the clock.
printf '%s block\n' "$(( $(date +%s) - 600 ))" > .loop/gate-last
echo '{}' | bash "$GATE" 2>/dev/null; assert_eq 2 $? "expired marker: the next genuine attempt blocks"
assert_eq "2" "$(cat .loop/gate-count 2>/dev/null)" "expired marker: the next genuine attempt counts"

# Garbage and future timestamps are ignored, not trusted. A marker dated in the
# FUTURE would otherwise suppress every block until that time arrives — the one
# shape that turns this optimisation into a disarm.
printf 'not-a-timestamp block\n' > .loop/gate-last
echo '{}' | bash "$GATE" 2>/dev/null; assert_eq 2 $? "garbage marker: gate still blocks"
assert_eq "3" "$(cat .loop/gate-count 2>/dev/null)" "garbage marker is ignored, not honoured"
rm -f .loop/gate-count
printf '%s block\n' "$(( $(date +%s) + 3600 ))" > .loop/gate-last
echo '{}' | bash "$GATE" 2>/dev/null; assert_eq 2 $? "future-dated marker: gate still blocks"
assert_eq "1" "$(cat .loop/gate-count 2>/dev/null)" "future-dated marker is ignored, not honoured"

# The ceiling's ALLOW must replay too, or the twin re-blocks the stop the
# ceiling just released and the session can never end.
echo 3 > .loop/gate-count
rm -f .loop/gate-last
echo '{}' | bash "$GATE" 2>/dev/null; assert_eq 0 $? "ceiling allows"
echo '{}' | bash "$GATE" 2>.loop/errDup2; assert_eq 0 $? "twin registration: the ceiling's allow is replayed, not re-blocked"
assert_file_contains .loop/errDup2 'same stop attempt' "ceiling replay says what it is"

# Window 0 disables the replay entirely (the escape hatch the counting tests above use).
rm -f .loop/gate-count .loop/gate-last
echo '{}' | LOOP_ENG_GATE_DEDUP_WINDOW=0 bash "$GATE" 2>/dev/null; assert_eq 2 $? "window 0: blocks"
echo '{}' | LOOP_ENG_GATE_DEDUP_WINDOW=0 bash "$GATE" 2>/dev/null; assert_eq 2 $? "window 0: blocks again"
assert_eq "2" "$(cat .loop/gate-count 2>/dev/null)" "window 0 counts every invocation (replay disabled)"

# A GREEN contract disarms, so the twin finds no .loop/active and allows on its
# own — but the marker must not survive the disarm, or it would be handed to the
# next loop armed in this tree.
rm -f .loop/gate-count .loop/gate-last
printf '1\tgreen\ttrue\n' > .loop/criteria.tsv
echo '{}' | bash "$GATE" 2>/dev/null; assert_eq 0 $? "green contract allows"
assert_eq "" "$([ -f .loop/gate-last ] && echo 1)" "green path clears the dedup marker with the rest of the gate state"

report "test-stop-gate"
