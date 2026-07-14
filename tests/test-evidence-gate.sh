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

# --- wrap-up that removes .loop/active AND criteria.sha256 in ONE Bash command is
#     denied (active still exists when the whole string is scanned); the deny must
#     advise splitting it — remove active first, then the hash-lock in a 2nd call. ---
gate "${B/CMD/rm -f .loop/active .loop/criteria.sha256}"; assert_eq 2 $? "Bash rm active+sha256 in one command denied when armed"
printf '%s' "${B/CMD/rm -f .loop/active .loop/criteria.sha256}" | bash "$GATE" 2>.loop/err || true
assert_file_contains .loop/err 'active first' "deny advises removing active first"

# --- results.json/evidence: always denied, armed or not ---
gate "${W/FILE/.loop/results.json}";              assert_eq 2 $? "results.json denied while armed"
rm -f .loop/active
gate "${W/FILE/.loop/criteria.sha256}";           assert_eq 0 $? "criteria.sha256 rewrite allowed when not armed"
rm -f .loop/criteria.sha256
gate "${W/FILE/.loop/results.json}";              assert_eq 2 $? "results.json denied with no active (explicit)"

# --- M4: a legacy (verify.sh) loop has NO criteria.tsv; while it is armed,
#     CREATING a fresh trivial criteria.tsv would hijack the stop-gate (which
#     prefers criteria.tsv over verify.sh). Deny the create too, not only the
#     overwrite — the Write/Edit branch must not require the file to pre-exist. ---
rm -f .loop/criteria.tsv
touch .loop/active
gate "${W/FILE/.loop/criteria.tsv}";              assert_eq 2 $? "create criteria.tsv denied when armed (no prior file)"
gate "${W/FILE/$SB/.loop/criteria.tsv}";          assert_eq 2 $? "create abs-path criteria.tsv denied when armed"
rm -f .loop/active
gate "${W/FILE/.loop/criteria.tsv}";              assert_eq 0 $? "create criteria.tsv allowed when not armed"

# --- L2: NotebookEdit carries the target in notebook_path, not file_path; the
#     gate must read it or NotebookEdit is a blind spot into the ledger. ---
N='{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"FILE"}}'
gate "${N/FILE/.loop/results.json}";              assert_eq 2 $? "NotebookEdit notebook_path results.json denied"
gate "${N/FILE/src/notebook.ipynb}";              assert_eq 0 $? "NotebookEdit unrelated notebook allowed"

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
# The runner path must be usable where the model runs: with CLAUDE_PLUGIN_ROOT
# set (marketplace install) the message carries the real absolute path; without
# it, a placeholder — never a project-relative skills/ path that isn't there.
printf '%s' "${W/FILE/.loop/results.json}" | CLAUDE_PLUGIN_ROOT=/opt/plug bash "$GATE" 2>.loop/err || true
assert_file_contains .loop/err '/opt/plug/skills/loop-eng/scripts/run-contract.sh' "deny resolves runner via CLAUDE_PLUGIN_ROOT"
printf '%s' "${W/FILE/.loop/results.json}" | env -u CLAUDE_PLUGIN_ROOT bash "$GATE" 2>.loop/err || true
assert_file_contains .loop/err '<loop-eng plugin root>' "deny falls back to a placeholder without CLAUDE_PLUGIN_ROOT"

# --- python3 fallback path (jq absent): the gate must still enforce ---
# jq-less environments (python3 only) are common; without this the whole fallback
# parser is untested and could regress silently. Force it by hiding jq behind a
# minimal PATH that has only the tools the gate needs.
if command -v python3 >/dev/null 2>&1; then
  FAKE=$(mktemp -d)
  # Mirror the tools the gate uses (bash for its own subshells, cat for stdin,
  # python3 for the fallback parser, plus the coreutils the path checks call) —
  # everything EXCEPT jq, so `command -v jq` fails and the python3 branch runs.
  for t in bash cat python3 grep dirname sed sha256sum; do
    src=$(command -v "$t") && ln -sf "$src" "$FAKE/$t"
  done
  if ! PATH="$FAKE" bash -c 'command -v jq' >/dev/null 2>&1; then
    printf '%s' "${W/FILE/.loop/results.json}" | PATH="$FAKE" bash "$GATE" 2>/dev/null
    assert_eq 2 $? "python3 fallback (no jq): Write results.json still denied"
    printf '%s' "${W/FILE/src/app.js}" | PATH="$FAKE" bash "$GATE" 2>/dev/null
    assert_eq 0 $? "python3 fallback (no jq): unrelated Write still allowed"
  else
    echo "  SKIP: could not hide jq from PATH — python3 branch not forced" >&2
  fi
  rm -rf "$FAKE"
fi

report "test-evidence-gate"
