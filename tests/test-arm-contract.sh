#!/usr/bin/env bash
# arm-contract.sh: pins criteria.tsv hash, arms the stop-gate, clears stale count.
set -u
. "$(dirname "$0")/lib.sh"

ARM="$PLUGIN_ROOT/skills/loop-eng/scripts/arm-contract.sh"
RUNNER="$PLUGIN_ROOT/skills/loop-eng/scripts/run-contract.sh"
SB=$(mk_sandbox_repo); trap 'rm -rf "$SB"' EXIT
cd "$SB" || exit 1
mkdir -p .loop

# --- arm pins the hash, creates active, clears a stale gate-count ---
printf '1\tok\ttrue\n' > .loop/criteria.tsv
echo 2 > .loop/gate-count   # stale counter from a previous loop
echo "1 block" > .loop/gate-last   # stale same-stop-attempt marker from a previous loop
bash "$ARM" 2>/dev/null
assert_eq 0 $? "arm exits 0"
assert_eq "1" "$([ -f .loop/active ] && echo 1)" "arm creates .loop/active"
assert_eq "" "$([ -f .loop/gate-count ] && echo 1)" "arm clears stale gate-count"
assert_eq "" "$([ -f .loop/gate-last ] && echo 1)" "arm clears the stale dedup marker with the counter"
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

# --- PARTLY malformed criteria.tsv: warn at ARM time, while the file is still
#     writable. run-contract fails closed on the same contract, but by then the
#     evidence-gate has locked criteria.tsv for the duration of the loop — so
#     without this warning the author's first signal is a stop they cannot fix. ---
rm -f .loop/criteria.tsv .loop/criteria.sha256 .loop/active
{ printf 'lint\tsyntax ok\ttrue\n'
  printf 'smoke must print world false\n'     # spaces, not TABs
  printf 'types\ttypecheck\ttrue\n'; } > .loop/criteria.tsv
bash "$ARM" 2>.loop/armwarn; assert_eq 0 $? "arm on a partly malformed contract still exits 0 (advisory)"
assert_eq "1" "$([ -f .loop/active ] && echo 1)" "arm still arms despite the malformed-line warning"
assert_file_contains .loop/armwarn 'malformed' "arm warns that a criterion line will never run"
assert_file_contains .loop/armwarn 'line(s): 2' "arm names the offending line number"
rm -f .loop/active .loop/criteria.sha256 .loop/gate-count .loop/armwarn

# --- .loop/ must be ignored by git, and arming is what guarantees it ---
# The whole chain assumed this and nothing made it so. In a repo whose
# .gitignore does not list .loop/, the builder's `git add -A` commits
# criteria.tsv, criteria.sha256, results.json and evidence/; the stop-gate then
# rewrites results.json on every stop, the tree is permanently ` M
# .loop/results.json`, and both unattended drivers refuse to run ("dirty tree")
# for good. Verified end to end before the fix: five .loop files committed, then
# a wedged tree. README asserted .loop/ "is gitignored" with nothing making it
# true. The sandbox helper writes a .gitignore, so this arm needs a repo without
# one — exactly the shape a new user's project has.
NOIGN=$(mktemp -d "${TMPDIR:-/tmp}/loop-eng-noign.XXXXXX")
NOIGN=$(cd "$NOIGN" && pwd)
# Scratch OUTSIDE the repo under test: a capture file written inside it would be
# staged by the very `git add -A` this block asserts stages nothing — the test
# would then fail on its own artifact and look like a product bug.
IGNOUT=$(mktemp -d "${TMPDIR:-/tmp}/loop-eng-ignout.XXXXXX")
trap 'rm -rf "$SB" "$NOIGN" "$IGNOUT"' EXIT
(
  cd "$NOIGN" || exit 1
  git init -q; git config user.email test@loop-eng.local; git config user.name loop-eng-test
  echo sandbox > README.md; git add README.md; git commit -qm initial
) >/dev/null
mkdir -p "$NOIGN/.loop"
printf 'ok\tstill fine\ttrue\n' > "$NOIGN/.loop/criteria.tsv"
( cd "$NOIGN" && bash "$ARM" 2>"$IGNOUT/ignwarn" ) >/dev/null
assert_file_contains "$IGNOUT/ignwarn" "not ignored by git" "arming an unignored repo says what it is fixing"
assert_file_contains "$NOIGN/.git/info/exclude" ".loop/" "arming writes the ignore into .git/info/exclude"
# the user's own .gitignore must stay untouched — arming a loop is not a diff
if [ -e "$NOIGN/.gitignore" ]; then
  assert_eq "no .gitignore" "created one" "arming does not create or edit the user's .gitignore"
