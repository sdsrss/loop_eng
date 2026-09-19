#!/usr/bin/env bash
# run-contract.sh: executes criteria.tsv, machine-writes results.json + evidence.
set -u
. "$(dirname "$0")/lib.sh"

RUNNER="$PLUGIN_ROOT/skills/loop-eng/scripts/run-contract.sh"
SB=$(mk_sandbox_repo); trap 'rm -rf "$SB"' EXIT
cd "$SB"
mkdir -p .loop

# --- all green ---
printf '1\techo works\techo hello-evidence\n2\ttrue passes\ttrue\n' > .loop/criteria.tsv
bash "$RUNNER"; assert_eq 0 $? "all-green exit 0"
assert_file_contains .loop/results.json '"all_green": true' "all_green true"
assert_file_contains .loop/results.json '"id": "1"' "criterion 1 present"
assert_file_contains .loop/evidence/1.log 'hello-evidence' "evidence captures real output"

# --- one red ---
printf '1\tok\ttrue\n2\tfails\tfalse\n' > .loop/criteria.tsv
bash "$RUNNER" 2>/dev/null; assert_eq 1 $? "red contract exit 1"
assert_file_contains .loop/results.json '"all_green": false' "all_green false"
assert_file_contains .loop/results.json '"id": "2", "desc": "fails", "cmd": "false", "exit": 1, "passes": false' "criterion 2 failed with exit code"

# --- a red contract must SAY what failed on stderr, not just exit 1 ---
# Every failure detail used to live ONLY in results.json + evidence/, so a
# consumer that reads the runner's output saw an exit code and nothing else —
# most visibly the stop-gate, whose "Output tail:" block reason (the one signal
# fed back to the model on a blocked stop) was empty on the primary path.
printf 'lint\tstays green\ttrue\ntypecheck\ttsc noEmit clean\tsh -c "echo boom-evidence >&2; exit 3"\n' > .loop/criteria.tsv
bash "$RUNNER" >/dev/null 2>.loop/rc-err; assert_eq 1 $? "red contract exits 1 (stderr-summary case)"
assert_file_contains .loop/rc-err 'typecheck' "stderr summary names the failing criterion id"
assert_file_contains .loop/rc-err 'tsc noEmit clean' "stderr summary names the failing criterion description"
assert_file_contains .loop/rc-err 'exit 3' "stderr summary names the failing exit code"
assert_file_contains .loop/rc-err 'boom-evidence' "stderr summary quotes the failing criterion's evidence"
assert_eq 0 "$(grep -c 'stays green' .loop/rc-err)" "stderr summary lists only failures, not passing criteria"
# a green contract stays quiet — the summary must not become noise on success
printf 'lint\tstays green\ttrue\n' > .loop/criteria.tsv
bash "$RUNNER" >/dev/null 2>.loop/rc-err-green; assert_eq 0 $? "green contract exits 0"
assert_eq 0 "$(wc -c < .loop/rc-err-green | tr -d ' ')" "green contract writes nothing to stderr"
rm -f .loop/rc-err .loop/rc-err-green

# --- the summary must fit the stop-gate's 40-line feedback window ---
# The gate tails our stderr into the block reason. At 3 evidence lines per red
# criterion a 10-failure contract produced 41 lines, so `tail -40` dropped the
# "N of M criteria FAILED" header. Evidence degrades to 1 line per criterion
# past the 8th, bounding the worst case at 1 + 4*min(N,8) + 2*max(N-8,0).
: > .loop/criteria.tsv
i=1
while [ "$i" -le 10 ]; do
  printf 'c%s\tdesc %s\tsh -c "echo L1 >&2; echo L2 >&2; echo L3 >&2; exit 1"\n' "$i" "$i" >> .loop/criteria.tsv
  i=$((i + 1))
done
bash "$RUNNER" >/dev/null 2>.loop/rc-many
many_lines=$(wc -l < .loop/rc-many | tr -d ' ')
if [ "$many_lines" -le 40 ]; then
  assert_eq 0 0 "10-failure summary fits the gate's 40-line window ($many_lines lines)"
else
  assert_eq "<=40" "$many_lines" "10-failure summary fits the gate's 40-line window"
fi
assert_eq 1 "$(grep -c 'criteria FAILED' .loop/rc-many)" "header survives at 10 failures"
assert_eq 10 "$(grep -c 'FAIL \[' .loop/rc-many)" "every failing criterion is still named"
rm -f .loop/rc-many

