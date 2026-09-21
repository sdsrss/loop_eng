#!/usr/bin/env bash
# loop-eng arm-contract — machine-arm the stop-gate for /autoloop.
#
# Replaces the manual `touch .loop/active`. Records the SHA-256 of the
# just-authored criteria.tsv into .loop/criteria.sha256, then arms the loop
# (.loop/active) and clears any stale block counter. run-contract.sh verifies
# that hash on every stop attempt and fails CLOSED if criteria.tsv no longer
# matches — so weakening an armed contract can never pass silently, whatever
# write path is used (Write/Edit tool OR Bash verbs the evidence-gate regex
# can't see). The hash is captured at arm time, right after the human/orchestrator
# authors the contract and before the builder runs.
#
# Honest scope: a fully adversarial model with arbitrary Bash could rewrite BOTH
# criteria.tsv and criteria.sha256 to a matching weakened pair. That residual is
# covered by the red lines in the command prompts and human review of the diff —
# note that .loop/ is gitignored, so a weakened contract is invisible in git.
set -u

# LOOP_ENG_LOOP_DIR is a TEST-ONLY knob (the plugin's own suite sandboxes with
# it). The stop-gate and evidence-gate are fixed to .loop/ — arming a custom
# dir in production means NEITHER hook watches it (silently disarmed loop).
LOOP_DIR="${LOOP_ENG_LOOP_DIR:-.loop}"
CRIT="$LOOP_DIR/criteria.tsv"
SHA_LOCK="$LOOP_DIR/criteria.sha256"
ACTIVE="$LOOP_DIR/active"
COUNT_FILE="$LOOP_DIR/gate-count"

# Every write to $LOOP_DIR below is CHECKED, and a failed one is fatal.
# arm-contract exits 0 on every other path and reports on stderr what it did, so
# an unchecked failed write printed the success lines over a $LOOP_DIR that got
# neither: "pinned criteria.tsv @ <hash>" with no hash-lock on disk, and
# "stop-gate armed" with no $ACTIVE. Without $ACTIVE the stop-gate returns at its
# first line (hooks/stop-gate.sh: `[ -f "$ACTIVE" ] || exit 0`), so the stop it
# exists to block is allowed, and the evidence-gate's lock on criteria.tsv — also
# keyed on $ACTIVE — never engages, leaving the armed contract FILE model-writable
# (results.json and evidence/ stay protected either way). An arm that reports
# success over that state is the one failure this plugin cannot afford: silently
# unenforced, in the script whose whole job is to enforce.
#
# Refusing is fail-closed here even though it leaves the loop unarmed: the
# alternative is arming a loop whose contract is not pinned, and a loop that
# never armed is loud (exit 73 + this message), where a mis-armed one is silent.
# 73 = EX_CANTCREAT, exactly what run-contract.sh's cannot_write() exits for the
# same class of failure, so both halves of the machinery tell one story. The raw
# bash/mkdir diagnostic is deliberately NOT swallowed — it carries the errno
# ("Permission denied" vs "No space left on device") this message cannot know.
cannot_arm() { # $1 = path, $2 = why
  echo "loop-eng arm-contract: FATAL — cannot write $1 ($2); refusing to arm (fail closed). An arm that cannot record the contract has armed nothing: the stop-gate only runs while $ACTIVE exists, so reporting success here would leave the loop silently unenforced. Check permissions and free space under $LOOP_DIR/." >&2
  exit 73
}

mkdir -p "$LOOP_DIR" || cannot_arm "$LOOP_DIR" "mkdir failed"