else
  assert_eq 0 0 "arming does not create or edit the user's .gitignore"
fi
# the consequence, not just the file: `git add -A` now stages nothing
( cd "$NOIGN" && git add -A && git status --porcelain ) > "$IGNOUT/after" 2>/dev/null
assert_eq 0 "$(wc -c < "$IGNOUT/after" | tr -d ' ')" "after arming, git add -A stages no loop bookkeeping"
# idempotent: a second arm must not append a duplicate line every round
( cd "$NOIGN" && bash "$ARM" ) >/dev/null 2>&1
assert_eq 1 "$(grep -c '^\.loop/$' "$NOIGN/.git/info/exclude")" "re-arming does not append a duplicate exclude line"

# ...and the case the exclude file cannot fix: git ignores nothing it already
# tracks, so arming warns and names the command that undoes it.
TRACKED=$(mktemp -d "${TMPDIR:-/tmp}/loop-eng-tracked.XXXXXX")
TRACKED=$(cd "$TRACKED" && pwd)
trap 'rm -rf "$SB" "$NOIGN" "$IGNOUT" "$TRACKED"' EXIT
(
  cd "$TRACKED" || exit 1
  git init -q; git config user.email test@loop-eng.local; git config user.name loop-eng-test
  mkdir -p .loop; printf 'ok\tstill fine\ttrue\n' > .loop/criteria.tsv
  git add -A -f; git commit -qm "loop bookkeeping committed by mistake"
) >/dev/null
( cd "$TRACKED" && bash "$ARM" 2>"$IGNOUT/trackwarn" ) >/dev/null
assert_file_contains "$IGNOUT/trackwarn" "TRACKED by git" "arming a repo with committed .loop/ warns that it is tracked"
assert_file_contains "$IGNOUT/trackwarn" "git rm -r --cached" "the tracked warning names the command that undoes it"
assert_eq "1" "$([ -f "$TRACKED/.loop/active" ] && echo 1)" "the tracked warning is advisory — the loop still arms"

# --- empty DESCRIPTION column: legal, and arm and run must agree that it is ---
# `id<TAB><TAB>cmd` is three real TAB-separated columns with a blank middle one.
# This file used to carry FOUR different splits of the same line: two `awk -F'\t'`
# (which does not collapse TABs) and two `IFS=$'\t' read` (which does, because
# TAB is IFS whitespace). They disagreed here and only here — awk called it
# runnable so arm warned about nothing and pinned the hash, both read loops saw
# an empty command and skipped it, and run-contract called it malformed and
# failed CLOSED on every stop with a message blaming SPACES in a file that has
# none. Armed and unfixable: the evidence-gate locks criteria.tsv, so the loop
# could only end by hitting a stop rule.
rm -f .loop/criteria.tsv .loop/criteria.sha256 .loop/active
printf 'id1\t\ttrue\n' > .loop/criteria.tsv
bash "$ARM" 2>.loop/armwarn; assert_eq 0 $? "arm on an empty-description criterion exits 0"
assert_eq "" "$(grep -c malformed .loop/armwarn 2>/dev/null | grep -v '^0$')" "empty description is not malformed"
assert_eq "" "$(grep -c 'no runnable criteria' .loop/armwarn 2>/dev/null | grep -v '^0$')" "empty description still counts as a runnable criterion"
# the advisory checks must SEE it too — as its own read loop each one skipped
# every empty-description criterion without saying so
assert_file_contains .loop/armwarn 'already green' "the red-check runs on an empty-description criterion"
rm -f .loop/active .loop/criteria.sha256 .loop/gate-count .loop/armwarn
printf 'id1\t\tif\n' > .loop/criteria.tsv   # unparseable command, empty description
bash "$ARM" 2>.loop/armwarn; assert_eq 0 $? "arm on an unparseable empty-description criterion exits 0"
assert_file_contains .loop/armwarn 'can never run' "the parse check runs on an empty-description criterion"
rm -f .loop/active .loop/criteria.sha256 .loop/gate-count .loop/armwarn

