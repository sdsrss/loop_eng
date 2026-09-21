#!/usr/bin/env bash
# evidence-gate: PreToolUse denial of model writes to the evidence ledger.
set -u
. "$(dirname "$0")/lib.sh"

GATE="$PLUGIN_ROOT/hooks/evidence-gate.sh"
SB=$(mk_sandbox_repo)
# Both fake-PATH dirs are declared HERE and covered by the one EXIT trap. As
# inline `FAKE=$(mktemp -d)` further down they were cleaned by an inline `rm`,
# which a killed suite (CI cancel, Ctrl-C) never reaches — and being unnamed,
# they did not even match the suite's own `loop-eng-*` leak scan.
FAKE_PY=$(mktemp -d "${TMPDIR:-/tmp}/loop-eng-nojq.XXXXXX")
FAKE_NONE=$(mktemp -d "${TMPDIR:-/tmp}/loop-eng-noparser.XXXXXX")
trap 'rm -rf "$SB" "$FAKE_PY" "$FAKE_NONE"' EXIT
cd "$SB" || exit 1
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

# --- P2-2: while armed, a Bash rm/mv aimed at .loop ITSELF takes the stop-gate's
#     marker, the hash-lock and the ledger in ONE command — every layer at once.
#     It is not an adversarial shape: README hands humans `rm -rf .loop` as the
#     cleanup command, so it is the likeliest way a non-adversarial session ends
#     up with a silently disarmed loop. Deny while armed and name the two-step
#     form, exactly as the active+sha256 wrap-up above does.
#     The boundary matters as much as the deny: a SUBPATH must be unaffected.
#     .loop/state.md is the orchestrator's own scratch file and has never been
#     guarded, and `.loopback` is a different directory that merely shares the
#     prefix — a `\b`-style boundary would swallow both. ---
gate "${B/CMD/rm -rf .loop}";                     assert_eq 2 $? "Bash rm -rf .loop denied when armed"
gate "${B/CMD/rm -rf .loop/}";                    assert_eq 2 $? "Bash rm -rf .loop/ (trailing slash) denied when armed"
gate "${B/CMD/rm -rf .loop; echo done}";          assert_eq 2 $? "Bash rm -rf .loop before a ; denied when armed"
gate "${B/CMD/rm -rf ./.loop}";                   assert_eq 2 $? "Bash rm -rf ./.loop denied when armed"
gate "${B/CMD/mv .loop .loop.bak}";               assert_eq 2 $? "Bash mv of the whole .loop dir denied when armed"
printf '%s' "${B/CMD/rm -rf .loop}" | bash "$GATE" 2>.loop/err2 || true
assert_file_contains .loop/err2 'rm .loop/active' "whole-dir deny names the disarm-first step"
gate "${B/CMD/rm .loop/state.md}";                assert_eq 0 $? "Bash rm .loop/state.md still allowed when armed"
gate "${B/CMD/rm -rf .loopback}";                 assert_eq 0 $? "Bash rm of a same-prefix sibling dir allowed when armed"
gate "${B/CMD/echo see .loop for the logs}";      assert_eq 0 $? "naming .loop with no write verb allowed when armed"

# --- P3-12: a MACHINE-TICKED backlog joins the protected set while armed -----
# A backlog whose lines carry `| verify: <cmd>` is ticked by run-contract from
# the command's exit status, so a model write to it is a completion claim typed
# into the file the ledger exists to produce. A backlog with no verify commands
# keeps the old model-ticked contract and stays writable — opting in is what
# locks it, so nobody's existing loop changes under them.
printf -- '- [ ] plain item\n' > .loop/backlog.md
gate "${W/FILE/.loop/backlog.md}";                assert_eq 0 $? "an opt-out backlog stays writable when armed"
gate "${B/CMD/sed -i s/x/y/ .loop/backlog.md}";   assert_eq 0 $? "Bash write to an opt-out backlog allowed when armed"
printf -- '- [ ] machine item | verify: true\n' > .loop/backlog.md
gate "${W/FILE/.loop/backlog.md}";                assert_eq 2 $? "Write to a machine-ticked backlog denied when armed"
gate "${E/FILE/.loop/backlog.md}";                assert_eq 2 $? "Edit to a machine-ticked backlog denied when armed"
gate "${W/FILE/$SB/.loop/backlog.md}";            assert_eq 2 $? "abs-path machine-ticked backlog denied when armed"
gate "${B/CMD/sed -i s/x/y/ .loop/backlog.md}";   assert_eq 2 $? "Bash sed -i on a machine-ticked backlog denied when armed"
gate "${B/CMD/echo x > .loop/backlog.md}";        assert_eq 2 $? "Bash redirect into a machine-ticked backlog denied when armed"
printf '%s' "${W/FILE/.loop/backlog.md}" | bash "$GATE" 2>.loop/err3 || true
assert_file_contains .loop/err3 'verify:' "the backlog deny names what made the file machine-ticked"
# This gate's opt-in probe is FILE-level, so an ORDERED-list item locks the
# whole backlog while run-contract ticks only `-`/`*`/`+` bullets. A deliberate
# boundary, not an oversight: pinned on both sides (the runner half lives in
# tests/test-run-contract.sh) so the residual stays a known, tested state.
printf -- '1. [ ] ordered item | verify: true\n' > .loop/backlog.md
gate "${W/FILE/.loop/backlog.md}";                assert_eq 2 $? "an ordered-list verify line locks the backlog, though the runner cannot tick it"
printf -- '- [ ] machine item | verify: true\n' > .loop/backlog.md

