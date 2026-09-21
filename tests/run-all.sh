#!/usr/bin/env bash
# loop-eng test entry point: syntax-check every shell script, run shellcheck
# when available, then run every tests/test-*.sh in sequence.
set -u
cd "$(dirname "$0")/.." || exit 1

overall=0

RUNLOG=$(mktemp "${TMPDIR:-/tmp}/loop-eng-runall.XXXXXX")
trap 'rm -f "$RUNLOG"' EXIT

# Tracked scripts AND untracked-but-not-ignored ones. `git ls-files '*.sh'`
# alone was the whole input, so a new script was invisible to BOTH legs below
# until someone remembered to `git add` it — this file's own header promises it
# syntax-checks every shell script, and for an un-added script it checked
# nothing while still printing ALL GREEN. Proven on a copy: an untracked
# `broken.sh` holding `if then fi` (`bash -n` → exit 2) passed the whole entry
# point. `--others --exclude-standard` keeps .gitignore honoured, so `.loop/`
# and other ignored paths stay out; what it adds is exactly the window between
# writing a script and adding it.
list_scripts() {
  git ls-files '*.sh'
  git ls-files --others --exclude-standard '*.sh'
}

echo "== bash -n =="
checked=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  checked=$((checked+1))
  if bash -n "$f"; then echo "  ok: $f"; else echo "  SYNTAX FAIL: $f"; overall=1; fi
done < <(list_scripts)
# Zero files checked is not a pass. `git ls-files` returns nothing outside a
# repo (or with a pathspec that stops matching), and the loop then simply does
# not run — the same unearned green that lib.sh's report() refuses one level
# down.
if [ "$checked" -eq 0 ]; then
  echo "  FAIL: no shell scripts found to syntax-check — nothing was verified"
  overall=1
fi

if command -v shellcheck >/dev/null 2>&1; then
  echo "== shellcheck =="
  # `-S warning`, not `-S error`. The gate sat at `error` with 13 warnings
  # unchecked behind it, and they were not cosmetic: nine were SC2164, a `cd`
  # with no `|| exit` — in a TEST suite, where a failed `cd` into the sandbox
  # means the rest of the file runs in the real working tree and starts
  # deleting .loop/ files there. The other four were a `$?` read from a
  # condition rather than a command (SC2319) and two unused-looking variables.
  # Raising the gate is what keeps that class from accumulating again; the two
  # deliberate exceptions carry an inline `# shellcheck disable=` with a reason.
  # `-S style` stays out: SC1091 (can't follow `. lib.sh`) alone is 12 hits with
  # nothing to fix.
  # shellcheck disable=SC2046
  if shellcheck -S warning $(list_scripts); then
    echo "  ok: no errors or warnings"
  else overall=1; fi
else
  echo "== shellcheck not installed, skipping (bash -n only) =="
fi

echo "== tests =="
ran=0
for t in tests/test-*.sh; do
  [ -e "$t" ] || continue
  ran=$((ran+1))
  bash "$t" 2>&1 | tee "$RUNLOG"
  rc=${PIPESTATUS[0]}
  if [ "$rc" -ne 0 ]; then
    echo "  TEST FAIL: $t"; overall=1
  # A suite is green only if it SAID so. Exit 0 also covers a suite that
  # returned before reaching `report` — no counts printed, nothing run, and
  # this loop used to call that "ok". report() is every suite's last line, so
  # its counts line is the one artifact that proves the file ran to the end.
  elif printf '%s' "$(cat "$RUNLOG")" | grep -qE '[0-9]+ passed, [0-9]+ failed'; then
    echo "  ok: $t"
  else
    echo "  NO REPORT: $t exited 0 without printing its assertion counts"; overall=1
  fi
done
if [ "$ran" -eq 0 ]; then
  echo "  FAIL: no tests/test-*.sh matched — no suite ran"
  overall=1
fi

[ "$overall" -eq 0 ] && echo "ALL GREEN" || echo "FAILED"
exit "$overall"