# --- an empty ID column is the mirror image and stays malformed ---
rm -f .loop/criteria.tsv .loop/criteria.sha256 .loop/active
printf '\tdesc\ttrue\n' > .loop/criteria.tsv   # leading TAB: no id
bash "$ARM" 2>.loop/armwarn; assert_eq 0 $? "arm on an empty-id criterion exits 0 (advisory)"
assert_file_contains .loop/armwarn 'malformed' "an empty id column is still malformed"
rm -f .loop/active .loop/criteria.sha256 .loop/gate-count .loop/armwarn

# --- zero false positives: the shapes the parser legitimately skips (comments,
#     blank, whitespace-only, indented comments) must NOT trip that warning. ---
rm -f .loop/criteria.tsv .loop/criteria.sha256 .loop/active
{ printf '# a leading comment\n'
  printf '\n'
  printf '   \n'
  printf '  # an indented comment\n'
  printf 'ok\tstill fine\ttrue\n'; } > .loop/criteria.tsv
bash "$ARM" 2>.loop/armwarn; assert_eq 0 $? "arm on a clean contract exits 0"
assert_eq "" "$(grep -c malformed .loop/armwarn 2>/dev/null | grep -v '^0$')" "no malformed warning on comment/blank/whitespace lines"
rm -f .loop/active .loop/criteria.sha256 .loop/gate-count .loop/armwarn

# --- criterion that can NEVER run: a command bash cannot PARSE. run-contract
#     executes each criterion as `bash -c "$cmd"`, so a string that does not
#     parse fails on EVERY stop attempt, on any tree, whatever the builder does
#     — the loop can then only end by hitting a stop rule. The shape below is
#     the one that actually happened in the v0.12.0 live-install smoke: the
#     orchestrator's printf ate the outer quotes off a git pathspec. It exits 2,
#     the same status as `grep -q needle missing-file` (a legitimate RED), which
#     is why this keys on the PARSE and not on the exit status. ---
rm -f .loop/criteria.tsv .loop/criteria.sha256 .loop/active
{ printf 'lint\tsyntax ok\ttrue\n'
  printf 'scope\tdiff excluding tests\tgit diff --stat -- . :(exclude)tests/*\n'; } > .loop/criteria.tsv
bash "$ARM" 2>.loop/armwarn; assert_eq 0 $? "arm on an unparseable criterion still exits 0 (advisory)"
assert_eq "1" "$([ -f .loop/active ] && echo 1)" "arm still arms despite the unparseable-criterion warning"
assert_file_contains .loop/armwarn 'can never run' "arm warns that an unparseable criterion can never run"
assert_file_contains .loop/armwarn "criterion 'scope'" "arm names the unparseable criterion by id"
assert_file_contains .loop/armwarn 'syntax error' "arm forwards bash's own diagnosis, not a generic message"
assert_eq "1" "$(grep -c 'can never run' .loop/armwarn)" "exactly one criterion is flagged — its parseable neighbour is not"
assert_eq "" "$(grep -c '^bash: ' .loop/armwarn 2>/dev/null | grep -v '^0$')" "the diagnosis is folded into one line, not spilled as raw bash stderr"
rm -f .loop/active .loop/criteria.sha256 .loop/gate-count .loop/armwarn