# The whole chain assumes git ignores $LOOP_DIR/, and nothing made it so.
#
# The builder commits with `git add -A`. In a repo whose .gitignore does not
# list it, that commits criteria.tsv, criteria.sha256, results.json and
# evidence/ — after which the stop-gate rewrites results.json on every stop, the
# tree is permanently ` M .loop/results.json`, and BOTH unattended drivers
# refuse to run ("dirty tree, refusing") for good. Verified end to end: five
# .loop files committed, then a wedged tree. README asserted the directory "is
# gitignored" without anything making it true; this repo's own .gitignore,
# tests/lib.sh and RELEASING.md each hand-write the line, so the assumption was
# known — the Install instructions just never said it.
#
# Written into .git/info/exclude, not the user's .gitignore: it is local and
# untracked, so arming a loop never turns into a diff in someone's PR.
#
# Already-tracked is the case the exclude file cannot fix — git ignores nothing
# it already tracks — so it warns instead, and names the one command that undoes
# it. Advisory, not fail-closed: the loop still runs, it just cannot promise the
# tree stays clean, and stranding a loop over bookkeeping would be the worse
# trade (same reasoning as the missing-hash-lock warning further down).
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [ -n "$(git ls-files -- "$LOOP_DIR" 2>/dev/null)" ]; then
    echo "loop-eng arm-contract: WARNING — $LOOP_DIR/ is TRACKED by git. Loop bookkeeping (results.json, evidence/) is rewritten on every stop, so the tree will never be clean again and the unattended drivers will refuse to run. Untrack it with: git rm -r --cached $LOOP_DIR && echo '$LOOP_DIR/' >> .gitignore && git commit -m 'untrack loop bookkeeping'" >&2
  elif ! git check-ignore -q "$LOOP_DIR/results.json" 2>/dev/null; then
    GIT_EXCLUDE="$(git rev-parse --git-dir 2>/dev/null)/info/exclude"
    if mkdir -p "$(dirname "$GIT_EXCLUDE")" 2>/dev/null \
       && printf '%s\n' "$LOOP_DIR/" >> "$GIT_EXCLUDE" 2>/dev/null; then
      echo "loop-eng arm-contract: $LOOP_DIR/ was not ignored by git; added it to $GIT_EXCLUDE (local only — your .gitignore is untouched). Loop bookkeeping must not be committed: the builder's \`git add -A\` would otherwise commit it and leave the tree permanently dirty." >&2
    else
      echo "loop-eng arm-contract: WARNING — $LOOP_DIR/ is not ignored by git and the local exclude file could not be written. The builder's \`git add -A\` will commit loop bookkeeping and the tree will never be clean again. Add '$LOOP_DIR/' to .gitignore before continuing." >&2
    fi
  fi
fi

loop_sha256() { # portable SHA-256 of a file -> stdout (empty if no tool)
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | awk '{print $NF}'
  fi
}

