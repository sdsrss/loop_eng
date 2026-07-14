#!/usr/bin/env bash
# unattended-autoloop: fresh-session-per-item, commit-keyed circuit breaker,
# auth env requirement, dirty-tree refusal. Uses a stub claude.
set -u
. "$(dirname "$0")/lib.sh"

DRIVER="$PLUGIN_ROOT/skills/loop-eng/scripts/unattended-autoloop.sh"
SD=$(mktemp -d "${TMPDIR:-/tmp}/loop-eng-stub.XXXXXX")

mk_stub() { # $1 = stub dir OUTSIDE any sandbox repo (untracked stub inside
            #      the repo would trip the driver's dirty-tree refusal)
  cat > "$1/stub-claude" <<'EOF'
#!/usr/bin/env bash
# stub claude: "progress" marks the first backlog item done and commits;
# "stall" produces no commit. Runs inside the repo cwd set by the driver.
case "${STUB_MODE:-progress}" in
  progress)
    sed -i.bak '0,/^- \[ \]/s//- [x]/' .loop/backlog.md && rm -f .loop/backlog.md.bak
    echo "done one item" > "progress-$(date +%s%N).txt"
    git add -A >/dev/null
    git commit -qm "stub: item done"
    echo "ALL GREEN"
    ;;
  stall)
    echo "no progress made"
    ;;
  nuke-backlog)
    # simulates a session that deletes the backlog mid-run: the driver must
    # treat "backlog gone" as 0 pending and stop, not keep launching sessions
    rm -f .loop/backlog.md
    echo "backlog removed"
    ;;
esac
exit 0
EOF
  chmod +x "$1/stub-claude"
}

mk_stub "$SD"
STUB="$SD/stub-claude"

# --- refuses without LOOP_ENG_ALLOW_AUTOBUILD=1 ---
SB=$(mk_sandbox_repo); trap 'rm -rf "$SB" "$SD"' EXIT
mkdir -p "$SB/.loop"
printf -- '- [ ] item A\n' > "$SB/.loop/backlog.md"
LOOP_ENG_CLAUDE_BIN="$STUB" bash "$DRIVER" "$SB" 2>/dev/null && rc=0 || rc=$?
assert_eq 1 "$rc" "refuses without AUTOBUILD env"

# --- happy path: consumes backlog, one session per item, exits 0 ---
printf -- '- [ ] item A\n- [ ] item B\n' > "$SB/.loop/backlog.md"
STUB_MODE=progress LOOP_ENG_ALLOW_AUTOBUILD=1 LOOP_ENG_CLAUDE_BIN="$STUB" \
  bash "$DRIVER" "$SB" 5 >/dev/null 2>&1
assert_eq 0 $? "happy path exits 0"
assert_eq 0 "$(grep -c '^- \[ \]' "$SB/.loop/backlog.md")" "backlog fully consumed"
assert_file_contains "$SB/.loop/unattended.log" "backlog empty" "logs completion"

# --- circuit breaker: stall stub -> stops after exactly 2 sessions ---
SB2=$(mk_sandbox_repo); trap 'rm -rf "$SB" "$SB2" "$SD"' EXIT
mkdir -p "$SB2/.loop"
printf -- '- [ ] never done\n' > "$SB2/.loop/backlog.md"
STUB_MODE=stall LOOP_ENG_ALLOW_AUTOBUILD=1 LOOP_ENG_CLAUDE_BIN="$STUB" \
  bash "$DRIVER" "$SB2" 5 >/dev/null 2>&1
assert_eq 0 $? "breaker stop is a clean exit"
assert_file_contains "$SB2/.loop/unattended.log" "circuit breaker OPEN" "breaker logged"
assert_eq 2 "$(grep -c 'session .* starting' "$SB2/.loop/unattended.log")" "exactly 2 sessions before breaker"

# --- dirty tree refusal ---
echo dirty > "$SB2/untracked-src.txt"
STUB_MODE=stall LOOP_ENG_ALLOW_AUTOBUILD=1 LOOP_ENG_CLAUDE_BIN="$STUB" \
  bash "$DRIVER" "$SB2" 5 >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 1 "$rc" "dirty tree refused"

# --- non-numeric knobs warn + fall back to default instead of crashing ---
# MAX_MINUTES=xyz used to crash ("xyz: unbound variable" in $(( )) under set -u);
# a non-numeric max-sessions used to spam "[: integer expression expected" and
# silently disable the cap. Both must now warn and use the default.
SB3=$(mk_sandbox_repo); trap 'rm -rf "$SB" "$SB2" "$SB3" "$SD"' EXIT
mkdir -p "$SB3/.loop"; printf -- '- [ ] one\n' > "$SB3/.loop/backlog.md"
STUB_MODE=progress LOOP_ENG_ALLOW_AUTOBUILD=1 LOOP_ENG_MAX_MINUTES=xyz \
  LOOP_ENG_CLAUDE_BIN="$STUB" bash "$DRIVER" "$SB3" 5 2>"$SD/w1" && rc=0 || rc=$?
assert_eq 0 "$rc" "non-numeric MAX_MINUTES does not crash the driver"
assert_file_contains "$SD/w1" "not a non-negative integer" "warns on non-numeric MAX_MINUTES"

printf -- '- [ ] one\n' > "$SB3/.loop/backlog.md"
STUB_MODE=progress LOOP_ENG_ALLOW_AUTOBUILD=1 \
  LOOP_ENG_CLAUDE_BIN="$STUB" bash "$DRIVER" "$SB3" abc 2>"$SD/w2" && rc=0 || rc=$?
