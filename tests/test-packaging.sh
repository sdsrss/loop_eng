#!/usr/bin/env bash
# packaging: what the README tells a user to RUN must actually be runnable from
# a fresh install.
#
# A marketplace install materializes the git tree with its recorded file modes,
# so a script the README documents as a bare-path command (`skills/.../x.sh …`,
# no `bash` prefix) must carry the exec bit IN THE INDEX — otherwise the very
# first thing a new user pastes answers "Permission denied", and no test in the
# suite sees it because every other suite invokes the scripts as `bash <path>`.
#
# The list is DERIVED from README.md rather than hardcoded: a runner documented
# tomorrow is covered tomorrow, without anyone remembering to extend this file.
set -u
. "$(dirname "$0")/lib.sh"

cd "$PLUGIN_ROOT" || exit 1

# Bare-path invocations in README code fences: an optional ./ then a repo-relative
# *.sh at the start of a line. A line that starts with `bash ` is NOT a bare-path
# invocation and is deliberately not matched — those work at any mode.
DOCUMENTED=$(grep -oE '^(\./)?(skills|scripts)/[A-Za-z0-9_/.-]+\.sh' README.md | sed 's|^\./||' | sort -u)

# Fail closed on a regex that matched nothing: a silently empty candidate set
# would make every assertion below vacuous and this suite would report green
# while checking zero files.
count=$(printf '%s\n' "$DOCUMENTED" | grep -c '[^[:space:]]' || true)
if [ "$count" -eq 0 ]; then
  FAIL=$((FAIL+1))
  echo "  FAIL: README bare-path scan matched no scripts — the pattern has rotted" >&2
else
  PASS=$((PASS+1))
fi

for f in $DOCUMENTED; do
  if [ ! -f "$f" ]; then
    FAIL=$((FAIL+1)); echo "  FAIL: README documents $f but it does not exist" >&2
    continue
  fi
  # The mode that actually ships is the one git records, not the one the working
  # tree happens to have.
  mode=$(git ls-files -s -- "$f" | awk '{print $1}')
  assert_eq "100755" "$mode" "README runs '$f' bare-path, so it must ship executable"
  if [ -x "$f" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $f is not executable in the working tree" >&2
  fi
done

# Conversely: a script the README only ever invokes via `bash <path>` needs no
# exec bit, and the hooks are always spawned as `bash "${CLAUDE_PLUGIN_ROOT}/..."`
# by hooks.json — assert that contract so nobody "fixes" the hook modes instead
# of the hooks.json command, which is what actually decides how they start.
while IFS= read -r hookcmd; do
  case "$hookcmd" in
    bash\ *) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1)); echo "  FAIL: hooks.json command not spawned via bash: $hookcmd" >&2 ;;
  esac
done < <(grep -o '"command": "[^"]*"' hooks/hooks.json | sed 's/"command": "//; s/"$//')

# --- prompt invariants the mechanism layer cannot enforce -------------------
# The stop rules, the round budget and the failure-identity contract live only
# in Markdown, so nothing catches a re-edit that reintroduces a contradiction.
# These are shallow grep assertions on purpose — they cannot prove the prompt
# WORKS, only that the four specific contradictions the audit found stay fixed.
# Same technique as the README-derived checks above: pin the text that carries
# a decision, so changing the decision is a visible test failure rather than a
# silent drift between two files that must agree.

has() { # $1=file $2=fixed-string $3=label
  if grep -qF -- "$2" "$1"; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $3 — $1 no longer contains [$2]" >&2; fi
}
hasnt() { # $1=file $2=fixed-string $3=label
  if grep -qF -- "$2" "$1"; then
    FAIL=$((FAIL+1)); echo "  FAIL: $3 — $1 still contains [$2]" >&2
  else PASS=$((PASS+1)); fi
}

# Stop rule 3 keys on the builder's named root cause, not on the failure. Keyed
# on the failure it fired on a builder that WAS progressing: the builder fixes
# one root cause per round by design, so a criterion with two causes behind it
# repeats its failure after the first is fixed.
has   commands/autoloop.md "Same root cause two rounds in a row" "stop rule 3 keys on the root cause"
hasnt commands/autoloop.md "Same failure two rounds in a row"    "stop rule 3 no longer keys on the failure"
has   agents/loop-builder.md "Root cause: <the cause you fixed this round" "the builder reports the root cause stop rule 3 compares"

# Stop rule 5 counts RED criteria from the machine ledger. The checker merges
# failures per file for readability, so its list length tracks how defects are
# distributed across files, not how many there are.
has commands/autoloop.md "number of RED criteria in \`.loop/results.json\`" "stop rule 5 counts from the ledger, not the checker's list"

