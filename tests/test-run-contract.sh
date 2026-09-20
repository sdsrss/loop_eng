#!/usr/bin/env bash
# run-contract.sh: executes criteria.tsv, machine-writes results.json + evidence.
set -u
. "$(dirname "$0")/lib.sh"

RUNNER="$PLUGIN_ROOT/skills/loop-eng/scripts/run-contract.sh"
SB=$(mk_sandbox_repo); trap 'rm -rf "$SB"' EXIT
cd "$SB" || exit 1
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

# --- UTF-8 BOM on the first line: the same class as CRLF and handled the same
#     way. An editor that writes a BOM puts EF BB BF before the first id, so the
#     id becomes "﻿check" — the ledger reports an id nobody authored and the
#     evidence log lands at .loop/evidence/_check.log (the sanitizer maps the
#     three non-ASCII bytes to underscores). Nothing FAILS, which is why it
#     survived: the contract still goes green and the mismatch only surfaces when
#     a human or a stop rule goes looking for a criterion by name. Strip it on
#     line 1 only, where a BOM can legally appear. ---
printf '\xef\xbb\xbfcheck\tbom first line\ttrue\nsecond\tplain\ttrue\n' > .loop/criteria.tsv
bash "$RUNNER"; assert_eq 0 $? "BOM-prefixed criteria.tsv still runs green"
assert_file_contains .loop/results.json '"id": "check"' "BOM stripped from the first criterion id"
assert_eq 0 "$(LC_ALL=C grep -c $'\xef\xbb\xbf' .loop/results.json)" "no BOM bytes survive into the ledger"
assert_eq "true" "$([ -f .loop/evidence/check.log ] && echo true)" "evidence log named by the clean id"

# --- a criterion that rewrites criteria.tsv MID-RUN cannot delete its siblings ---
# The loop used to stream the live file, so a criterion that truncated
# criteria.tsv made every line after it vanish at EOF — silently. Not "skipped",
# not "malformed": absent. The vacuous and partial-parse guards below cannot see
# it either, because from their side the contract simply WAS one line. Verified
# pre-fix: exit 0 with only "one" in the ledger and "all_green": true, while the
# authored contract's second criterion was `false`.
rm -f .loop/active .loop/criteria.sha256 .loop/results.json
printf 'one\ttruncates the contract\t: > .loop/criteria.tsv; true\ntwo\tred\tfalse\n' > .loop/criteria.tsv
bash "$RUNNER" >/dev/null 2>&1; assert_eq 1 $? "a criterion truncating criteria.tsv cannot hide the RED criterion after it"
assert_file_contains .loop/results.json '"all_green": false' "truncating criterion: contract is red, not vacuously green"
assert_file_contains .loop/results.json '"id": "two"' "truncating criterion: the criterion after it still appears in the ledger"

# ...and the mirror image: a criterion that APPENDS to criteria.tsv does not get
# its new line executed by this run. The executed set is the snapshot taken
# before the first command, which is also the set the hash-lock verified — a
# contract that could grow mid-run would report on criteria nothing checked.
printf 'one\tappends\tprintf "smuggled\\tadded mid-run\\ttrue\\n" >> .loop/criteria.tsv\n' > .loop/criteria.tsv
bash "$RUNNER" >/dev/null 2>&1; assert_eq 0 $? "a criterion appending to criteria.tsv still exits on its own result"
# grep for the ID FIELD, not the bare word: the appending criterion's own `cmd`
# is recorded in the ledger and contains "smuggled", so a bare-word count is 1
# even when the fix works.
assert_eq 0 "$(grep -c '"id": "smuggled"' .loop/results.json)" "appended criterion is NOT in this run's ledger (executed set is the snapshot)"
# the snapshot is private bookkeeping and must not outlive the run
assert_eq 0 "$(find .loop -maxdepth 1 -name '.criteria.snapshot.*' | wc -l | tr -d ' ')" "the contract snapshot is cleaned up on exit"
rm -f .loop/results.json