# --- results.json/evidence: always denied, armed or not ---
gate "${W/FILE/.loop/results.json}";              assert_eq 2 $? "results.json denied while armed"
rm -f .loop/active
# The whole-dir deny is armed-scoped like the contract lock: once the loop has
# ended, `rm -rf .loop` is the documented cleanup and must go through.
gate "${B/CMD/rm -rf .loop}";                     assert_eq 0 $? "Bash rm -rf .loop allowed when not armed"
# So is the backlog lock — between loops the next backlog has to be writable.
gate "${W/FILE/.loop/backlog.md}";                assert_eq 0 $? "machine-ticked backlog writable when not armed"
rm -f .loop/backlog.md
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

# --- P0-A: .loop/verify.sh joins the armed protected set ---------------------
# In a legacy loop verify.sh IS the contract: arm-contract.sh arms without a
# criteria.tsv and the stop-gate then runs this script. It was the one gate
# input still absent from the protected set, so a model could rewrite its own
# gate to `exit 0` — on that path "passes: true can only be produced by running
# the contract" simply did not hold. Armed-scoped like criteria.tsv: authoring a
# verify.sh BEFORE arming is the legitimate case and stays writable; freezing it
# once the loop is live is the point. Create as well as overwrite, for the same
# reason criteria.tsv denies the create — handing the gate a script it did not
# have is the same hijack as replacing the one it had.
gate "${W/FILE/.loop/verify.sh}";                 assert_eq 0 $? "Write verify.sh allowed when not armed"
printf '#!/usr/bin/env bash\nexit 1\n' > .loop/verify.sh
touch .loop/active
gate "${W/FILE/.loop/verify.sh}";                 assert_eq 2 $? "overwrite verify.sh denied when armed"
gate "${E/FILE/.loop/verify.sh}";                 assert_eq 2 $? "Edit verify.sh denied when armed"
gate "${W/FILE/$SB/.loop/verify.sh}";             assert_eq 2 $? "abs-path verify.sh denied when armed"
gate "${B/CMD/echo exit 0 > .loop/verify.sh}";    assert_eq 2 $? "Bash redirect into verify.sh denied when armed"
gate "${B/CMD/sed -i s/1/0/ .loop/verify.sh}";    assert_eq 2 $? "Bash sed -i on verify.sh denied when armed"
gate "${B/CMD/rm .loop/verify.sh}";               assert_eq 2 $? "Bash rm of verify.sh denied when armed"
# Executing the gate's own script is not writing it — a legacy loop has to be
# able to RUN the very file this rule freezes.
gate "${B/CMD/bash .loop/verify.sh}";             assert_eq 0 $? "running verify.sh still allowed when armed"
rm -f .loop/verify.sh
gate "${W/FILE/.loop/verify.sh}";                 assert_eq 2 $? "create verify.sh denied when armed (no prior file)"
printf '%s' "${W/FILE/.loop/verify.sh}" | bash "$GATE" 2>.loop/errV || true
assert_file_contains .loop/errV 'verify.sh' "the verify.sh deny names the file it froze"
rm -f .loop/active .loop/errV
gate "${W/FILE/.loop/verify.sh}";                 assert_eq 0 $? "verify.sh writable again once the loop is disarmed"

# --- L2: NotebookEdit carries the target in notebook_path, not file_path; the
#     gate must read it or NotebookEdit is a blind spot into the ledger. ---
N='{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"FILE"}}'
gate "${N/FILE/.loop/results.json}";              assert_eq 2 $? "NotebookEdit notebook_path results.json denied"
gate "${N/FILE/src/notebook.ipynb}";              assert_eq 0 $? "NotebookEdit unrelated notebook allowed"