# --- the parse check is STATIC: it must survive LOOP_ENG_ARM_REDCHECK=0 (the
#     knob exists to execute ZERO criterion commands) and must itself execute
#     none. bash parses a whole -c string before running any of it, so even the
#     side effect standing BEFORE the syntax error never happens. ---
#     The side effect sits on its own PARSEABLE line, so swapping the check's
#     `bash -n -c` for `bash -c` leaves the marker behind and trips this. ---
rm -f .loop/criteria.tsv .loop/criteria.sha256 .loop/active
{ printf 'effect\ta criterion that would touch a file if executed\ttouch parse-probe.marker\n'
  printf 'probe\tunparseable\techo "unterminated\n'; } > .loop/criteria.tsv
LOOP_ENG_ARM_REDCHECK=0 bash "$ARM" 2>.loop/armwarn; assert_eq 0 $? "arm with the red-check disabled still exits 0 on an unparseable criterion"
assert_file_contains .loop/armwarn 'can never run' "the parse check still warns with LOOP_ENG_ARM_REDCHECK=0"
assert_eq "" "$([ -f parse-probe.marker ] && echo 1)" "the parse check executes ZERO criterion commands"
rm -f .loop/active .loop/criteria.sha256 .loop/gate-count .loop/armwarn parse-probe.marker

# --- zero false positives: a criterion that is merely RED at arm time — and
#     goes green once the builder has worked — must NOT be flagged. Each line
#     is a status the "unrunnable = 126/127/2" reading would have misclaimed:
#     2 (grep on a file the work creates), 127 (a test script the work writes),
#     1 (plain false), plus the correctly-quoted form of the pathspec above. ---
rm -f .loop/criteria.tsv .loop/criteria.sha256 .loop/active
{ printf 'needle\tgrep a file the work creates\tgrep -q needle not-yet-created.txt\n'
  printf 'suite\trun a test the work writes\tbash tests/not-yet-written.sh\n'
  printf 'plain\tplain red\tfalse\n'
  printf 'scope\tquoted pathspec (the fixed form)\tgit diff --stat -- . ":(exclude)tests/*"\n'; } > .loop/criteria.tsv
LOOP_ENG_ARM_REDCHECK=0 bash "$ARM" 2>.loop/armwarn; assert_eq 0 $? "arm on legitimately-red criteria exits 0"
assert_eq "" "$(grep -F 'can never run' .loop/armwarn)" "no unrunnable warning on criteria that are merely RED"
rm -f .loop/active .loop/criteria.sha256 .loop/gate-count .loop/armwarn

# --- pre-arm red-check: an ALREADY-green criterion warns but arm still succeeds ---
rm -f .loop/criteria.tsv .loop/criteria.sha256 .loop/active .loop/gate-count
printf 'baseline\talready passes\ttrue\n' > .loop/criteria.tsv
bash "$ARM" 2>.loop/armwarn; assert_eq 0 $? "arm with an already-green criterion still exits 0"
assert_eq "1" "$([ -f .loop/active ] && echo 1)" "arm still creates .loop/active despite red-check warning"
assert_file_contains .loop/armwarn 'already green' "arm red-check warns on a criterion green at arm time"
assert_file_contains .loop/armwarn 'baseline' "arm red-check names the offending criterion id"
rm -f .loop/active .loop/criteria.sha256 .loop/gate-count .loop/armwarn

# --- UTF-8 BOM on line 1: arm and run must agree on the id, for the same reason
#     they were made to agree on the empty-description split (P1-6). If only one
#     of them strips the BOM, arm's warnings name a criterion the ledger does not
#     contain — and every arm-time warning exists precisely so a human can find
#     that criterion by name before the evidence-gate locks the file. ---
rm -f .loop/criteria.tsv .loop/criteria.sha256 .loop/active .loop/gate-count
printf '\xef\xbb\xbfbaseline\talready passes\ttrue\n' > .loop/criteria.tsv
bash "$ARM" 2>.loop/armwarn; assert_eq 0 $? "arm with a BOM-prefixed criteria.tsv exits 0"
assert_file_contains .loop/armwarn "criterion 'baseline' is already green" "arm strips the BOM before naming the criterion"
rm -f .loop/active .loop/criteria.sha256 .loop/gate-count .loop/armwarn