# --- empty DESCRIPTION column: three real TAB-separated columns, blank middle ---
# `IFS=$'\t' read -r id desc cmd` COLLAPSES runs of TAB (TAB is IFS whitespace),
# so `id1<TAB><TAB>true` came back as desc="true", cmd="" -> malformed -> fail
# closed, on every stop, with a message blaming SPACES in a file that contains
# only TABs. arm-contract's awk read the same line as three columns and warned
# about nothing, so the contract armed and pinned its hash first; the
# evidence-gate then locked criteria.tsv, leaving a loop that could only end by
# hitting a stop rule. The split is now on the FIRST TWO TABs in both scripts.
rm -f .loop/results.json
printf 'id1\t\ttrue\n' > .loop/criteria.tsv
bash "$RUNNER" 2>.loop/emptydesc.err; assert_eq 0 $? "empty description column runs instead of failing closed"
assert_file_contains .loop/results.json '"id": "id1", "desc": "", "cmd": "true"' "empty description is recorded as empty, and the command is the command"
assert_eq "" "$(grep -c malformed .loop/emptydesc.err 2>/dev/null | grep -v '^0$')" "empty description is not reported malformed"

# ...while the two shapes that really are malformed still are, and the message
# no longer asserts SPACES about a file that may be all TABs.
printf 'smoke must print world true\n' > .loop/criteria.tsv   # spaces, not TABs
bash "$RUNNER" 2>.loop/spaces.err; assert_eq 1 $? "spaces instead of TABs still fails closed"
assert_file_contains .loop/spaces.err 'FIRST TWO TABs' "the malformed message states the actual splitting rule"
assert_file_contains .loop/spaces.err 'EMPTY description is fine' "the malformed message says an empty description is legal"
printf '\tdesc\ttrue\n' > .loop/criteria.tsv                  # leading TAB: no id
bash "$RUNNER" 2>/dev/null; assert_eq 1 $? "empty id column still fails closed (mirror image of empty desc)"
assert_file_contains .loop/results.json '"all_green": false' "empty id: contract is not green"
rm -f .loop/emptydesc.err .loop/spaces.err .loop/results.json

# --- the #comment probe runs on the WHOLE line, BEFORE the TAB split ---
# run-contract used to probe for '#' on $id, i.e. after splitting, while
# arm-contract probes the whole line in both of its parse loops. They therefore
# disagreed on exactly the lines whose INDENT contains a TAB — the same
# arm-says-fine / run-says-malformed divergence the shared parse rule exists to
# end. A TAB-indented comment armed and pinned its hash without a warning, then
# made run-contract call the contract partly parsed: every real criterion green,
# all_green false, exit 1 on EVERY stop attempt, with criteria.tsv already locked
# by the evidence-gate — only a human disarm could clear it.
rm -f .loop/results.json
{ printf 'ok\tstill fine\ttrue\n'
  printf '\t# disabled for now\tsuite passes\tfalse\n'; } > .loop/criteria.tsv
bash "$RUNNER" 2>.loop/tabcomment.err; assert_eq 0 $? "TAB-indented comment is skipped, not malformed"
assert_file_contains .loop/results.json '"all_green": true' "TAB-indented comment: the contract can still go green"
assert_eq "" "$(grep -c malformed .loop/tabcomment.err 2>/dev/null | grep -v '^0$')" "TAB-indented comment raises no malformed warning"
assert_eq 0 "$(grep -c '"id": ""' .loop/results.json)" "TAB-indented comment is not a ledger entry"
# ...and the worse half of the same misplaced probe: a <space><TAB> indent left
# id=" ", which is non-empty, so the line cleared the empty-column guard and the
# commented-out criterion was EXECUTED (its own text as argv[0] of `bash -c`).
rm -f .loop/results.json I-RAN-A-COMMENT
{ printf 'ok\tstill fine\ttrue\n'
  printf ' \t# disabled\ttouch I-RAN-A-COMMENT\n'; } > .loop/criteria.tsv
