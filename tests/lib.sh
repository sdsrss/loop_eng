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
  # Canonicalize: on macOS $TMPDIR lives under /var -> /private/var (symlink),
  # so scripts that `cd && pwd` a repo argument (install-timer) print the
  # /private/... form while the raw mktemp string says /var/... — assertions
  # comparing the two then fail on paths that are the same directory.
  sb=$(cd "$sb" && pwd)
  (
    cd "$sb" || exit 1
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

# A sandbox repo with MANY tracked files. SCALE is the point, and it is the
# axis every dirty-tree fixture in this suite was blind to: the drivers' guards
# read `git status --porcelain` through a consumer that stops at the first line,
# so whether the guard works at all is a RACE between git writing and the
# consumer leaving. A one-file fixture (~40 bytes of porcelain) is won by git
# every time and the guard looks sound. The race turns deterministic the other
# way once the output passes the 64KB pipe buffer — git blocks mid-write and
# takes the SIGPIPE — on a tree wide enough that git is still enumerating when
# the consumer goes. 4000 files = ~72000 bytes once all of them are modified.
#
# Deliberately pinned at that far end. Measured on the pre-fix driver, the
# 15-24KB band flips run to run (a test pinned there would be FLAKY) and ~27KB
# is already deterministic; 72000 bytes sits clear of both. Build cost is
# ~0.2s, so the whole shape is cheap enough to keep.
mk_wide_sandbox_repo() { # [file-count, default 4000] -> repo path on stdout
  local sb n i f
  n="${1:-4000}"
  sb=$(mk_sandbox_repo)
  (
    cd "$sb" || exit 1
    mkdir wide || exit 1
    # printf -v, not $(printf ...): a subshell per file turns 0.2s into minutes.
    for ((i = 0; i < n; i++)); do
      printf -v f 'wide/f%05d.txt' "$i"
      printf 'x\n' > "$f"
    done
    git add wide
    git commit -qm "wide fixture: $n tracked files"
  ) >/dev/null || return 1
  echo "$sb"
}

dirty_wide_tree() { # repo -> modify every file the wide fixture tracked
  local f
  for f in "$1"/wide/*; do printf 'modified\n' > "$f"; done
}

sha_of() { # portable SHA-256 of a file -> stdout (mirrors the scripts' loop_sha256)
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | awk '{print $NF}'; fi
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
  # A suite that ran ZERO assertions is not green — it is unrun. Two suites bail
  # out early when the host has no JSON parser (test-manifest needs python3,
  # test-hooks-json needs jq or python3), and on such a host each printed
  # "0 passed, 0 failed", exited 0, and run-all.sh printed ALL GREEN for a run
  # in which nothing about the manifests or hooks.json was checked. That is this
  # plugin's own failure mode one level up: a green report nobody earned. The
  # counts are still printed first, so the reason is visible either way.
  if [ "$PASS" -eq 0 ] && [ "$FAIL" -eq 0 ]; then
    echo "  FAIL: $1 ran no assertions at all — a suite that checked nothing is not green" >&2
    return 1
  fi
  [ "$FAIL" -eq 0 ]
}
