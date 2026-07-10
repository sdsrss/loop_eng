#!/usr/bin/env bash
# evidence-gate: PreToolUse denial of model writes to the evidence ledger.
set -u
. "$(dirname "$0")/lib.sh"

GATE="$PLUGIN_ROOT/hooks/evidence-gate.sh"
SB=$(mk_sandbox_repo); trap 'rm -rf "$SB"' EXIT
cd "$SB"
mkdir -p .loop/evidence

gate() { # json -> exit code of gate
  printf '%s' "$1" | bash "$GATE" 2>/dev/null
}

W='{"tool_name":"Write","tool_input":{"file_path":"FILE"}}'
E='{"tool_name":"Edit","tool_input":{"file_path":"FILE"}}'
B='{"tool_name":"Bash","tool_input":{"command":"CMD"}}'

# --- always-protected: results.json + evidence/ ---
gate "${W/FILE/.loop/results.json}";              assert_eq 2 $? "Write results.json denied"
gate "${W/FILE/$SB/.loop/results.json}";          assert_eq 2 $? "Write abs-path results.json denied"
gate "${E/FILE/.loop/evidence/1.log}";            assert_eq 2 $? "Edit evidence log denied"

# --- criteria.tsv: first Write always allowed (file absent) ---
gate "${W/FILE/.loop/criteria.tsv}";              assert_eq 0 $? "first Write criteria.tsv allowed"
printf '1\tx\ttrue\n' > .loop/criteria.tsv

# --- criteria.tsv exists but loop NOT armed: next contract may rewrite it ---
gate "${W/FILE/.loop/criteria.tsv}";              assert_eq 0 $? "rewrite criteria.tsv allowed when not armed"
gate "${E/FILE/.loop/criteria.tsv}";              assert_eq 0 $? "Edit criteria.tsv allowed when not armed"
gate "${B/CMD/rm .loop/criteria.tsv}";            assert_eq 0 $? "Bash rm criteria.tsv allowed when not armed"

# --- criteria.tsv exists AND loop armed (.loop/active present): locked ---
touch .loop/active
gate "${W/FILE/.loop/criteria.tsv}";              assert_eq 2 $? "overwrite criteria.tsv denied when armed"
gate "${E/FILE/.loop/criteria.tsv}";              assert_eq 2 $? "Edit criteria.tsv denied when armed"
gate "${W/FILE/$SB/.loop/criteria.tsv}";          assert_eq 2 $? "abs-path criteria.tsv denied when armed"
gate "${B/CMD/rm .loop/criteria.tsv}";            assert_eq 2 $? "Bash rm criteria.tsv denied when armed"

# --- criteria.sha256 hash-lock: locked while armed (else a model could rewrite
#     it to match a weakened criteria.tsv and defeat run-contract's tamper check) ---
printf 'deadbeef\n' > .loop/criteria.sha256
gate "${W/FILE/.loop/criteria.sha256}";           assert_eq 2 $? "overwrite criteria.sha256 denied when armed"
gate "${E/FILE/.loop/criteria.sha256}";           assert_eq 2 $? "Edit criteria.sha256 denied when armed"
gate "${B/CMD/echo x > .loop/criteria.sha256}";   assert_eq 2 $? "Bash redirect criteria.sha256 denied when armed"

# --- results.json/evidence: always denied, armed or not ---
gate "${W/FILE/.loop/results.json}";              assert_eq 2 $? "results.json denied while armed"
rm -f .loop/active
gate "${W/FILE/.loop/criteria.sha256}";           assert_eq 0 $? "criteria.sha256 rewrite allowed when not armed"
rm -f .loop/criteria.sha256
gate "${W/FILE/.loop/results.json}";              assert_eq 2 $? "results.json denied with no active (explicit)"

# --- unrelated paths allowed ---
gate "${W/FILE/src/app.js}";                      assert_eq 0 $? "unrelated Write allowed"
gate "${W/FILE/.loop/state.md}";                  assert_eq 0 $? ".loop/state.md Write allowed"

# --- Bash: write-ish operators on always-protected paths denied, benign allowed ---
gate "${B/CMD/echo done > .loop/results.json}";   assert_eq 2 $? "Bash redirect to results.json denied"
gate "${B/CMD/sed -i s,false,true, .loop/results.json}"; assert_eq 2 $? "Bash sed -i results.json denied"
gate "${B/CMD/bash .loop/verify.sh}";             assert_eq 0 $? "running verify.sh allowed"
gate "${B/CMD/cat .loop/results.json}";           assert_eq 0 $? "reading results.json allowed"
gate "${B/CMD/git add .loop/results.json}";       assert_eq 0 $? "git add allowed"

# --- escape hatch ---
printf '%s' "${W/FILE/.loop/results.json}" | LOOP_ENG_DISABLE_EVIDENCE_GATE=1 bash "$GATE" 2>/dev/null
assert_eq 0 $? "escape hatch allows everything"

# --- deny message names the refresh path and the escape hatch ---
printf '%s' "${W/FILE/.loop/results.json}" | bash "$GATE" 2>.loop/err || true
assert_file_contains .loop/err 'machine-written' "deny explains machine-written"
assert_file_contains .loop/err 'LOOP_ENG_DISABLE_EVIDENCE_GATE' "deny names escape hatch"

report "test-evidence-gate"