bash "$RUNNER" 2>.loop/sptab.err; assert_eq 0 $? "space+TAB-indented comment keeps a good contract green"
assert_eq "" "$([ -e I-RAN-A-COMMENT ] && echo ran)" "a commented-out criterion is NEVER executed"
assert_eq 0 "$(grep -c '# disabled' .loop/results.json)" "space+TAB-indented comment is not a ledger entry"
rm -f I-RAN-A-COMMENT
# controls — the comment shapes that already worked must not move, including an
# id that legitimately begins with '#' (already read as a comment today)
rm -f .loop/results.json
{ printf '# unindented\tlooks like\ta criterion\n'
  printf '  # space-indented\tlooks like\ta criterion\n'
  printf 'ok\tstill fine\ttrue\n'; } > .loop/criteria.tsv
bash "$RUNNER" 2>.loop/ctl.err; assert_eq 0 $? "unindented / space-indented comments are still skipped"
assert_eq "" "$(grep -c malformed .loop/ctl.err 2>/dev/null | grep -v '^0$')" "control comments raise no malformed warning"
# ...and a TAB-indented line that is NOT a comment is still the malformed mirror
# image of the spaces slip — the hoist must not turn every indent into a skip
rm -f .loop/results.json
{ printf 'ok\tstill fine\ttrue\n'
  printf '\tsuite passes\tbash tests/run-all.sh\n'; } > .loop/criteria.tsv
bash "$RUNNER" 2>.loop/tabreal.err; assert_eq 1 $? "TAB-indented non-comment still fails closed"
assert_file_contains .loop/tabreal.err 'line(s): 2' "malformed message names the TAB-indented line"
assert_file_contains .loop/tabreal.err 'whose indent starts with a TAB' "malformed message names the indent cause, not only SPACES"
rm -f .loop/tabcomment.err .loop/sptab.err .loop/ctl.err .loop/tabreal.err .loop/results.json

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

# --- hash-lock: a criterion that rewrites the contract DURING the run -> 77 ---
# The pre-run check proves criteria.tsv matched the armed contract when the run
# STARTED. Every criterion then executes with the repo's own privileges, so the
# file can move between that check and the ledger — drift caused BY the run,
# which is the one class the pre-run check structurally cannot see. The snapshot
# decides what ran; this decides whether the result may be reported at all.
rm -f .loop/results.json
printf 'one\trewrites the contract\tprintf "one\\tok\\ttrue\\n" > .loop/criteria.tsv\n' > .loop/criteria.tsv
: > .loop/active
sha_of .loop/criteria.tsv > .loop/criteria.sha256
bash "$RUNNER" >/dev/null 2>.loop/drift.err; assert_eq 77 $? "armed: a criterion rewriting criteria.tsv mid-run fails closed, exit 77"
assert_file_contains .loop/results.json '"all_green": false' "mid-run drift: ledger is not green"
assert_file_contains .loop/results.json 'during the run' "mid-run drift: ledger says the change happened during the run"
assert_file_contains .loop/drift.err 'WHILE the contract ran' "mid-run drift: stderr says when the contract moved"

# ...including when the criterion deletes the LOCK first. Gating the post-run
# check on criteria.sha256 still being present would hand a two-line bypass to
# anything that can run a command: rm the lock, then rewrite the contract.
rm -f .loop/results.json .loop/drift.err
printf 'one\tunlocks then rewrites\trm -f .loop/criteria.sha256; printf "one\\tok\\ttrue\\n" > .loop/criteria.tsv\n' > .loop/criteria.tsv
: > .loop/active
sha_of .loop/criteria.tsv > .loop/criteria.sha256
bash "$RUNNER" >/dev/null 2>&1; assert_eq 77 $? "armed: deleting criteria.sha256 mid-run does not disable the post-run check"
rm -f .loop/active .loop/criteria.sha256 .loop/results.json .loop/drift.err

