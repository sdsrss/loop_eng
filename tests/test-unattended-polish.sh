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

report "test-unattended-polish"