# --- red-check: a stdin-reading criterion must not swallow later criteria lines ---
# (pre-fix, `cat` consumed the rest of criteria.tsv from the while-read loop's
# stdin — run-contract.sh guards this with </dev/null, the red-check did not —
# so criteria after a stdin-reader were silently skipped, losing their warnings)
rm -f .loop/criteria.tsv .loop/criteria.sha256 .loop/active .loop/gate-count
printf 'reader\treads stdin\tcat\nc2\talso green\ttrue\n' > .loop/criteria.tsv
bash "$ARM" 2>.loop/armwarn; assert_eq 0 $? "arm with a stdin-reading criterion exits 0"
assert_file_contains .loop/armwarn "criterion 'c2' is already green" "criterion after a stdin-reader is still red-checked"
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

# --- family invariant: a budget knob set to 0 must never mean "no budget" ---
# GNU `timeout 0` DISABLES the timeout, so 0 is a config error for every budget
# knob in this plugin: LOOP_ENG_GATE_TIMEOUT (stop-gate), LOOP_ENG_MAX_MINUTES
# (both unattended runners) and this one. The other three warn and fall back, and
# each has an assertion pinning that. arm-contract fell back correctly but
# SILENTLY, and was the only one of the four with nothing asserting it — which is
# exactly how the same gap survived in stop-gate.sh until an audit caught it.
# Keep this test and its three siblings in lockstep when adding a budget knob.
rm -f .loop/criteria.tsv .loop/criteria.sha256 .loop/active .loop/gate-count
printf 'ok\ttrivially green\ttrue\n' > .loop/criteria.tsv
LOOP_ENG_ARM_REDCHECK_TIMEOUT=0 bash "$ARM" 2>.loop/armwarn0; assert_eq 0 $? "REDCHECK_TIMEOUT=0 still arms"
assert_file_contains .loop/armwarn0 "would disable" "REDCHECK_TIMEOUT=0 warns that 0 would disable the budget"
LOOP_ENG_ARM_REDCHECK_TIMEOUT=00 bash "$ARM" 2>.loop/armwarn00
assert_file_contains .loop/armwarn00 "would disable" "REDCHECK_TIMEOUT=00 (leading zero) hits the same guard"
LOOP_ENG_ARM_REDCHECK_TIMEOUT=10 bash "$ARM" 2>.loop/armwarnok
if grep -q 'would disable' .loop/armwarnok; then
  assert_eq "quiet" "warned" "a valid REDCHECK_TIMEOUT does not warn"
else
  assert_eq 0 0 "a valid REDCHECK_TIMEOUT does not warn"
fi
rm -f .loop/active .loop/criteria.sha256 .loop/gate-count .loop/armwarn0 .loop/armwarn00 .loop/armwarnok

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

# --- no SHA-256 tool on PATH: arm warns, still arms, writes NO hash-lock ---
# (fail-open by design at arm time: the loop still runs, but post-arm drift can
# never fail closed — the stderr warning is the only signal. Forced with a
# minimal fake PATH holding the tools arm-contract needs but none of
# sha256sum/shasum/openssl; LOOP_ENG_ARM_REDCHECK=0 keeps the case focused on
# the hash branch. Same PATH-stripping technique as test-evidence-gate.sh.)
rm -f .loop/criteria.tsv .loop/criteria.sha256 .loop/active .loop/gate-count .loop/armwarn
printf '1\tok\ttrue\n' > .loop/criteria.tsv
FAKEBIN="$SB/fakebin-arm"; mkdir -p "$FAKEBIN"
for t in bash awk mkdir rm; do
  src=$(command -v "$t") && ln -sf "$src" "$FAKEBIN/$t"
