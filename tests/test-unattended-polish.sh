#!/usr/bin/env bash
# unattended-polish: status capture on failure, rate-limit detection, stub claude.
set -u
. "$(dirname "$0")/lib.sh"

SCRIPT="$PLUGIN_ROOT/skills/loop-eng/scripts/unattended-polish.sh"
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
  limit) echo "Claude AI usage limit reached"; exit 1 ;;
esac
EOF
chmod +x "$STUB"

# --- success path logs exit=0 ---
STUB_MODE=ok LOOP_ENG_CLAUDE_BIN="$STUB" bash "$SCRIPT" "$SB" src/
assert_eq 0 $? "ok run exits 0"
assert_file_contains "$SB/.loop/unattended.log" "exit=0" "logs exit=0"

# --- failure path: exit code captured and passed through (was: died silently) ---
STUB_MODE=fail LOOP_ENG_CLAUDE_BIN="$STUB" bash "$SCRIPT" "$SB" src/ && rc=0 || rc=$?
assert_eq 3 "$rc" "failing claude exit passed through"
assert_file_contains "$SB/.loop/unattended.log" "exit=3" "logs exit=3 on failure"

# --- rate-limit path: exit 75 + marker ---
STUB_MODE=limit LOOP_ENG_CLAUDE_BIN="$STUB" bash "$SCRIPT" "$SB" src/ && rc=0 || rc=$?
assert_eq 75 "$rc" "rate-limited run exits 75"
assert_file_contains "$SB/.loop/unattended.log" "rate-limited" "logs rate-limited marker"

# --- non-numeric MAX_MINUTES warns + falls back to default (was: opaque timeout fail) ---
STUB_MODE=ok LOOP_ENG_MAX_MINUTES=nope LOOP_ENG_CLAUDE_BIN="$STUB" \
  bash "$SCRIPT" "$SB" src/ 2>"$SD/warn" && rc=0 || rc=$?
assert_eq 0 "$rc" "non-numeric MAX_MINUTES still runs (falls back to default)"
assert_file_contains "$SD/warn" "not a non-negative integer" "warns on non-numeric MAX_MINUTES"

# --- MAX_MINUTES=0 would DISABLE the timeout (GNU `timeout 0m` = no limit): warn + default ---
STUB_MODE=ok LOOP_ENG_MAX_MINUTES=0 LOOP_ENG_CLAUDE_BIN="$STUB" \
  bash "$SCRIPT" "$SB" src/ 2>"$SD/warn0" && rc=0 || rc=$?
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
