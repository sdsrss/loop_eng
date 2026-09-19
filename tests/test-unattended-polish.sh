#!/usr/bin/env bash
# unattended-polish: status capture on failure, rate-limit detection, stub claude.
set -u
. "$(dirname "$0")/lib.sh"

SCRIPT="$PLUGIN_ROOT/skills/loop-eng/scripts/unattended-polish.sh"

# --- bash floor: the header's "requires bash >= 4.4" is now enforced ---
# Pre-fix it was a comment, so on stock macOS bash 3.2 this driver STARTED, did
# real work, and only then died on the first empty-array expansion under set -u
# — the worst shape for an unattended WRITER. Two arms are runnable anywhere:
# a non-bash shell (BASH_VERSION empty), and this machine's bash, which the
# suite itself requires to be >= 4.4 and which must therefore NOT trip it.
# The genuine old-BASH arm needs a 3.2 interpreter; CLAUDE.md's docker recipe
# covers it (verified exit 78 on 3.2.57) and the 3.2 CI leg does not run this
# suite, so it is deliberately not asserted here.
guard_out=$(sh "$SCRIPT" 2>&1 >/dev/null); guard_rc=$?
assert_eq 78 "$guard_rc" "bash floor: a non-bash shell is refused with EX_CONFIG"
case "$guard_out" in
  *"bash >= 4.4"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: non-bash refusal does not name the requirement: $guard_out" >&2 ;;
esac
bash "$SCRIPT" >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 78 ]; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: the bash floor fired on this machine's bash ($BASH_VERSION)" >&2; fi

# ORDER, asserted structurally — this is the invariant, and the `sh` arm above
# cannot carry it. `set -o pipefail` is not POSIX: some sh implementations take
# it, others answer "Illegal option" and exit 2 before any guard below it runs.
# The two dashes disagreed (local accepted, the CI runner refused), so the arm
# above passed here and failed there. Whichever sh this machine has, the guard
# must sit ABOVE the set line or it is unreachable on the shells it exists for.
guard_ln=$(grep -n 'if \[ -z "${BASH_VERSION:-}" \]' "$SCRIPT" | head -1 | cut -d: -f1)
setopt_ln=$(grep -n '^set -euo pipefail' "$SCRIPT" | head -1 | cut -d: -f1)
if [ -n "$guard_ln" ] && [ -n "$setopt_ln" ] && [ "$guard_ln" -lt "$setopt_ln" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  echo "  FAIL: bash-floor guard (line ${guard_ln:-none}) must precede 'set -euo pipefail' (line ${setopt_ln:-none})" >&2
fi

SB=$(mk_sandbox_repo)
SD=$(mktemp -d "${TMPDIR:-/tmp}/loop-eng-stub.XXXXXX")
trap 'rm -rf "$SB" "$SD"' EXIT

# stub lives OUTSIDE the sandbox repo — an untracked stub inside it would
# trip the script's own dirty-tree refusal
STUB="$SD/stub-claude"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
# stub claude: behavior driven by STUB_MODE
case "${STUB_MODE:-ok}" in
  ok)    echo "polish report: 0 findings"; exit 0 ;;
  fail)  echo "boom"; exit 3 ;;
  limit) echo "${STUB_LIMIT_MSG:-Claude AI usage limit reached}"; exit 1 ;;
esac
EOF
chmod +x "$STUB"

# --- success path logs exit=0 ---
# stdout of every driver run goes to /dev/null: the stub's fixture output
# ("boom", the limit message) and the script's own session-log tail would
# otherwise leak into the runner console; assertions read the log files
# and exit codes, never stdout.
STUB_MODE=ok LOOP_ENG_CLAUDE_BIN="$STUB" bash "$SCRIPT" "$SB" src/ >/dev/null
assert_eq 0 $? "ok run exits 0"
assert_file_contains "$SB/.loop/unattended.log" "exit=0" "logs exit=0"