done
if env PATH="$FAKEBIN" bash -c 'command -v sha256sum || command -v shasum || command -v openssl' >/dev/null 2>&1; then
  echo "  SKIP: could not hide every SHA-256 tool from PATH" >&2
else
  env PATH="$FAKEBIN" LOOP_ENG_ARM_REDCHECK=0 bash "$ARM" 2>.loop/armwarn
  assert_eq 0 $? "arm without any SHA-256 tool still exits 0"
  assert_file_contains .loop/armwarn 'no SHA-256 tool' "arm warns when no SHA-256 tool is on PATH"
  assert_eq "1" "$([ -f .loop/active ] && echo 1)" "arm still creates .loop/active without a SHA-256 tool"
  assert_eq "" "$([ -f .loop/criteria.sha256 ] && echo 1)" "arm writes no hash-lock without a SHA-256 tool"
fi
rm -rf "$FAKEBIN"
rm -f .loop/criteria.tsv .loop/criteria.sha256 .loop/active .loop/gate-count .loop/armwarn

# --- LOOP_ENG_LOOP_DIR: arming a custom dir arms THAT dir, never ./.loop ---
# (the scripts' comments call this the suite's sandboxing knob — this is the
# test that makes that claim true. Assert both the custom-dir writes AND that
# the default .loop/ stays untouched.)
rm -rf customdir
rm -f .loop/criteria.tsv .loop/criteria.sha256 .loop/active .loop/gate-count
mkdir -p customdir
printf 'c1\tok\ttrue\n' > customdir/criteria.tsv
LOOP_ENG_LOOP_DIR=customdir bash "$ARM" 2>/dev/null; assert_eq 0 $? "LOOP_ENG_LOOP_DIR: arm exits 0"
assert_eq "1" "$([ -f customdir/active ] && echo 1)" "LOOP_ENG_LOOP_DIR: arm creates customdir/active"
assert_eq "$(sha_of customdir/criteria.tsv)" "$(cut -d' ' -f1 < customdir/criteria.sha256)" "LOOP_ENG_LOOP_DIR: hash-lock pinned inside the custom dir"
assert_eq "" "$([ -f .loop/active ] && echo 1)" "LOOP_ENG_LOOP_DIR: default .loop/active NOT created"
assert_eq "" "$([ -f .loop/criteria.sha256 ] && echo 1)" "LOOP_ENG_LOOP_DIR: default .loop/criteria.sha256 NOT created"
rm -rf customdir

