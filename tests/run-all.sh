#!/usr/bin/env bash
# loop-eng test entry point: syntax-check every shell script, run shellcheck
# when available, then run every tests/test-*.sh in sequence.
set -u
cd "$(dirname "$0")/.."

overall=0

echo "== bash -n =="
while IFS= read -r f; do
  if bash -n "$f"; then echo "  ok: $f"; else echo "  SYNTAX FAIL: $f"; overall=1; fi
done < <(git ls-files '*.sh')

if command -v shellcheck >/dev/null 2>&1; then
  echo "== shellcheck =="
  # shellcheck disable=SC2046
  if shellcheck -S error $(git ls-files '*.sh'); then
    echo "  ok: no errors"
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