# --- TC-1: MultiEdit sits in the write-tool arm and nothing pinned it there ---
# Deleting `MultiEdit|` from the `case "$TOOL"` arm left all 834 assertions
# green: the tool most likely to rewrite a ledger in bulk was held in the
# protected set by prompt-strength alone.
M='{"tool_name":"MultiEdit","tool_input":{"file_path":"FILE"}}'
gate "${M/FILE/.loop/results.json}";              assert_eq 2 $? "MultiEdit results.json denied"
gate "${M/FILE/.loop/evidence/1.log}";            assert_eq 2 $? "MultiEdit evidence log denied"
gate "${M/FILE/src/app.js}";                      assert_eq 0 $? "MultiEdit unrelated file allowed"
touch .loop/active
gate "${M/FILE/.loop/criteria.tsv}";              assert_eq 2 $? "MultiEdit armed criteria.tsv denied"
gate "${M/FILE/.loop/verify.sh}";                 assert_eq 2 $? "MultiEdit armed verify.sh denied"
rm -f .loop/active

# --- unrelated paths allowed ---
gate "${W/FILE/src/app.js}";                      assert_eq 0 $? "unrelated Write allowed"
gate "${W/FILE/.loop/state.md}";                  assert_eq 0 $? ".loop/state.md Write allowed"

# --- Bash: write-ish operators on always-protected paths denied, benign allowed ---
gate "${B/CMD/echo done > .loop/results.json}";   assert_eq 2 $? "Bash redirect to results.json denied"
gate "${B/CMD/sed -i s,false,true, .loop/results.json}"; assert_eq 2 $? "Bash sed -i results.json denied"
gate "${B/CMD/bash .loop/verify.sh}";             assert_eq 0 $? "running verify.sh allowed"
gate "${B/CMD/cat .loop/results.json}";           assert_eq 0 $? "reading results.json allowed"
gate "${B/CMD/git add .loop/results.json}";       assert_eq 0 $? "git add allowed"

# --- FP fix: a literal `->` arrow must NOT be read as a `>` redirect verb.
#     "logs -> $(ls .loop/evidence/)" only READS the ledger via a subshell; the
#     arrow's `>` used to trip the redirect branch. Stripping `->` before the
#     match preserves every real redirect while dropping this false positive. ---
gate "${B/CMD/echo \"logs -> \$(ls .loop\/evidence\/ | wc -l)\"}"; assert_eq 0 $? "arrow-then-mention of evidence/ (read subshell) allowed"
gate "${B/CMD/echo \"count -> \$(ls .loop\/results.json)\"}";      assert_eq 0 $? "arrow-then-mention of results.json allowed"
# --- but real redirects with a nearby arrow-in-data must STILL be denied ---
gate "${B/CMD/printf '1->2' > .loop\/results.json}"; assert_eq 2 $? "real redirect denied even when payload contains an arrow"

# --- TP preservation after the `->` strip: every real write path still denied ---
gate "${B/CMD/echo x >> .loop\/results.json}";        assert_eq 2 $? "append >> results.json still denied"
gate "${B/CMD/tee .loop\/results.json}";              assert_eq 2 $? "tee results.json still denied"
gate "${B/CMD/rm .loop\/evidence\/1.log}";            assert_eq 2 $? "rm evidence log still denied"
gate "${B/CMD/mv x .loop\/results.json}";             assert_eq 2 $? "mv into results.json still denied"

# --- three write shapes the first version of the pattern let straight through ---
# None of them is an evasion; each is how someone normally types the command.
#   `.loop/evidence` without the trailing slash — the slash was REQUIRED, so the
#     plain directory name (how anyone writes an rm) matched nothing.
#   `>|` — the noclobber override, i.e. "overwrite anyway", while the verb group
#     stopped at `>>?`.
#   `.loop//results.json` — a doubled slash is the same path to every OS.
gate "${B/CMD/rm -rf .loop\/evidence}";               assert_eq 2 $? "rm of the evidence DIR without a trailing slash is denied"
gate "${B/CMD/rm -rf .loop\/evidence; true}";         assert_eq 2 $? "…including when another command follows it"
gate "${B/CMD/echo x >| .loop\/results.json}";        assert_eq 2 $? "noclobber-override redirect (>|) into results.json is denied"
gate "${B/CMD/echo x > .loop\/\/results.json}";       assert_eq 2 $? "doubled slash in the ledger path is denied"

# ...and the siblings that share the prefix are NOT the ledger, so widening the
# pattern must not swallow them. (A `\b` after `evidence` would: it counts `-`
# and `.` as boundaries, which is why the pattern tests for "not a filename
# character" instead.)
gate "${B/CMD/rm .loop\/evidence-notes.md}";          assert_eq 0 $? "a sibling file whose name starts with 'evidence-' is not the ledger"
gate "${B/CMD/rm .loop\/evidence.bak}";               assert_eq 0 $? "a sibling file whose name starts with 'evidence.' is not the ledger"
gate "${B/CMD/echo x > .loop\/evidencelog}";          assert_eq 0 $? "a sibling file whose name merely starts with 'evidence' is not the ledger"

