#!/usr/bin/env bash
# test-harness: the one thing no other suite can check about itself.
#
# Every tests/test-*.sh ends in lib.sh's report(), which is the single place a
# suite's exit status — and therefore run-all.sh's ALL GREEN — is decided. A
# bug there is invisible from inside any suite that uses it, so it gets its own.
set -u
. "$(dirname "$0")/lib.sh"

TD=$(mktemp -d "${TMPDIR:-/tmp}/loop-eng-harness.XXXXXX")
trap 'rm -rf "$TD"' EXIT

# --- report(): a suite that ran no assertions is NOT green -------------------
# tests/test-manifest.sh needs python3 and tests/test-hooks-json.sh needs jq or
# python3; each bails out early when its parser is absent. Pre-fix each then
# printed "0 passed, 0 failed", exited 0, and run-all.sh printed ALL GREEN for a
# run that verified nothing about the manifests or about hooks.json — the exact
# unearned-green shape the rest of this plugin exists to refuse, one level up.
#
# Each probe runs in a SUBSHELL so its PASS/FAIL assignments cannot disturb this
# suite's own counters.
( PASS=0; FAIL=0; report "probe-zero" >"$TD/zero-out" 2>"$TD/zero-err" ) && rc=0 || rc=$?
assert_eq 1 "$rc" "report() fails a suite that ran no assertions at all"
assert_file_contains "$TD/zero-err" "no assertions" "the zero-assertion refusal says what was wrong"
assert_file_contains "$TD/zero-out" "0 passed, 0 failed" "the count line is still printed before the refusal"

( PASS=7; FAIL=0; report "probe-green" >/dev/null 2>&1 ) && rc=0 || rc=$?
assert_eq 0 "$rc" "report() still succeeds when assertions ran and all passed"

( PASS=7; FAIL=1; report "probe-red" >/dev/null 2>&1 ) && rc=0 || rc=$?
assert_eq 1 "$rc" "report() still fails when an assertion failed"

# PASS=0 with failures is the ordinary all-red case, not the unrun case: it must
# fail for the normal reason, and the guard above must not be what catches it.
# shellcheck disable=SC2034  # PASS is read by report(), which lives in lib.sh
( PASS=0; FAIL=2; report "probe-allred" >"$TD/allred-out" 2>"$TD/allred-err" ) && rc=0 || rc=$?
assert_eq 1 "$rc" "report() fails when every assertion failed"
if grep -qF "no assertions" "$TD/allred-err"; then
  assert_eq "ordinary failure" "misreported as unrun" "an all-red suite is not reported as unrun"
else
  assert_eq 0 0 "an all-red suite is not reported as unrun"
fi

# --- and the two parser-dependent suites actually go red without a parser ----
# The unit probes above pin report()'s contract; this arm pins the consequence
# the finding was actually about. Build a PATH holding no python3 and no jq —
# the real PATH cannot provide that — with symlinks to exactly what those two
# suites reach BY NAME. A missing entry here would look like a suite bug, so
# each one is asserted rather than assumed.
mkdir -p "$TD/bin"
for b in bash sh git grep sed awk cat cut head tail wc sort tr mktemp rm mkdir \
         dirname basename find diff chmod touch date env; do
  bp=$(command -v "$b" 2>/dev/null) || bp=""
  if [ -n "$bp" ]; then ln -sf "$bp" "$TD/bin/$b"; else
    FAIL=$((FAIL+1)); echo "  FAIL: test prerequisite '$b' is not on PATH" >&2; fi
done
if [ -e "$TD/bin/python3" ] || [ -e "$TD/bin/jq" ]; then
  assert_eq "no parser" "parser present" "the restricted PATH holds neither python3 nor jq"
else
  assert_eq 0 0 "the restricted PATH holds neither python3 nor jq"
fi

