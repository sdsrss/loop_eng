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
bash "$RUNNER"; assert_eq 1 $? "red contract exit 1"
assert_file_contains .loop/results.json '"all_green": false' "all_green false"
assert_file_contains .loop/results.json '"id": "2", "desc": "fails", "cmd": "false", "exit": 1, "passes": false' "criterion 2 failed with exit code"

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
bash "$RUNNER" 2>/dev/null; assert_eq 1 $? "all-comment criteria fails closed, exit 1"
assert_file_contains .loop/results.json '"all_green": false' "vacuous contract not green"
assert_file_contains .loop/results.json 'no runnable criteria' "vacuous contract reason recorded"
: > .loop/criteria.tsv   # truly empty file
bash "$RUNNER" 2>/dev/null; assert_eq 1 $? "empty criteria fails closed, exit 1"
assert_file_contains .loop/results.json '"all_green": false' "empty contract not green"

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
bash "$RUNNER"; assert_eq 1 $? "no-trailing-newline: failing last criterion caught (exit 1)"
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

# --- missing criteria.tsv ---
rm .loop/criteria.tsv
bash "$RUNNER" 2>/dev/null; assert_eq 78 $? "missing criteria exit 78"

report "test-run-contract"