# --- comments/blank lines ignored; quotes in desc escaped ---
printf '# comment line\n\n1\tsays "hi"\ttrue\n' > .loop/criteria.tsv
bash "$RUNNER"; assert_eq 0 $? "comments ignored, exit 0"
assert_file_contains .loop/results.json '\"hi\"' "quotes JSON-escaped"

# --- an id containing '/' must not produce a false RED (evidence path sanitized) ---
printf 'lint/eslint\tlint clean\ttrue\n' > .loop/criteria.tsv
bash "$RUNNER"; assert_eq 0 $? "slashed id: passing criterion is GREEN, not a false red"
assert_file_contains .loop/results.json '"id": "lint/eslint"' "slashed id preserved verbatim in JSON"
assert_file_contains .loop/results.json '"passes": true' "slashed id criterion actually ran and passed"

# --- two ids that sanitize to the same filename must not share one evidence log ---
# (pre-fix, 'a/b' and 'a:b' both wrote .loop/evidence/a_b.log: results.json cited
# the same path twice and the first criterion's evidence was silently overwritten)
printf 'a/b\tfirst collider\techo first-evidence\na:b\tsecond collider\techo second-evidence\n' > .loop/criteria.tsv
bash "$RUNNER"; assert_eq 0 $? "colliding ids: contract still exits 0"
assert_file_contains .loop/evidence/a_b.log 'first-evidence' "first collider keeps its own evidence log"
assert_file_contains .loop/evidence/a_b.2.log 'second-evidence' "second collider gets a suffixed evidence log"
assert_file_contains .loop/results.json 'a_b.2.log' "results.json cites the suffixed evidence path"

# --- vacuous contract (zero runnable criteria) fails CLOSED, never a false green ---
printf '# only comments\n\n' > .loop/criteria.tsv
bash "$RUNNER" 2>.loop/rc-err-vac; assert_eq 1 $? "all-comment criteria fails closed, exit 1"
assert_file_contains .loop/rc-err-vac 'no runnable criteria' "vacuous contract explains itself on stderr, not only in results.json"
rm -f .loop/rc-err-vac
assert_file_contains .loop/results.json '"all_green": false' "vacuous contract not green"
assert_file_contains .loop/results.json 'no runnable criteria' "vacuous contract reason recorded"
: > .loop/criteria.tsv   # truly empty file
bash "$RUNNER" 2>/dev/null; assert_eq 1 $? "empty criteria fails closed, exit 1"
assert_file_contains .loop/results.json '"all_green": false' "empty contract not green"

# --- PARTIALLY parsed contract fails CLOSED too. The vacuous guard above only
#     fires at ZERO runnable criteria; between 1 and N-1 a criterion line that
#     misses the TSV shape (the classic slip: spaces where TABs belong, which
#     parses the whole line into $id) used to be skipped in SILENCE — so a
#     contract could report all_green over fewer criteria than its author wrote,
#     and the dropped one is exactly the one nobody is watching. ---
rm -f .loop/results.json
{ printf 'lint\tsyntax ok\ttrue\n'
  printf 'smoke must print world false\n'     # spaces, not TABs -> whole line is $id
  printf 'types\ttypecheck\ttrue\n'; } > .loop/criteria.tsv
bash "$RUNNER" 2>.loop/rc-err-partial; assert_eq 1 $? "partially parsed contract fails closed, exit 1"
assert_file_contains .loop/results.json '"all_green": false' "dropped criterion line is never a green contract"
assert_file_contains .loop/rc-err-partial 'malformed' "stderr says the contract was only partly parsed"
assert_file_contains .loop/rc-err-partial 'line(s): 2' "stderr names the offending line number"
# the well-formed criteria still run: the ledger stays informative, it just
# cannot be green while a line the author wrote is unaccounted for
assert_file_contains .loop/results.json '"id": "lint"' "well-formed criteria before the bad line still run"
assert_file_contains .loop/results.json '"id": "types"' "well-formed criteria after the bad line still run"
assert_file_contains .loop/results.json '"malformed_lines": "2"' "ledger records which line was unparseable"
# a partly parsed contract's id set is incomplete, so it must NOT prune: the
# dropped line's evidence would look stale and be deleted on the very run that
# is telling the author their contract is wrong
printf 'evidence from the line that stopped parsing\n' > .loop/evidence/smoke.log
bash "$RUNNER" 2>/dev/null; assert_eq 1 $? "partly parsed contract stays red on re-run"
assert_eq 1 "$([ -f .loop/evidence/smoke.log ] && echo 1)" "partly parsed run does NOT prune evidence"
rm -f .loop/rc-err-partial .loop/evidence/smoke.log