for suite in test-manifest test-hooks-json; do
  PATH="$TD/bin" bash "$PLUGIN_ROOT/tests/$suite.sh" >"$TD/$suite.out" 2>"$TD/$suite.err" && rc=0 || rc=$?
  assert_eq 1 "$rc" "$suite exits non-zero on a host with no JSON parser (was: 0 passed, 0 failed, exit 0)"
  assert_file_contains "$TD/$suite.err" "no assertions" "$suite says it checked nothing rather than reporting green"
done

# --- P3-6: every scratch dir a suite creates must be in its EXIT trap --------
# CLAUDE.md's rule is "builds a throwaway repo, cleans it on a `trap ... EXIT`",
# and two suites had grown scratch dirs cleaned by an inline `rm` instead — which
# a killed suite (CI cancel, Ctrl-C, a hung assertion) never reaches. One of
# them used a bare `mktemp -d` with no name pattern, so it did not even show up
# in a `loop-eng-*` leak scan of $TMPDIR. Checked statically rather than by
# leak-scanning a run: a leak only appears on the abnormal exits, which is
# exactly when no test is watching.
for f in "$PLUGIN_ROOT"/tests/test-*.sh; do
  base=$(basename "$f")
  # A trap INSTALLATION: comment lines dropped first, then `trap` at the start
  # of a statement — so the one-line `X=$(mktemp -d); trap ... EXIT` form counts
  # while the same words quoted in prose do not. Both halves are load-bearing:
  # without the anchor this file failed against its own scan's pattern string,
  # and without the comment filter it failed against the sentence describing the
  # anchor.
  traps=$(grep -vE '^[[:space:]]*#' "$f" | grep -E '(^|;[[:space:]]*)trap .+EXIT' || true)
  # Match the SHAPE, not a list of spellings. The pattern used to require an
  # uppercase name, a bare `=$(`, and the literal `mktemp -d` — so four ordinary
  # ways of making a scratch dir were invisible to both halves of this scan:
  # `LEAK="$(mktemp -d)"` (quoted), `leak=$(mktemp -d)` (lowercase),
  # `export LEAK=$(mktemp -d)`, and `LEAK=$(mktemp)` (a scratch FILE, which also
  # needs removing). Injecting all four into a copy of test-sync-local.sh left
  # this suite at 98 passed, 0 failed. It also meant every new `mk_*sandbox*`
  # helper had to be remembered here by hand, and the list had already been
  # short once (mk_wide_sandbox_repo builds the most expensive dir in $TMPDIR to
  # leak and was added only after it existed). Now: any assignment whose value
  # comes from `mktemp` or from a helper named `mk_…sandbox…`, however spelled.
  vars=$(grep -oE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*="?\$\((mktemp|mk_[A-Za-z0-9_]*sandbox[A-Za-z0-9_]*)' "$f" \
           | sed -E 's/^[[:space:]]*//; s/^export[[:space:]]+//; s/="?\$\(.*//' | sort -u)
  for v in $vars; do
    case "$traps" in
      *"\$$v"*|*"\${$v}"*) PASS=$((PASS+1)) ;;
      *) FAIL=$((FAIL+1))
         echo "  FAIL: $base creates \$$v (mktemp / mk_*sandbox* helper) but no EXIT trap removes it" >&2 ;;
    esac
  done
  # ...and the LAST trap must name them all. Two suites re-install a longer trap
  # beside each new sandbox, a hand-maintained list that grows by one name per
  # sandbox — and it had already dropped names twice, so a sandbox registered
  # early was silently unregistered again by a later line. Only the last trap
  # installed is the one that runs.
  last_trap=$(printf '%s\n' "$traps" | tail -1)
  [ -n "$last_trap" ] || continue
  for v in $vars; do
    case "$last_trap" in
      *"\$$v"*|*"\${$v}"*) PASS=$((PASS+1)) ;;
      *) FAIL=$((FAIL+1))
         echo "  FAIL: $base's FINAL EXIT trap drops \$$v — a later trap re-install removed it from the list" >&2 ;;
    esac
  done
done

report "test-harness"