# --- a write that FAILED must never be reported as a successful arm ---
# arm-contract runs under `set -u` only and exits 0 on every path, reporting on
# stderr what it did. With the writes to $LOOP_DIR unchecked, a failed write
# printed both success lines over a .loop/ that got neither: `pinned
# criteria.tsv @ <hash>` with no hash-lock on disk, and `stop-gate armed
# (.loop/active)` with no .loop/active. Without .loop/active the stop-gate
# returns at its first line (hooks/stop-gate.sh: `[ -f "$ACTIVE" ] || exit 0`),
# so the stop it exists to block is allowed, and the evidence-gate's lock on
# criteria.tsv — also keyed on .loop/active — never engages, leaving the armed
# contract file model-writable. (results.json and evidence/ stay protected
# either way; only the contract file and the stop-gate are lost.)
#
# Case (c) needs no filesystem fault at all: an unwritable criteria.sha256 left
# by an earlier run under sudo or `docker run -v` in an otherwise writable
# .loop/ is enough, and it wedges the NEXT loop instead of disarming this one.
# chmod cannot take write access away from root, so this is skipped there.
if [ "$(id -u)" -ne 0 ]; then
  rm -f .loop/criteria.tsv .loop/criteria.sha256 .loop/active .loop/gate-count .loop/gate-last
  ARMERR="$SB/arm-failed.err"   # outside .loop/ — the dir under test is unwritable

  # (a) the loop dir itself cannot be created
  rm -rf roparent; mkdir -p roparent; chmod a-w roparent
  LOOP_ENG_LOOP_DIR=roparent/loop bash "$ARM" 2>"$ARMERR"; rc=$?
  chmod u+w roparent
  assert_eq 73 "$rc" "uncreatable loop dir: arm refuses, exit 73 (EX_CANTCREAT, as run-contract's cannot_write)"
  assert_file_contains "$ARMERR" 'cannot write' "uncreatable loop dir: the refusal names the write it could not do"
  assert_eq "" "$(grep -c 'stop-gate armed' "$ARMERR" 2>/dev/null | grep -v '^0$')" "uncreatable loop dir: arm never claims the stop-gate is armed"
  rm -rf roparent

  # (b) .loop/ exists but is read-only: the hash-lock write is the first casualty
  rm -f .loop/criteria.tsv .loop/criteria.sha256 .loop/active .loop/gate-count
  printf 'c1\tsuite passes\tfalse\n' > .loop/criteria.tsv
  chmod a-w .loop
  bash "$ARM" 2>"$ARMERR"; rc=$?
  chmod u+w .loop
  assert_eq 73 "$rc" "read-only .loop: arm refuses, exit 73"
  assert_file_contains "$ARMERR" 'cannot write .loop/criteria.sha256' "read-only .loop: the refusal names the hash-lock it could not write (bash's own redirect error names that path too — the needle is the refusal's own wording)"
  assert_eq "" "$(grep -c 'pinned criteria.tsv @' "$ARMERR" 2>/dev/null | grep -v '^0$')" "read-only .loop: arm never reports pinning a hash it could not write"
  assert_eq "" "$(grep -c 'stop-gate armed' "$ARMERR" 2>/dev/null | grep -v '^0$')" "read-only .loop: arm never claims the stop-gate is armed"
  assert_eq "" "$([ -f .loop/active ] && echo 1)" "read-only .loop: no .loop/active — the refusal leaves the loop honestly unarmed"
  assert_eq "" "$([ -f .loop/criteria.sha256 ] && echo 1)" "read-only .loop: no hash-lock on disk either"

  # (c) writable .loop/, unwritable pre-existing criteria.sha256 (no FS fault)
  rm -f .loop/criteria.tsv .loop/criteria.sha256 .loop/active .loop/gate-count
  printf 'c1\tok\ttrue\n' > .loop/criteria.tsv
  bash "$ARM" 2>/dev/null                      # healthy arm pins contract A
  stale_lock=$(cut -d' ' -f1 < .loop/criteria.sha256)
  rm -f .loop/active .loop/gate-count
  chmod a-w .loop/criteria.sha256
  printf 'c1\tok\ttrue\nc2\talso ok\ttrue\n' > .loop/criteria.tsv   # contract B
  bash "$ARM" 2>"$ARMERR"; rc=$?
  chmod u+w .loop/criteria.sha256
  assert_eq 73 "$rc" "unwritable pre-existing hash-lock: arm refuses, exit 73"
  assert_eq "$stale_lock" "$(cut -d' ' -f1 < .loop/criteria.sha256)" "unwritable hash-lock: disk still holds the OLD contract's hash"
  assert_eq "" "$(grep -c 'pinned criteria.tsv @' "$ARMERR" 2>/dev/null | grep -v '^0$')" "unwritable hash-lock: arm does not report the new hash as pinned while disk holds the old one"
  assert_eq "" "$([ -f .loop/active ] && echo 1)" "unwritable hash-lock: a contract that could not be re-pinned is not armed"
  # The wedge this prevents: armed + lock/contract mismatch is exit 77 on EVERY
  # stop, with criteria.tsv gate-locked, for a contract that is fully GREEN.
  bash "$RUNNER" >/dev/null 2>&1
  assert_eq 0 "$?" "unwritable hash-lock: no wedge — the refused arm left no armed-but-mismatched pair to fail closed on"

  rm -f "$ARMERR" .loop/active .loop/gate-count .loop/criteria.sha256
else
  echo "  SKIP: running as root — chmod cannot take write access away, so the failed-write refusals are not exercised (14 assertions)" >&2
fi

report "test-arm-contract"