# --- ...and zero false positives on the shapes the parser legitimately skips.
#     A warning that fires on correct input is a warning people learn to ignore. ---
{ printf '# a leading comment\n'
  printf '\n'
  printf '   \n'                              # whitespace-only line
  printf '  # an indented comment\n'
  printf 'ok\tstill fine\ttrue\n'; } > .loop/criteria.tsv
bash "$RUNNER" 2>.loop/rc-err-clean; assert_eq 0 $? "comments/blank/whitespace-only lines keep a good contract green"
assert_eq "" "$(grep -c malformed .loop/rc-err-clean 2>/dev/null | grep -v '^0$')" "no malformed warning on comment/blank/whitespace lines"
rm -f .loop/rc-err-clean

# --- a TAB inside a field (4+ column line / CRLF) must not break JSON validity ---
printf '1\tgrep tab\tprintf "a\\tb"\ttrue\n' > .loop/criteria.tsv  # 4 columns -> cmd absorbs a raw TAB
bash "$RUNNER" >/dev/null 2>&1
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import json;json.load(open('.loop/results.json'))" 2>/dev/null
  assert_eq 0 $? "results.json stays valid JSON when a field contains a TAB"
fi
assert_file_contains .loop/results.json '\\t' "TAB in field escaped as \\t"
# a raw C0 control byte (ESC) in a field must also keep results.json valid JSON
printf '1\tesc %b here\ttrue\n' 'x\x1by' > .loop/criteria.tsv
bash "$RUNNER" >/dev/null 2>&1
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import json;json.load(open('.loop/results.json'))" 2>/dev/null
  assert_eq 0 $? "results.json stays valid JSON when a field contains a raw C0 control byte"
fi

# --- stdin-reading criterion must not swallow later criteria lines ---
printf '1\treads stdin\tcat\n2\tstill runs\techo second-ran\n' > .loop/criteria.tsv
bash "$RUNNER"; assert_eq 0 $? "stdin-reading criterion exits 0"
assert_file_contains .loop/results.json '"id": "2"' "criterion after stdin-reader still executed"
assert_file_contains .loop/evidence/2.log 'second-ran' "later criterion produced evidence"

# --- last criterion with NO trailing newline must NOT be silently dropped (#1) ---
printf '1\tok\ttrue\n2\tmust-fail\tfalse' > .loop/criteria.tsv   # no final newline
bash "$RUNNER" 2>/dev/null; assert_eq 1 $? "no-trailing-newline: failing last criterion caught (exit 1)"
assert_file_contains .loop/results.json '"id": "2"' "no-trailing-newline: last criterion present"
assert_file_contains .loop/results.json '"all_green": false' "no-trailing-newline: not a false green"

# --- CRLF-authored criteria.tsv: the trailing CR belongs to the line ending, not
#     the command. It must be stripped before `bash -c`, or every criterion runs a
#     command with a trailing CR ("true\r" -> command not found, exit 127) and a
#     PASSING check reports a false RED, so the loop can never reach ALL GREEN. ---
printf '1\tok\ttrue\r\n2\talso ok\ttrue\r\n' > .loop/criteria.tsv   # CRLF line endings
bash "$RUNNER"; assert_eq 0 $? "CRLF line endings: passing criteria go GREEN, not false-red"
assert_file_contains .loop/results.json '"all_green": true' "CRLF: passing contract is green"

# --- hash-lock: armed + matching hash runs the contract normally ---
printf '1\tok\ttrue\n' > .loop/criteria.tsv
: > .loop/active
sha_of .loop/criteria.tsv > .loop/criteria.sha256
bash "$RUNNER"; assert_eq 0 $? "hash-lock: matching hash runs, exit 0"
assert_file_contains .loop/results.json '"all_green": true' "hash-lock: matching hash all_green true"