# a contract that leaves criteria.tsv alone must NOT be reported as drifted —
# the check has to distinguish "the run changed it" from "the run ran".
printf '1\tok\ttrue\n' > .loop/criteria.tsv
: > .loop/active
sha_of .loop/criteria.tsv > .loop/criteria.sha256
bash "$RUNNER"; assert_eq 0 $? "armed: a well-behaved contract still exits 0 (no false drift)"
assert_file_contains .loop/results.json '"all_green": true' "armed: well-behaved contract stays green"
rm -f .loop/active .loop/criteria.sha256 .loop/results.json
printf '1\tok\ttrue\n9\tsmuggled\ttrue\n' > .loop/criteria.tsv   # restore the state the next case inherits

# --- hash-lock present but NO SHA-256 tool on PATH: integrity unverifiable -> fail CLOSED ---
# (armed + a stale criteria.sha256 on disk, but sha256sum/shasum/openssl all
# missing: run-contract must refuse to execute the contract rather than skip
# the integrity check. Forced with a minimal fake PATH holding only the tools
# this code path needs — same PATH-stripping technique as test-evidence-gate.sh.)
printf '1\tok\ttrue\n' > .loop/criteria.tsv
: > .loop/active
printf 'deadbeef-stale-hash\n' > .loop/criteria.sha256
FAKEBIN="$SB/fakebin-run"; mkdir -p "$FAKEBIN"
for t in bash mkdir cut mv rm cp; do
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

# --- armed with NO hash-lock, on a box that HAS a SHA-256 tool ---
# arm-contract removes criteria.sha256 only when no hashing tool was available,
# so a tool being present now leaves the lock's absence unexplained: either the
# arm predates the tool, or the lock was removed afterwards — and in that second
# case every tamper check above was skipped in SILENCE. This must not fail
# closed (a toolchain that changed between arm and run is a legitimate way to
# get here, and failing would strand a real loop whose only exit is deleting
# .loop/active), but it must not be invisible either. Assert both halves: the
# contract still runs, and the fact is on stderr AND in the ledger — the ledger
# because a GREEN contract lets the stop-gate exit 0, which discards our stderr.
rm -rf .loop/evidence; rm -f .loop/results.json
printf '1\tok\ttrue\n' > .loop/criteria.tsv
: > .loop/active
bash "$RUNNER" 2>.loop/nolock.err; assert_eq 0 $? "no hash-lock while armed: contract still RUNS (not fail-closed)"
assert_file_contains .loop/results.json '"contract_lock": "absent"' "no hash-lock while armed: recorded in the ledger"
assert_file_contains .loop/results.json '"all_green": true' "no hash-lock while armed: a green contract is still green"
assert_file_contains .loop/nolock.err 'armed but' "no hash-lock while armed: warned on stderr"

# ...and the field must NOT appear on the ordinary paths, or it is noise that
# teaches readers to ignore it.
sha_of .loop/criteria.tsv > .loop/criteria.sha256
bash "$RUNNER" 2>/dev/null; assert_eq 0 $? "hash-lock present: exit 0"
assert_eq "" "$(grep -c 'contract_lock' .loop/results.json | sed 's/^0$//')" "hash-lock present: no contract_lock field"
rm -f .loop/active .loop/criteria.sha256
bash "$RUNNER" 2>/dev/null; assert_eq 0 $? "not armed: exit 0"
assert_eq "" "$(grep -c 'contract_lock' .loop/results.json | sed 's/^0$//')" "not armed: no contract_lock field"

# The fourth arm of the same branch, and the one that decides whether this is a
# warning or a false alarm: armed, no lock, and NO SHA-256 tool. That is exactly
# what arm-contract leaves behind on a hashless box, so it is the expected state,
# not a missing lock — it must stay silent, or every run on such a box cries wolf.
: > .loop/active
FAKEBIN2="$SB/fakebin-nolock"; mkdir -p "$FAKEBIN2"
# This list is the runner's external-tool contract, not a convenience: anything
# missing here makes the runner fail for the wrong reason and the arm below
# assert nothing. `cp` joined it when the criteria loop started reading a
# snapshot of criteria.tsv instead of the live file.
for t in bash mkdir cut mv rm cp date tail sed printf; do
  src=$(command -v "$t") && ln -sf "$src" "$FAKEBIN2/$t"