# A failure needs an identity that survives an edit. file:line does not: it
# moves with every line inserted above it.
has agents/loop-checker.md '[<criterion-id>] file:line' "checker failures carry the criterion id"

# Step 3 must not read a per-item ALL GREEN as "the loop is done" — on a
# multi-item backlog round 1 legitimately reports ALL GREEN for item 1.
has   commands/autoloop.md "that verdict is about THIS" "step 3 scopes ALL GREEN to the current item"
hasnt commands/autoloop.md "If the checker's report starts with \`ALL GREEN\`: stop." "step 3 no longer stops the loop on the first item's ALL GREEN"

# The round budget is total, not per item.
has   commands/autoloop.md "TOTAL budget for the invocation, not a per-item allowance" "round budget is stated as total"

# The synchronous-dispatch instruction must not name a parameter the Agent tool
# does not have — an instruction that cannot be carried out is not a mitigation.
hasnt commands/autoloop.md "set \`run_in_background:false\`" "dispatch guidance does not name a nonexistent tool parameter"

# P2-13. `allowed-tools` is a PRE-AUTHORIZATION list, and the subagent tool is
# now named Agent; `Task` is the old name. Listing only the old one costs a
# permission prompt on every dispatch in interactive mode (bypass mode hides
# it), and `claude plugin validate` does not check tool names, so nothing else
# would catch the drift. Both are listed until the alias is proven dead.
for c in commands/autoloop.md commands/polish.md; do
  has "$c" "Task, Agent" "$c pre-authorizes both the old and current subagent tool name"
done

# P2-11. "No write access by design" was stronger than the mechanism. These
# three agents have no Write/Edit — that part is real, enforced by the tool
# whitelist — but they all have Bash, which writes. The claim had to come down
# to what is actually true, and the red line it was standing in for had to be
# stated as a red line.
for a in agents/loop-checker.md agents/loop-reviewer.md agents/loop-verifier.md; do
  hasnt "$a" "no write access by design" "$a no longer claims a guarantee its Bash tool breaks"
  has   "$a" "no Write or Edit tool" "$a states the part the tool whitelist actually enforces"
  has   "$a" "not for writing"       "$a states the Bash red line instead of implying it is impossible"
done

# ...and the same overclaim, in the file the sweep above did not cover. SKILL.md
# said "loop-checker cannot [write]" for as long as the agent files said "no
# write access by design", and survived the round that removed it from them —
# a ban is only worth what its scope covers. The positive assertion is what
# stops the short version coming back as a "simplification".
hasnt skills/loop-eng/SKILL.md "loop-checker cannot" \
  "SKILL.md does not claim the checker cannot write — it has Bash"
has   skills/loop-eng/SKILL.md "no Write or Edit tool" \
  "SKILL.md states the whitelist claim in the same terms the agent files do"

# P2-12. The template's FAST subset is what the stop-gate runs on every stop
# attempt under a 100s budget, and it shipped with `npm test` in it — a typical
# JS suite overruns, the gate blocks as a fail-closed timeout, three of those
# reach the ceiling, and ALL GREEN can never be machine-confirmed. The full
# suite belongs in the block that says "final round".
has   skills/loop-eng/templates/contract.md "Full suite (final round)" "the template still has a full-suite block"
hasnt skills/loop-eng/templates/contract.md "1	All tests pass	npm test" "the fast subset no longer ships an unscoped whole-suite command"

# P2-10. The verify commands had two sources of truth — contract.md for the
# checker, criteria.tsv for the gate — both model-written, with nothing binding
# them. criteria.tsv is the one that RUNS, so it is the one that decides.
has agents/loop-checker.md ".loop/criteria.tsv" "the checker reads the contract the gate actually executes"
has commands/autoloop.md "the ledger wins" "step 3 has a branch for a green report over a red ledger"

# --- P3-5 / P2-15: documentation that DERIVES from the tree, not from memory --
# Three README sections restate facts the repo already knows, and all three had
# drifted: the env-var table was missing a variable, the layout block named two
# of the four hooks and called six unattended scripts "unattended runner", and
# two different paragraphs disagreed about how many scripts hold the bash-3.2
# floor. Each assertion below reads the source of truth and compares, so the
# next addition is covered the day it lands rather than the day someone
# remembers — the same reasoning as the README-derived exec-bit scan above.

