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

# --- missing criteria.tsv ---
rm .loop/criteria.tsv
bash "$RUNNER" 2>/dev/null; assert_eq 78 $? "missing criteria exit 78"

report "test-run-contract"