if [ -f "$CRIT" ]; then
  # ONE parse, shared by every check in this block and written to match
  # run-contract.sh line for line. This file used to carry FOUR different
  # splits — two `awk -F'\t'` (which does not collapse TABs) and two
  # `IFS=$'\t' read` (which does, because TAB is IFS whitespace) — and they
  # disagreed on exactly one shape: `id<TAB><TAB>cmd`, a criterion with an empty
  # description. awk called it runnable, so arming warned about nothing and
  # pinned the hash; the two read loops saw an empty command and skipped it, so
  # neither advisory check ever looked at it; and run-contract, reading it the
  # same collapsing way, called it malformed and failed CLOSED on every stop —
  # with a message blaming SPACES in a file that contains none. By then the
  # evidence-gate had locked criteria.tsv, so the loop could only end by hitting
  # a stop rule. One rule, in one place per script, is the fix.
  #
  # The rule: split on the FIRST TWO TABs. Everything after the second TAB is
  # the command. Blank/whitespace-only lines and #comments (indent tolerated)
  # are skipped. Fewer than two TABs, an empty id, or an empty command is
  # malformed. An EMPTY DESCRIPTION is legal — arm does not use the description
  # column at all, so it is stepped over rather than named.
  runnable=0
  malformed=""
  crit_lineno=0
  crit_line=""
  while IFS= read -r crit_line || [ -n "$crit_line" ]; do
    crit_lineno=$((crit_lineno + 1))
    crit_line="${crit_line%$'\r'}"
    # UTF-8 BOM on line 1, stripped exactly where run-contract.sh strips it. Arm
    # and run must name the same id: every warning below exists so a human can
    # find the criterion BEFORE the evidence-gate locks the file, and a warning
    # naming "﻿baseline" for a ledger entry that says "baseline" sends them
    # looking for a criterion that does not exist. Same failure shape as the
    # empty-description split the two scripts were made to share.
    [ "$crit_lineno" -eq 1 ] && crit_line="${crit_line#$'\xef\xbb\xbf'}"
    case "$crit_line" in
      *[![:space:]]*) : ;;
      *) continue ;;
    esac
    case "${crit_line#"${crit_line%%[![:space:]]*}"}" in \#*) continue ;; esac
    case "$crit_line" in
      *$'\t'*$'\t'*)
        c_id="${crit_line%%$'\t'*}"
        c_rest="${crit_line#*$'\t'}"
        c_cmd="${c_rest#*$'\t'}" ;;
      *) c_id="$crit_line"; c_cmd="" ;;
    esac
    if [ -z "$c_id" ] || [ -z "$c_cmd" ]; then
      malformed="$malformed $crit_lineno"
      continue
    fi
    runnable=$((runnable + 1))

    # Static parse check — the other half of "this criterion can never run", and
    # the same family as the malformed-line warning below: both catch a criterion
    # the author expects to be checked and that no amount of work can turn green.
    # run-contract executes each criterion as `bash -c "$cmd"`, so a command
    # string bash cannot PARSE fails on every stop attempt, on any tree, whatever
    # the builder does — the loop can then only end by hitting a stop rule.
    # `bash -n -c` is exactly that parse with nothing executed.
    #
    # Why the parse and not an exit status: the shape that motivated this (the
    # 0.12.0 live-install smoke — a printf ate the outer quotes off a git
    # pathspec, leaving `:(exclude)…` bare) exits 2, which is also what
    # `grep -q needle a-file-the-work-creates` exits, and that is a legitimate
    # RED. 126/127 are ambiguous the same way: `bash tests/not-yet-written.sh`
    # is 127 and a perfectly good criterion. A parse failure is the one verdict
    # that cannot be a false positive, because it is a property of the string
    # rather than of the tree.
    #
    # Deliberately NOT under LOOP_ENG_ARM_REDCHECK: that knob exists so that
    # arming executes ZERO criterion commands, and this executes none either way
    # (bash parses a whole -c string before running any of it, so even a side
    # effect standing before the syntax error never happens).
    #
    # It now runs on exactly the criteria run-contract will execute, which is the
    # point of folding it into this loop: as its own `IFS=$'\t' read` loop it saw
    # an empty command for every empty-description criterion and skipped it.
    pcheck_err=$(bash -n -c "$c_cmd" 2>&1 </dev/null) && continue
    # Fold to one line: bash's diagnosis is multi-line, and a warning that spans
    # lines is one neither a log reader nor a test assertion can match reliably.
    pcheck_err=$(printf '%s' "$pcheck_err" | tr '\n' ' ')
    echo "loop-eng arm-contract: WARNING — criterion '$c_id' can never run: its command is not valid shell — $pcheck_err. run-contract executes it as \`bash -c\`, so it fails on EVERY stop attempt no matter what the builder does, and the loop can only end by hitting a stop rule. Fix it NOW; once the loop is armed the evidence-gate locks $CRIT." >&2
  done < "$CRIT"

  # Warn early (fail-fast) if the contract verifies nothing: a criteria.tsv with
  # zero runnable lines (empty / all-comment / all-malformed) makes run-contract
  # fail CLOSED on every stop. Catch it at arm time rather than at first block.
  if [ "$runnable" -eq 0 ]; then
    echo "loop-eng arm-contract: WARNING — criteria.tsv has no runnable criteria (need <id>TAB<description>TAB<command> lines). run-contract will FAIL CLOSED on every stop until you add at least one; a contract that verifies nothing can never be 'done'." >&2
  fi
  # A line that carries content, is not a #comment, and yields no id or no
  # command is a criterion its author expects to be checked and that will never
  # run. Warn HERE, at arm time — run-contract fails closed on the same
  # contract, but by then the evidence-gate has locked criteria.tsv for the
  # whole loop, so a first signal delivered at the first blocked stop is one the
  # model cannot act on.
  if [ -n "$malformed" ]; then
    echo "loop-eng arm-contract: WARNING — malformed criteria line(s):$malformed in $CRIT. Each criterion is split on its FIRST TWO TABs into <id>TAB<description>TAB<command> and needs a non-empty id and a non-empty command (an EMPTY description is fine). A line with fewer than two TABs — most often columns separated by SPACES — has no command column, and a line whose indent starts with a TAB has no id column; either way that criterion never runs. run-contract FAILS CLOSED on a partly parsed contract, so fix the line(s) NOW — once the loop is armed the evidence-gate locks this file. Comment a line out with a leading # if it was never meant to be a criterion." >&2
  fi
  hash=$(loop_sha256 "$CRIT")
  if [ -n "$hash" ]; then
    printf '%s\n' "$hash" > "$SHA_LOCK" || cannot_arm "$SHA_LOCK" "hash-lock not writable"
    echo "loop-eng arm-contract: pinned criteria.tsv @ $hash" >&2
  else
    rm -f "$SHA_LOCK" || cannot_arm "$SHA_LOCK" "stale hash-lock not removable"
    echo "loop-eng arm-contract: no SHA-256 tool available; contract armed WITHOUT a hash-lock (drift will not fail closed)." >&2
  fi