# --- failure path: exit code captured and passed through (was: died silently) ---
STUB_MODE=fail LOOP_ENG_CLAUDE_BIN="$STUB" bash "$SCRIPT" "$SB" src/ >/dev/null && rc=0 || rc=$?
assert_eq 3 "$rc" "failing claude exit passed through"
assert_file_contains "$SB/.loop/unattended.log" "exit=3" "logs exit=3 on failure"

# --- argument shape is validated, not assumed ---
# Both traps below produced a clean exit 0 that LOOKS like a working write-mode
# run: under a nightly timer they stay invisible for weeks.
#   a) scope omitted -> the flag lands in the scope slot: silently report-only
#      AND pointed at a scope that does not exist
#   b) flag typo'd -> silently report-only
STUB_MODE=ok LOOP_ENG_ALLOW_AUTOFIX=1 LOOP_ENG_CLAUDE_BIN="$STUB" \
  bash "$SCRIPT" "$SB" --auto-fix >/dev/null 2>"$SD/usage1" && rc=0 || rc=$?
assert_eq 64 "$rc" "flag in the scope slot is a usage error, not a silent report-only run"
assert_file_contains "$SD/usage1" "scope" "usage error explains the scope/flag order"
STUB_MODE=ok LOOP_ENG_ALLOW_AUTOFIX=1 LOOP_ENG_CLAUDE_BIN="$STUB" \
  bash "$SCRIPT" "$SB" src/ --auto-fixx >/dev/null 2>"$SD/usage2" && rc=0 || rc=$?
assert_eq 64 "$rc" "typo'd flag is a usage error, not a silent report-only run"
assert_file_contains "$SD/usage2" "--auto-fixx" "usage error quotes the unknown option"
STUB_MODE=ok LOOP_ENG_ALLOW_AUTOFIX=1 LOOP_ENG_CLAUDE_BIN="$STUB" \
  bash "$SCRIPT" "$SB" src/ --auto-fix extra >/dev/null 2>"$SD/usage3" && rc=0 || rc=$?
assert_eq 64 "$rc" "extra trailing argument is a usage error"
# the valid shapes must keep working
STUB_MODE=ok LOOP_ENG_CLAUDE_BIN="$STUB" bash "$SCRIPT" "$SB" >/dev/null && rc=0 || rc=$?
assert_eq 0 "$rc" "repo-only invocation still runs (scope defaults to src/)"
STUB_MODE=ok LOOP_ENG_ALLOW_AUTOFIX=1 LOOP_ENG_CLAUDE_BIN="$STUB" \
  bash "$SCRIPT" "$SB" src/ --auto-fix >/dev/null && rc=0 || rc=$?
assert_eq 0 "$rc" "well-formed --auto-fix invocation still runs"

# --- non-git target: the dirty-tree guard must not fail OPEN ---
# `git status --porcelain` in a non-repo writes its fatal to stderr and leaves
# stdout EMPTY, so `grep -vq` found no line, reported "not dirty", and the run
# proceeded — invoking claude with --permission-mode bypassPermissions against a
# directory with no version control at all, i.e. unattributable, unrevertable
# edits. That is exactly what the guard exists to prevent.
NOGIT="$SD/nogit"
mkdir -p "$NOGIT"; echo "unversioned work" > "$NOGIT/important.txt"
STUB_MODE=ok LOOP_ENG_CLAUDE_BIN="$STUB" bash "$SCRIPT" "$NOGIT" src/ >/dev/null 2>"$SD/nogit-err" && rc=0 || rc=$?
assert_eq 1 "$rc" "non-git target refused (the dirty-tree guard cannot fail open)"
assert_file_contains "$SD/nogit-err" "not a git repository" "refusal says the target is not a git repository"
if [ -d "$NOGIT/.loop" ]; then
  assert_eq "no .loop" "created .loop" "refused run does not run far enough to create .loop in the non-repo"
else
  assert_eq 0 0 "refused run does not run far enough to create .loop in the non-repo"
fi