assert_eq 0 "$rc" "non-numeric max-sessions does not crash the driver"
assert_file_contains "$SD/w2" "not a non-negative integer" "warns on non-numeric max-sessions"
if grep -q 'integer expression expected' "$SD/w2"; then
  assert_eq 1 0 "max-sessions guard eliminates the '[: integer expression' spam"
else
  assert_eq 0 0 "max-sessions guard eliminates the '[: integer expression' spam"
fi

# --- leading-zero knobs (08/09) must not crash bash arithmetic as bad octal ---
printf -- '- [ ] one\n' > "$SB3/.loop/backlog.md"
STUB_MODE=progress LOOP_ENG_ALLOW_AUTOBUILD=1 LOOP_ENG_MAX_MINUTES=08 LOOP_ENG_LIMIT_WAIT_MIN=09 \
  LOOP_ENG_CLAUDE_BIN="$STUB" bash "$DRIVER" "$SB3" 07 2>"$SD/w3" && rc=0 || rc=$?
assert_eq 0 "$rc" "leading-zero numeric knobs (08/09/07) do not crash the driver"
if grep -qE 'value too great for base|unbound variable' "$SD/w3"; then
  assert_eq 1 0 "leading-zero knobs normalized to base-10 (no octal crash)"
else
  assert_eq 0 0 "leading-zero knobs normalized to base-10 (no octal crash)"
fi

# --- per-session timeout: claude is wrapped in `timeout -k 30 <remaining-budget>` ---
# A fake `timeout` first on PATH records its argv, then execs the wrapped command
# (or exits 124 in expire mode) — verifies the wiring without waiting minutes.
TD=$(mktemp -d "${TMPDIR:-/tmp}/loop-eng-faketo.XXXXXX")
trap 'rm -rf "$SB" "$SB2" "$SB3" "$SD" "$TD"' EXIT
cat > "$TD/timeout" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$TIMEOUT_RECORD"
[ "${FAKE_TIMEOUT_MODE:-exec}" = expire ] && exit 124
shift 3  # -k 30 <secs>
exec "$@"
EOF
chmod +x "$TD/timeout"

SB4=$(mk_sandbox_repo); trap 'rm -rf "$SB" "$SB2" "$SB3" "$SB4" "$SD" "$TD"' EXIT
mkdir -p "$SB4/.loop"; printf -- '- [ ] one\n' > "$SB4/.loop/backlog.md"
: > "$TD/record"
STUB_MODE=progress LOOP_ENG_ALLOW_AUTOBUILD=1 LOOP_ENG_CLAUDE_BIN="$STUB" \
  TIMEOUT_RECORD="$TD/record" PATH="$TD:$PATH" \
  bash "$DRIVER" "$SB4" 5 >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 0 "$rc" "session under fake timeout completes"
if grep -qE '^-k 30 [0-9]+ .*stub-claude' "$TD/record"; then
  assert_eq 0 0 "claude session is wrapped in 'timeout -k 30 <seconds>'"
else
  assert_eq "timeout-wrapped" "not-wrapped: $(head -1 "$TD/record" 2>/dev/null)" "claude session is wrapped in 'timeout -k 30 <seconds>'"
fi

# --- a session that hits the timeout (exit 124) is logged and feeds the breaker ---
printf -- '- [ ] never done\n' > "$SB4/.loop/backlog.md"
rm -f "$SB4/.loop/unattended.log"
STUB_MODE=progress LOOP_ENG_ALLOW_AUTOBUILD=1 LOOP_ENG_CLAUDE_BIN="$STUB" \
  TIMEOUT_RECORD="$TD/record" FAKE_TIMEOUT_MODE=expire PATH="$TD:$PATH" \
  bash "$DRIVER" "$SB4" 5 >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 0 "$rc" "timed-out sessions end in a clean breaker stop"
assert_file_contains "$SB4/.loop/unattended.log" "TIMED OUT" "timeout is named in the driver log"
assert_file_contains "$SB4/.loop/unattended.log" "circuit breaker OPEN" "timed-out sessions count as no progress"

# --- backlog deleted mid-run: counts as 0 pending, driver stops cleanly ---
# (pre-fix, count_pending returned "" and the empty-backlog stop was silently
# skipped, so the driver kept launching sessions against a missing backlog)
SB5=$(mk_sandbox_repo); trap 'rm -rf "$SB" "$SB2" "$SB3" "$SB4" "$SB5" "$SD" "$TD"' EXIT
mkdir -p "$SB5/.loop"; printf -- '- [ ] one\n' > "$SB5/.loop/backlog.md"
STUB_MODE=nuke-backlog LOOP_ENG_ALLOW_AUTOBUILD=1 LOOP_ENG_CLAUDE_BIN="$STUB" \
  bash "$DRIVER" "$SB5" 5 >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 0 "$rc" "backlog deleted mid-run stops cleanly"
assert_file_contains "$SB5/.loop/unattended.log" "backlog empty" "missing backlog counts as 0 pending"
assert_eq 1 "$(grep -c 'session .* starting' "$SB5/.loop/unattended.log")" "exactly 1 session before the empty-backlog stop"

# --- LOOP_ENG_MAX_MINUTES=0 is a config error: warn + default, never 'no limit' ---
printf -- '- [ ] one\n' > "$SB5/.loop/backlog.md"
STUB_MODE=progress LOOP_ENG_ALLOW_AUTOBUILD=1 LOOP_ENG_MAX_MINUTES=0 \
  LOOP_ENG_CLAUDE_BIN="$STUB" bash "$DRIVER" "$SB5" 5 2>"$SD/w4" >/dev/null && rc=0 || rc=$?
assert_eq 0 "$rc" "MAX_MINUTES=0 still runs (falls back to default)"
assert_file_contains "$SD/w4" "would disable the wall-clock budget" "warns that 0 would disable the budget"

report "test-unattended-autoloop"