else
  # Fatal for the same reason the write above is: a stale lock left beside a
  # contract this arm did not pin makes run-contract fail closed on a tamper that
  # never happened, and the loop can then only end by hitting a stop rule.
  rm -f "$SHA_LOCK" || cannot_arm "$SHA_LOCK" "stale hash-lock not removable"
  echo "loop-eng arm-contract: no $CRIT (legacy verify.sh loop?); armed without a hash-lock." >&2
fi

# Pre-arm RED-CHECK (pilot retro finding): a verify criterion that is ALREADY
# green before any work has been done is untrustworthy — like a test that has
# never failed, it may be vacuously satisfied (e.g. a grep matching a
# pre-existing comment, a file-exists check on a file that predates the task).
# Surface it here so the human can judge whether it can actually go RED.
# ADVISORY ONLY: this loop never changes the arm outcome — the contract is
# already pinned above and .loop/active is still created below regardless. A
# criterion that is legitimately green at arm (e.g. a baseline "suite passes")
# also warns; that is acceptable, the human decides. Same TSV parse shape as
# run-contract.sh (skip blanks + #comments, strip a trailing CR). Each command's
# stdout+stderr are silenced so arm's own output stays clean — silenced, NOT
# sandboxed: a side-effecting criterion command runs for real here, and again on
# every stop attempt via run-contract. Criteria must be idempotent verify-only
# commands (see SKILL.md, "Contract quality caps loop quality").
#
# Knobs (arming must stay instant even when a criterion is the full test suite):
#   LOOP_ENG_ARM_REDCHECK=0          skip the red-check entirely — ZERO criterion
#                                    commands executed (guarded before the loop).
#   LOOP_ENG_ARM_REDCHECK_TIMEOUT=N  per-criterion budget in seconds (default 10;
#                                    non-numeric or 0 falls back to 10). A command
#                                    that times out exits 124 via timeout(1): it is
#                                    UNKNOWN, not green, so it never warns.
if [ -f "$CRIT" ] && [ "${LOOP_ENG_ARM_REDCHECK:-1}" != "0" ]; then
  REDCHECK_TIMEOUT="${LOOP_ENG_ARM_REDCHECK_TIMEOUT:-10}"
  case "$REDCHECK_TIMEOUT" in ''|*[!0-9]*) REDCHECK_TIMEOUT=10 ;; esac
  # 10#: "00"/"08" are digit strings too; force base-10 so the arithmetic never
  # sees a bad octal token. 0 would DISABLE timeout(1) (GNU semantics) — the
  # opposite of a budget at its lowest value — so it also falls back to 10.
  # Say so, rather than falling back in silence: this was the only one of the
  # plugin's four budget knobs (GATE_TIMEOUT, MAX_MINUTES ×2, this) that handled
  # 0 correctly but invisibly — so it was also the only one no test could pin,
  # and an unpinned invariant is how the same gap survived in stop-gate.sh.
  if [ "$((10#$REDCHECK_TIMEOUT))" -eq 0 ]; then
    echo "loop-eng arm-contract: LOOP_ENG_ARM_REDCHECK_TIMEOUT=$REDCHECK_TIMEOUT would disable the per-criterion red-check budget (timeout 0 = no limit); using 10." >&2
    REDCHECK_TIMEOUT=10
  fi
  # Same detection as stop-gate.sh (bash 3.2-safe): prefer timeout(1), else
  # gtimeout (macOS coreutils), else run unbounded rather than fail — advisory.
  REDCHECK_TIMEOUT_BIN=""
  if command -v timeout >/dev/null 2>&1; then REDCHECK_TIMEOUT_BIN="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then REDCHECK_TIMEOUT_BIN="gtimeout"; fi
  # Same split as the classification loop above and as run-contract.sh: on the
  # FIRST TWO TABs, empty description legal. As `IFS=$'\t' read -r id desc cmd`
  # this loop silently skipped every empty-description criterion (collapsed TABs
  # left cmd empty), so the one class of criterion most likely to be a hasty
  # afterthought was also the one that never got red-checked.
  rc_line=""
  rc_lineno=0
  while IFS= read -r rc_line || [ -n "$rc_line" ]; do
    rc_lineno=$((rc_lineno + 1))
    rc_line="${rc_line%$'\r'}"
    # Same BOM strip as the classification loop above and run-contract.sh: this
    # loop names criteria too ("criterion 'x' is already green").
    [ "$rc_lineno" -eq 1 ] && rc_line="${rc_line#$'\xef\xbb\xbf'}"
    case "$rc_line" in
      *[![:space:]]*) : ;;
      *) continue ;;
    esac
    case "${rc_line#"${rc_line%%[![:space:]]*}"}" in \#*) continue ;; esac
    case "$rc_line" in
      *$'\t'*$'\t'*)
        id="${rc_line%%$'\t'*}"
        rc_rest="${rc_line#*$'\t'}"
        cmd="${rc_rest#*$'\t'}" ;;
      *) id="$rc_line"; cmd="" ;;
    esac
    [ -z "$id" ] && continue
    [ -z "$cmd" ] && continue
    # </dev/null: same guard as run-contract.sh — a stdin-reading criterion
    # command would otherwise consume the remaining criteria lines from this
    # while-read loop (silently skipping their red-check).
    if [ -n "$REDCHECK_TIMEOUT_BIN" ]; then
      "$REDCHECK_TIMEOUT_BIN" "$REDCHECK_TIMEOUT" bash -c "$cmd" >/dev/null 2>&1 </dev/null
    else
      bash -c "$cmd" >/dev/null 2>&1 </dev/null
    fi
    redcheck_status=$?
    if [ "$redcheck_status" -eq 0 ]; then
      echo "loop-eng arm-contract: WARNING — criterion '$id' is already green at arm time (passed before any work). A criterion that never had to go RED may be vacuously satisfied — verify it actually tests the change. Advisory only; the loop is still armed." >&2
    fi
  done < "$CRIT"
fi

: > "$ACTIVE" || cannot_arm "$ACTIVE" "arm marker not creatable"
# gate-last is the stop-gate's same-stop-attempt marker. It is time-bounded, so a
# stale one is already harmless — but a loop arms with a clean slate, and leaving
# a previous loop's verdict lying next to a fresh contract is the same class of
# leftover as the stale gate-count beside it.
# Checked like every other write here: a surviving gate-count spends the
# stop-gate's 3-block ceiling before this loop's first stop, which weakens the
# gate exactly the way a missing $ACTIVE removes it.
rm -f "$COUNT_FILE" "$LOOP_DIR/gate-last" || cannot_arm "$COUNT_FILE" "stale gate-count not removable"
echo "loop-eng arm-contract: stop-gate armed ($ACTIVE)." >&2
# Provenance line (cache-vs-repo divergence guard, pilot retro finding): print
# the path THIS script was invoked as. In a dogfood run the loop arms from the
# installed plugin CACHE (…/plugins/cache/loop-eng/…), which can lag the repo —
# repo-side script edits are NOT in effect until `/plugin update`. Surfacing the
# armed-from path makes that divergence visible instead of silent. Advisory only.
echo "loop-eng arm-contract: armed from $0" >&2