# --- rate-limit path: exit 75 + marker ---
STUB_MODE=limit LOOP_ENG_CLAUDE_BIN="$STUB" bash "$SCRIPT" "$SB" src/ >/dev/null && rc=0 || rc=$?
assert_eq 75 "$rc" "rate-limited run exits 75"
assert_file_contains "$SB/.loop/unattended.log" "rate-limited" "logs rate-limited marker"

# --- broadened limit regex: a non-"usage limit" phrasing also takes the limit path ---
STUB_MODE=limit STUB_LIMIT_MSG="quota exceeded" LOOP_ENG_CLAUDE_BIN="$STUB" \
  bash "$SCRIPT" "$SB" src/ >/dev/null && rc=0 || rc=$?
assert_eq 75 "$rc" "quota-exceeded run exits 75 (broadened limit regex)"

# --- non-numeric MAX_MINUTES warns + falls back to default (was: opaque timeout fail) ---
STUB_MODE=ok LOOP_ENG_MAX_MINUTES=nope LOOP_ENG_CLAUDE_BIN="$STUB" \
  bash "$SCRIPT" "$SB" src/ >/dev/null 2>"$SD/warn" && rc=0 || rc=$?
assert_eq 0 "$rc" "non-numeric MAX_MINUTES still runs (falls back to default)"
assert_file_contains "$SD/warn" "not a non-negative integer" "warns on non-numeric MAX_MINUTES"

# --- MAX_MINUTES=0 would DISABLE the timeout (GNU `timeout 0m` = no limit): warn + default ---
STUB_MODE=ok LOOP_ENG_MAX_MINUTES=0 LOOP_ENG_CLAUDE_BIN="$STUB" \
  bash "$SCRIPT" "$SB" src/ >/dev/null 2>"$SD/warn0" && rc=0 || rc=$?
assert_eq 0 "$rc" "MAX_MINUTES=0 still runs (falls back to default)"
assert_file_contains "$SD/warn0" "would disable the timeout" "warns that 0 disables the timeout"

# --- log rotation: >30-day per-run logs pruned, fresh ones kept, rolling log capped ---
# touch -t (not GNU-only `touch -d '40 days ago'`) so the fake-old mtime also
# works on BSD/macOS CI; any fixed past date is always >30 days old.
OLD_LOG="$SB/.loop/unattended-20200101-000000.log"
echo "ancient run" > "$OLD_LOG"
touch -t 202001010000 "$OLD_LOG"
FRESH_LOG="$SB/.loop/unattended-fresh-run.log"
echo "recent run" > "$FRESH_LOG"
# oversized rolling log: >1MB of filler, marker line at the very end
{ head -c 1200000 /dev/zero | tr '\0' 'x'; echo; echo "TAIL-MARKER-SURVIVES"; } > "$SB/.loop/unattended.log"
STUB_MODE=ok LOOP_ENG_CLAUDE_BIN="$STUB" bash "$SCRIPT" "$SB" src/ >/dev/null
assert_eq 0 $? "rotation run exits 0"
if [ -e "$OLD_LOG" ]; then
  assert_eq "pruned" "still-present" ">30-day per-run log is pruned"
else
  assert_eq 0 0 ">30-day per-run log is pruned"
fi
if [ -e "$FRESH_LOG" ]; then
  assert_eq 0 0 "fresh per-run log is kept"
else
  assert_eq "kept" "deleted" "fresh per-run log is kept"
fi
ROLL_SIZE=$(wc -c < "$SB/.loop/unattended.log")
if [ "$ROLL_SIZE" -le 1048576 ]; then
  assert_eq 0 0 "oversized unattended.log truncated to <=1MB (now $ROLL_SIZE bytes)"
else
  assert_eq "<=1048576" "$ROLL_SIZE" "oversized unattended.log truncated to <=1MB"
fi
assert_file_contains "$SB/.loop/unattended.log" "TAIL-MARKER-SURVIVES" "truncation keeps the tail (marker survives)"

report "test-unattended-polish"