# --- hash-lock: criteria.tsv altered after arm -> fail CLOSED, never runs ---
printf '1\tok\ttrue\n9\tsmuggled\ttrue\n' > .loop/criteria.tsv   # both pass, so a RUN would be green
bash "$RUNNER" 2>/dev/null; assert_eq 77 $? "hash-lock: tampered criteria fails closed, exit 77"
assert_file_contains .loop/results.json '"all_green": false' "hash-lock: tampered not green"
assert_file_contains .loop/results.json 'tampered' "hash-lock: tamper reason recorded"

# --- hash-lock inert when the loop is not armed (no .loop/active) ---
rm -f .loop/active
bash "$RUNNER"; assert_eq 0 $? "hash-lock: not armed -> hash ignored, runs normally"
rm -f .loop/criteria.sha256

# --- hash-lock present but NO SHA-256 tool on PATH: integrity unverifiable -> fail CLOSED ---
# (armed + a stale criteria.sha256 on disk, but sha256sum/shasum/openssl all
# missing: run-contract must refuse to execute the contract rather than skip
# the integrity check. Forced with a minimal fake PATH holding only the tools
# this code path needs — same PATH-stripping technique as test-evidence-gate.sh.)
printf '1\tok\ttrue\n' > .loop/criteria.tsv
: > .loop/active
printf 'deadbeef-stale-hash\n' > .loop/criteria.sha256
FAKEBIN="$SB/fakebin-run"; mkdir -p "$FAKEBIN"
for t in bash mkdir cut mv rm; do
  src=$(command -v "$t") && ln -sf "$src" "$FAKEBIN/$t"
done
if env PATH="$FAKEBIN" bash -c 'command -v sha256sum || command -v shasum || command -v openssl' >/dev/null 2>&1; then
  echo "  SKIP: could not hide every SHA-256 tool from PATH" >&2
else
  env PATH="$FAKEBIN" bash "$RUNNER" 2>/dev/null
  assert_eq 77 $? "no SHA-256 tool with a hash-lock present: fail closed, exit 77"
  assert_file_contains .loop/results.json '"all_green": false' "no SHA-256 tool: results.json not green"
  assert_file_contains .loop/results.json 'integrity could not be verified' "no SHA-256 tool: fail-closed reason recorded"
fi
rm -rf "$FAKEBIN"
rm -f .loop/active .loop/criteria.sha256 .loop/results.json

# --- LOOP_ENG_LOOP_DIR: the sandbox knob redirects EVERY loop path ---
# (the scripts' comments call this the suite's sandboxing knob — this is the
# test that makes that claim true. Assert both the custom-dir writes AND that
# the default .loop/ artifacts stay untouched.)
rm -rf customdir .loop/evidence
rm -f .loop/results.json .loop/active .loop/criteria.sha256
mkdir -p customdir
printf 'c1\tcustom-dir criterion\techo custom-evidence\n' > customdir/criteria.tsv
LOOP_ENG_LOOP_DIR=customdir bash "$RUNNER"; assert_eq 0 $? "LOOP_ENG_LOOP_DIR: contract runs green"
assert_file_contains customdir/results.json '"all_green": true' "LOOP_ENG_LOOP_DIR: results.json written in the custom dir"
assert_file_contains customdir/evidence/c1.log 'custom-evidence' "LOOP_ENG_LOOP_DIR: evidence written in the custom dir"
assert_eq "" "$([ -f .loop/results.json ] && echo 1)" "LOOP_ENG_LOOP_DIR: default .loop/results.json NOT written"
assert_eq "" "$([ -d .loop/evidence ] && echo 1)" "LOOP_ENG_LOOP_DIR: default .loop/evidence NOT created"
rm -rf customdir

# --- stale evidence pruning: a log from a PRIOR criteria set is removed, while the
#     CURRENT criteria's evidence logs survive. A repo cycling through many
#     contracts (different criterion ids) otherwise accumulates stale evidence
#     logs forever. ---
rm -rf .loop/evidence; rm -f .loop/results.json .loop/active .loop/criteria.sha256
printf '1\tok\ttrue\n2\talso ok\ttrue\n' > .loop/criteria.tsv
bash "$RUNNER"; assert_eq 0 $? "stale evidence: initial run with ids {1,2} exits 0"
printf 'from a criterion that no longer exists\n' > .loop/evidence/oldcriterion.log
bash "$RUNNER"; assert_eq 0 $? "stale evidence: re-run with ids {1,2} exits 0"
assert_eq "" "$([ -f .loop/evidence/oldcriterion.log ] && echo 1)" "stale evidence log from a prior criteria set is pruned"
assert_eq 1 "$([ -f .loop/evidence/1.log ] && echo 1)" "stale evidence prune keeps current criterion 1.log"
assert_eq 1 "$([ -f .loop/evidence/2.log ] && echo 1)" "stale evidence prune keeps current criterion 2.log"