done
if env PATH="$FAKEBIN2" bash -c 'command -v sha256sum || command -v shasum || command -v openssl' >/dev/null 2>&1; then
  echo "  SKIP: could not hide every SHA-256 tool from PATH (no-tool arm)" >&2
else
  env PATH="$FAKEBIN2" bash "$RUNNER" 2>.loop/notool.err
  assert_eq 0 $? "armed, no lock, no SHA tool: contract runs"
  assert_eq "" "$(grep -c 'contract_lock' .loop/results.json | sed 's/^0$//')" "armed, no lock, no SHA tool: no contract_lock field (expected state, not drift)"
  assert_eq "" "$(grep -c 'armed but' .loop/notool.err | sed 's/^0$//')" "armed, no lock, no SHA tool: no false warning"
fi
rm -rf "$FAKEBIN2"
rm -f .loop/active .loop/nolock.err .loop/notool.err .loop/results.json

# The route the author missed and the pre-ship reviewer found: commands/autoloop.md
# documents a last-resort arm that is a bare `touch .loop/active` with no
# arm-contract.sh at all. That lands in the same arm as above and SHOULD warn —
# nothing verified the contract — but the first version of the message asserted a
# single cause ("arm-contract only omits the lock when no hashing tool exists")
# and prescribed re-running arm-contract.sh, which on this very path is
# unavailable by definition. A true warning carrying a false sentence.
# Pin the corrected shape: it fires, it names the fallback as an expected route,
# and it does NOT carry the retracted diagnosis.
rm -rf .loop/evidence; rm -f .loop/results.json
printf '1\tok\ttrue\n' > .loop/criteria.tsv
: > .loop/active                      # exactly the documented fallback: no lock is ever written
bash "$RUNNER" 2>.loop/fallback.err; assert_eq 0 $? "documented touch-active fallback: contract still runs"
assert_file_contains .loop/results.json '"contract_lock": "absent"' "documented fallback: recorded in the ledger"
assert_file_contains .loop/fallback.err 'touch .loop/active' "documented fallback: warning names it as an expected route"
assert_eq "" "$(grep -c 'arm-contract only omits' .loop/fallback.err | sed 's/^0$//')" "documented fallback: the retracted single-cause diagnosis is gone"
rm -f .loop/active .loop/fallback.err .loop/results.json

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
else
  # Say so. Silently dropping four fail-closed assertions is how a 93 gets read
  # as a 97 minus platform noise: CLAUDE.md's documented local bash-3.2 recipe
  # runs the container as ROOT, so this block vanished there with no note, and
  # the whole 97-vs-93 delta had no visible cause. CI's macOS test-bash32 leg
  # runs non-root, so real coverage exists — this note is what tells a human
  # reading the local recipe's output that it does not.
  echo "  SKIP: running as root — the chmod-based unwritable-.loop half is not exercised (4 assertions)" >&2
fi
rm -rf .loop/evidence; rm -f .loop/results.json

# --- missing criteria.tsv ---
rm .loop/criteria.tsv
bash "$RUNNER" 2>/dev/null; assert_eq 78 $? "missing criteria exit 78"

