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

cd "$PLUGIN_ROOT"

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

report "test-packaging"
