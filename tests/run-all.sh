#!/usr/bin/env bash
# loop-eng test entry point: syntax-check every shell script, run shellcheck
# when available, then run every tests/test-*.sh in sequence.
set -u
cd "$(dirname "$0")/.." || exit 1

overall=0

echo "== bash -n =="
while IFS= read -r f; do
  if bash -n "$f"; then echo "  ok: $f"; else echo "  SYNTAX FAIL: $f"; overall=1; fi
done < <(git ls-files '*.sh')

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
  if shellcheck -S warning $(git ls-files '*.sh'); then
    echo "  ok: no errors or warnings"
  else overall=1; fi
else
  echo "== shellcheck not installed, skipping (bash -n only) =="
fi

echo "== tests =="
for t in tests/test-*.sh; do
  [ -e "$t" ] || continue
  if bash "$t"; then echo "  ok: $t"; else echo "  TEST FAIL: $t"; overall=1; fi
done

[ "$overall" -eq 0 ] && echo "ALL GREEN" || echo "FAILED"
exit "$overall"