# --- prune guard: a fail-closed run does NOT prune. On a hash-lock mismatch
#     (exit 77) the fail-closed exit happens BEFORE the criteria loop, so pruning
#     never runs and the armed set's evidence — including any stale log — survives. ---
rm -rf .loop/evidence; rm -f .loop/results.json .loop/active .loop/criteria.sha256
printf '1\tok\ttrue\n' > .loop/criteria.tsv
bash "$RUNNER"; assert_eq 0 $? "prune guard: baseline run exits 0 (writes 1.log)"
printf 'stale under the armed set\n' > .loop/evidence/oldcriterion.log
: > .loop/active
printf 'deadbeef-not-the-live-hash\n' > .loop/criteria.sha256
bash "$RUNNER" 2>/dev/null; assert_eq 77 $? "prune guard: hash-lock mismatch fails closed, exit 77"
assert_eq 1 "$([ -f .loop/evidence/oldcriterion.log ] && echo 1)" "fail-closed run does NOT prune: stale evidence preserved on exit 77"
assert_eq 1 "$([ -f .loop/evidence/1.log ] && echo 1)" "fail-closed run does NOT prune: armed criterion evidence preserved"
rm -f .loop/active .loop/criteria.sha256 .loop/results.json
rm -rf .loop/evidence

# --- an unrecordable result must fail closed WITH A REASON, not by accident ---
# Pre-fix, an unwritable .loop/ made the `{ … } > "$TMP"` group's redirect fail,
# so the criteria loop never ran and `ran`/`malformed` were never assigned; the
# script then exited non-zero only because `set -u` tripped over an unbound
# variable three lines later, printing bash internals instead of a cause. Safe —
# but by coincidence: hoisting those initialisations out of the group command (an
# ordinary cleanup) would have turned a full disk into a false ALL GREEN.
# Occupying the evidence path with a FILE reproduces it independently of uid, so
# this assertion also holds in the root-run bash 3.2 container.
rm -rf .loop/evidence; rm -f .loop/results.json
printf '1\tok\ttrue\n' > .loop/criteria.tsv
printf 'not a directory\n' > .loop/evidence
bash "$RUNNER" 2>.loop/rc-err-nowrite; assert_eq 73 $? "unusable evidence dir fails closed, exit 73 (EX_CANTCREAT)"
assert_file_contains .loop/rc-err-nowrite 'cannot write' "the refusal states it could not write, not a bash internal"
assert_eq "" "$(grep -c 'unbound variable' .loop/rc-err-nowrite 2>/dev/null | grep -v '^0$')" "no bash internals leak into the refusal"
rm -f .loop/evidence .loop/rc-err-nowrite

# Same invariant via the other door: a .loop/ the process cannot write at all.
# chmod cannot take write access away from root, so this half is skipped there.
if [ "$(id -u)" -ne 0 ]; then
  rm -rf .loop/evidence; rm -f .loop/results.json
  printf '1\tok\ttrue\n' > .loop/criteria.tsv
  chmod a-w .loop
  bash "$RUNNER" 2>.loop-err-ro; rc=$?
  chmod u+w .loop
  assert_eq 73 "$rc" "unwritable .loop fails closed, exit 73"
  assert_file_contains .loop-err-ro 'cannot write' "read-only .loop refusal states the cause"
  # this is the door that actually leaked bash internals pre-fix
  assert_eq "" "$(grep -c 'unbound variable' .loop-err-ro 2>/dev/null | grep -v '^0$')" "read-only .loop refusal leaks no bash internals"
  # ...and the probe's own redirect must not leak one either (it does unless
  # 2>/dev/null precedes the probe redirect — see the note in run-contract.sh)
  assert_eq "" "$(grep -c 'run-contract.sh: line' .loop-err-ro 2>/dev/null | grep -v '^0$')" "the writability probe leaks no raw bash redirect error"
  rm -f .loop-err-ro
fi
rm -rf .loop/evidence; rm -f .loop/results.json

# --- missing criteria.tsv ---
rm .loop/criteria.tsv
bash "$RUNNER" 2>/dev/null; assert_eq 78 $? "missing criteria exit 78"

report "test-run-contract"
