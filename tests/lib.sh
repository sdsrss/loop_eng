#!/usr/bin/env bash
# Shared helpers for loop-eng tests. Source, don't execute.
# Every test creates its own sandbox git repo and MUST clean it on exit:
#   SB=$(mk_sandbox_repo); trap 'rm -rf "$SB"' EXIT

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PLUGIN_ROOT

PASS=0
FAIL=0

mk_sandbox_repo() {
  local sb
  sb=$(mktemp -d "${TMPDIR:-/tmp}/loop-eng-test.XXXXXX")
  (
    cd "$sb"
    git init -q
    git config user.email test@loop-eng.local
    git config user.name loop-eng-test
    printf '.loop/\n*.log\n' > .gitignore   # mirror the real repo: .loop/ bookkeeping is not tracked
    echo "sandbox" > README.md
    git add .gitignore README.md
    git commit -qm "initial"
  ) >/dev/null
  echo "$sb"
}

assert_eq() { # expected actual label
  if [ "$1" = "$2" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $3 — expected [$1] got [$2]" >&2; fi
}

assert_file_contains() { # file needle label
  if grep -qF -- "$2" "$1" 2>/dev/null; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $3 — $1 does not contain [$2]" >&2; fi
}

report() { # test-name
  echo "$1: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}