# Every LOOP_ENG_* a shipped script reads must be in the README table, and every
# row in the table must name a variable some script reads.
# shellcheck disable=SC2046  # the file list must word-split; same as run-all.sh
CODE_VARS=$(grep -ohE 'LOOP_ENG_[A-Z_]+' $(git ls-files '*.sh') | sort -u)
DOC_VARS=$(grep -oE '^\| `LOOP_ENG_[A-Z_]+`' README.md | tr -d '|` ' | sort -u)
undocumented=$(comm -23 <(printf '%s\n' "$CODE_VARS") <(printf '%s\n' "$DOC_VARS") | tr '\n' ' ')
phantom=$(comm -13 <(printf '%s\n' "$CODE_VARS") <(printf '%s\n' "$DOC_VARS") | tr '\n' ' ')
assert_eq "" "${undocumented% }" "every LOOP_ENG_* the scripts read has a README row"
assert_eq "" "${phantom% }"      "every README env row names a variable some script reads"
assert_eq "" "$(printf '%s\n' "$CODE_VARS" | grep -c '^$' | grep -v '^0$')" "the env-var scan matched something (pattern not rotted)"

# The layout block must name every tracked hook script. It named two of four.
LAYOUT=$(sed -n '/^## Repository layout$/,/^## /p' README.md)
for h in $(git ls-files 'hooks/*.sh'); do
  case "$LAYOUT" in
    *"$(basename "$h")"*) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1)); echo "  FAIL: README layout block does not name $h" >&2 ;;
  esac
done
# ...and must not describe the six unattended/skill scripts in the singular.
case "$LAYOUT" in
  *"unattended runner"*) FAIL=$((FAIL+1)); echo "  FAIL: layout block still says 'unattended runner' (singular) for $(git ls-files 'skills/loop-eng/scripts/*.sh' | wc -l | tr -d ' ') scripts" >&2 ;;
  *) PASS=$((PASS+1)) ;;
esac

# The bash-3.2 floor is a CI fact: whatever test.yml syntax-checks under
# /bin/bash IS the list, and the README must not name a different number.
FLOOR=$(sed -n '/Syntax-check the hooks-only scripts/,$p' .github/workflows/test.yml \
          | grep -oE '(hooks|skills/loop-eng/scripts)/[a-z-]+\.sh' | sort -u)
floor_n=$(printf '%s\n' "$FLOOR" | grep -c '[^[:space:]]')
assert_eq 5 "$floor_n" "the bash-3.2 CI leg covers five scripts"
for f in $FLOOR; do
  b=$(basename "$f")
  if grep -q "$b" <(sed -n '/^Bash compatibility:/,/^$/p' README.md); then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: README's Bash-compatibility paragraph omits $b, which the test-bash32 job covers" >&2; fi
done

# P3-9. /polish has four stop rules and three macro rounds; SKILL.md described
# both loops with /autoloop's six-and-five.
hasnt skills/loop-eng/SKILL.md "Six stop rules bound every loop at 5 rounds max" "SKILL.md no longer gives both loops /autoloop's caps"
has   skills/loop-eng/SKILL.md "three macro rounds" "SKILL.md states /polish's own round cap"

# --- P2-17: the release gate's WIRING, checked here because its verdict can
#     only be produced in CI ---
# The gate itself compares the tag against the manifests, and that comparison
# needs a tag, so it cannot run locally. What can be checked locally is that it
# is wired at all: a workflow that never fires is indistinguishable from the
# manual checklist it replaced.
REL=.github/workflows/release.yml
if [ -f "$REL" ]; then
  PASS=$((PASS+1))
  has "$REL" "tags: ['v*']" "the release gate fires on a v* tag"
  has "$REL" "uses: ./.github/workflows/test.yml" "the release gate re-runs THE suite, not a copy of it"
  has "$REL" "contents: read" "the release gate has read-only permissions (it publishes nothing)"
  has .github/workflows/test.yml "workflow_call:" "test.yml is callable, or the release gate's suite job cannot run"
  # The three manifest fields the gate compares must be the three that exist.
  # Named here so renaming one in the manifests reddens a fast local suite
  # rather than a tag push.
  for field in '"version"' 'metadata.version' 'plugins\[0\].version'; do
    if grep -qF -- "$field" "$REL" || grep -q -- "$field" "$REL"; then PASS=$((PASS+1)); else
      FAIL=$((FAIL+1)); echo "  FAIL: the release gate does not mention the manifest field $field" >&2; fi
  done
else
  FAIL=$((FAIL+1)); echo "  FAIL: $REL is missing — tag pushes are unchecked again" >&2
fi

report "test-packaging"