# --- P3-12: a backlog box is ticked by a verify command, not by a claim ------
# `.loop/backlog.md` was the last trust boundary left in the completion chain:
# the all-boxes-ticked check read a file the orchestrator writes, so "tick a box
# only after the checker reports ALL GREEN" was a red line honoured rather than
# a fact produced. A line carrying `| verify: <cmd>` opts into the same rule as
# everything else in this runner — the box moves when the command exits 0, and
# never because someone typed it.
rm -f .loop/criteria.tsv .loop/results.json .loop/backlog.md
printf '1\tok\ttrue\n' > .loop/criteria.tsv
{
  printf -- '- [ ] green item | verify: true\n'
  printf -- '- [ ] red item | verify: false\n'
  printf -- '- [ ] plain item with no verify command\n'
  printf -- '- [x] already done | verify: touch should-not-rerun.marker\n'
} > .loop/backlog.md
bash "$RUNNER" >/dev/null 2>&1; assert_eq 0 $? "backlog verification does not change the contract's own verdict"
assert_file_contains .loop/backlog.md '- [x] green item | verify: true' "a passing verify command ticks its box"
assert_file_contains .loop/backlog.md '- [ ] red item | verify: false' "a failing verify command leaves its box unticked"
assert_file_contains .loop/backlog.md '- [ ] plain item with no verify command' "a line with no verify command is left exactly as written"
assert_eq "" "$([ -f should-not-rerun.marker ] && echo 1)" "an already-ticked line's command is not re-run"
assert_file_contains .loop/results.json '"item": "green item", "verify": "true", "exit": 0, "done": true' "the ledger records the tick and what produced it"
assert_file_contains .loop/results.json '"item": "red item", "verify": "false", "exit": 1, "done": false' "the ledger records the unticked item too"
assert_eq 0 "$(grep -c 'plain item' .loop/results.json)" "a line with no verify command is not in the backlog ledger"
# The backlog is progress, not the contract: a red backlog item must not make a
# green contract red, or every loop would be blocked until its whole backlog
# was drained — which is the orchestrator's job across rounds, not one stop's.
assert_file_contains .loop/results.json '"all_green": true' "an unticked backlog item does not turn a green contract red"

# Idempotent: a second run re-verifies the unticked line and leaves the rest.
bash "$RUNNER" >/dev/null 2>&1
assert_eq 1 "$(grep -c '^- \[x\] green item' .loop/backlog.md)" "a re-run does not duplicate or re-write a ticked line"
assert_eq 1 "$(grep -c '^- \[ \] red item' .loop/backlog.md)" "a re-run re-checks the still-red line"

# JSON validity with hostile item text — the same guarantee the criteria have.
printf -- '- [ ] say "hi" \\ and\ttab | verify: true\n' > .loop/backlog.md
bash "$RUNNER" >/dev/null 2>&1
if command -v jq >/dev/null 2>&1; then
  jq . .loop/results.json >/dev/null 2>&1; assert_eq 0 $? "results.json stays valid JSON with quotes/backslash/TAB in an item"
elif command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; json.load(open(".loop/results.json"))' 2>/dev/null; assert_eq 0 $? "results.json stays valid JSON with quotes/backslash/TAB in an item"
else
  echo "  SKIP: no jq/python3 — backlog JSON validity not checked (1 assertion)" >&2
fi

# --- locked must imply tickable ---------------------------------------------
# The evidence-gate locks the WHOLE backlog file on `grep '|[[:space:]]*verify:'`
# while the loop is armed, but this runner used to tick only the strict literal
# `| verify: ` behind a 6-char `- [ ] ` prefix test. A line matching the gate and
# not the runner was untickable by ANYONE: the model's Write/Edit/Bash is denied
# and the runner never sees a verify command, so the box cannot move — the
# unattended driver re-picks the same item every round until its circuit breaker
# fires. Every shape below is one the gate locks; each must therefore tick.
rm -f .loop/backlog.md .loop/results.json
{
  printf -- '- [ ] canonical | verify: true\n'
  printf -- '- [ ] nospace |verify: true\n'
  printf -- '- [ ] tabbed |\tverify: true\n'
  printf -- '- [ ] twospace |  verify: true\n'
  printf -- '  - [ ] indented | verify: true\n'
  printf -- '- [ ] tight | verify:true\n'
  printf -- '- [ ] still red |verify: false\n'
} > .loop/backlog.md
bash "$RUNNER" >/dev/null 2>&1; assert_eq 0 $? "a tolerantly-spaced backlog does not change the contract's own verdict"
assert_file_contains .loop/backlog.md '- [x] canonical | verify: true' "the canonical spacing still ticks (control)"
assert_file_contains .loop/backlog.md '- [x] nospace | verify: true' "a pipe with no space before verify: ticks"
assert_file_contains .loop/backlog.md '- [x] tabbed | verify: true' "a TAB between the pipe and verify: ticks"
assert_file_contains .loop/backlog.md '- [x] twospace | verify: true' "two spaces between the pipe and verify: ticks"
assert_file_contains .loop/backlog.md '  - [x] indented | verify: true' "an indented item ticks, and keeps its indentation"
assert_file_contains .loop/backlog.md '- [x] tight | verify: true' "no space after verify: ticks"
assert_file_contains .loop/backlog.md '- [ ] still red |verify: false' "a red tolerant line stays unticked, byte for byte as written"
assert_file_contains .loop/results.json '"item": "indented", "verify": "true", "exit": 0, "done": true' "the ledger records the item without its indentation"
assert_file_contains .loop/results.json '"item": "tabbed", "verify": "true", "exit": 0, "done": true' "the ledger records a TAB-spaced item's command without the TAB"