# --- deny message names the mention-only false-positive escape ---
printf '%s' "${W/FILE/.loop/results.json}" | bash "$GATE" 2>.loop/err || true
assert_file_contains .loop/err 'only NAMES a guarded path' "deny explains the mention-only false positive"

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
  FAKE="$FAKE_PY"
  # Mirror the tools the gate uses (bash for its own subshells, cat for stdin,
  # python3 for the fallback parser, plus the coreutils the path checks call) —
  # everything EXCEPT jq, so `command -v jq` fails and the python3 branch runs.
  # `sha256sum` used to be in this list and never belonged: the gate does not
  # hash anything — it path-matches `.loop/criteria.sha256` as a string
  # (evidence-gate.sh:122, :192) — and the tool is absent on stock macOS, so the
  # symlink loop silently produced a different environment there than the one
  # this block names. A missing prerequisite now says so instead of leaving the
  # arm to fail as something unrelated.
  missing=""
  for t in bash cat python3 grep dirname sed; do
    src=$(command -v "$t") && ln -sf "$src" "$FAKE/$t" || missing="$missing $t"
  done
  if [ -n "$missing" ]; then
    echo "  SKIP: fake-PATH prerequisite(s) not on PATH —$missing — the python3-fallback arm did not run" >&2
  elif ! PATH="$FAKE" bash -c 'command -v jq' >/dev/null 2>&1; then
    printf '%s' "${W/FILE/.loop/results.json}" | PATH="$FAKE" bash "$GATE" 2>/dev/null
    assert_eq 2 $? "python3 fallback (no jq): Write results.json still denied"
    printf '%s' "${W/FILE/src/app.js}" | PATH="$FAKE" bash "$GATE" 2>/dev/null
    assert_eq 0 $? "python3 fallback (no jq): unrelated Write still allowed"
    # TC-2: the fallback parser's CMD line is what the whole Bash branch reads,
    # and only its FILE line was pinned — breaking the CMD extraction left 834
    # assertions green while every Bash deny went silent in jq-less
    # environments. The tool_name half is pinned by the same call: a broken
    # TOOL line lands in neither branch and the write is allowed.
    printf '%s' "${B/CMD/echo done > .loop/results.json}" | PATH="$FAKE" bash "$GATE" 2>/dev/null
    assert_eq 2 $? "python3 fallback (no jq): Bash redirect to results.json still denied"
    printf '%s' "${B/CMD/rm -rf .loop/evidence}" | PATH="$FAKE" bash "$GATE" 2>/dev/null
    assert_eq 2 $? "python3 fallback (no jq): Bash rm of the evidence dir still denied"
    printf '%s' "${B/CMD/cat .loop/results.json}" | PATH="$FAKE" bash "$GATE" 2>/dev/null
    assert_eq 0 $? "python3 fallback (no jq): benign Bash read still allowed"
    # NotebookEdit's notebook_path is read by the fallback's own `or` chain, a
    # second untested half of the same three lines.
    printf '%s' "${N/FILE/.loop/results.json}" | PATH="$FAKE" bash "$GATE" 2>/dev/null
    assert_eq 2 $? "python3 fallback (no jq): NotebookEdit notebook_path still denied"
  else
    echo "  SKIP: could not hide jq from PATH — python3 branch not forced" >&2
  fi
  # cleanup is the EXIT trap's, not an inline rm a killed suite would skip
fi

# --- NEITHER parser present: the gate fails OPEN, loudly ---
# This is a deliberate design choice (a PreToolUse hook must never brick a
# session), but it is also the one environment in which the gate looks installed
# and enforces nothing — so pin BOTH halves. The exit code keeps the fail-open
# honest; the warning on stderr is the only signal a human gets that the layer
# is inert, and a silent version of this path is indistinguishable from a
# working gate. README's "Requirements" section documents it for users.
FAKE="$FAKE_NONE"
# Only what the gate itself needs to reach its own parser check — no jq, no
# python3. `cat` is required: the gate reads stdin before deciding anything.
for t in bash cat grep dirname sed; do
  src=$(command -v "$t") && ln -sf "$src" "$FAKE/$t"
done
if ! PATH="$FAKE" bash -c 'command -v jq || command -v python3' >/dev/null 2>&1; then
  printf '%s' "${W/FILE/.loop/results.json}" | PATH="$FAKE" bash "$GATE" 2>.loop/noparser
  assert_eq 0 $? "no jq and no python3: gate fails OPEN (never bricks the session)"
  assert_file_contains .loop/noparser 'no jq or python3 available' \
    "no jq and no python3: the inert gate says so on stderr"
else
  echo "  SKIP: could not hide both jq and python3 from PATH" >&2
fi
# cleanup is the EXIT trap's (see the top of this file)

report "test-evidence-gate"