# --- alternative bullet markers, kept as the author wrote them ---------------
# The gate's lock is FILE-level, so `* [ ] x | verify: true` locks the whole
# backlog and must therefore be tickable here too — same locked-must-imply-
# tickable rule as the spacing shapes above. The marker is PRESERVED rather
# than normalized to `-`: ticking a box is not reformatting someone's markdown,
# and inside a nested list the marker can change how the item renders.
rm -f .loop/backlog.md .loop/results.json
{
  printf -- '- [ ] dash | verify: true\n'
  printf -- '* [ ] star | verify: true\n'
  printf -- '+ [ ] plus | verify: true\n'
  printf -- '  * [ ] nested star |verify: true\n'
  printf -- '* [ ] red star | verify: false\n'
  printf -- '1. [ ] ordered | verify: true\n'
} > .loop/backlog.md
bash "$RUNNER" >/dev/null 2>&1; assert_eq 0 $? "a mixed-bullet backlog does not change the contract's own verdict"
assert_file_contains .loop/backlog.md '- [x] dash | verify: true' "a dash bullet still ticks (control)"
assert_file_contains .loop/backlog.md '* [x] star | verify: true' "a star bullet ticks, and keeps its marker"
assert_file_contains .loop/backlog.md '+ [x] plus | verify: true' "a plus bullet ticks, and keeps its marker"
assert_file_contains .loop/backlog.md '  * [x] nested star | verify: true' "an indented star bullet keeps both its indent and its marker"
assert_file_contains .loop/backlog.md '* [ ] red star | verify: false' "a failing star bullet stays unticked, byte for byte as written"
assert_file_contains .loop/results.json '"item": "star", "verify": "true", "exit": 0, "done": true' "the ledger records a star item without its marker"
# Ordered-list markers are a DELIBERATE boundary, not an oversight: the gate
# locks a backlog carrying this line (pinned in tests/test-evidence-gate.sh) and
# the runner leaves it alone, so the residual is a known, tested state.
assert_file_contains .loop/backlog.md '1. [ ] ordered | verify: true' "an ordered-list item is left exactly as written"
assert_eq 0 "$(grep -c '"item": "ordered"' .loop/results.json)" "an ordered-list item is not in the backlog ledger either"

# No backlog, or a backlog nobody opted in: no backlog block at all, and the
# old model-ticked contract is untouched.
rm -f .loop/backlog.md
bash "$RUNNER" >/dev/null 2>&1
assert_eq 0 "$(grep -c '"backlog"' .loop/results.json)" "no backlog file means no backlog block in the ledger"
printf -- '- [ ] an old-style item\n' > .loop/backlog.md
bash "$RUNNER" >/dev/null 2>&1
assert_eq 0 "$(grep -c '"backlog"' .loop/results.json)" "a backlog with no verify commands is left entirely alone"
assert_file_contains .loop/backlog.md '- [ ] an old-style item' "an opt-out backlog is not rewritten"
rm -f .loop/backlog.md should-not-rerun.marker

report "test-run-contract"
