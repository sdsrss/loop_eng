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
    # awk, not sed: GNU's first-match-only address `0,/re/` does not exist in
    # BSD sed (macOS) — there the sed errored, the item was never marked, no
    # commit happened, and the happy path flaked into the circuit breaker.
    awk '!d && /^- \[ \]/ { sub(/^- \[ \]/, "- [x]"); d=1 } { print }' \
      .loop/backlog.md > .loop/backlog.md.new && mv .loop/backlog.md.new .loop/backlog.md
    # $$-unique, not date-based: BSD date has no %N (prints a literal "N"), so
    # two same-second sessions would collide on the filename -> empty commit ->
    # stub exits non-zero -> flaky breaker counts on macOS CI.
    echo "done one item" > "progress-$$.txt"
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
  limit)
    # simulates a provider usage/rate limit: the session log must mention a
    # usage limit and the process must exit non-zero, so the driver's limit
    # branch (grep 'usage limit|rate.?limit' on a STATUS!=0 session) fires.
    # Mirrors tests/test-unattended-polish.sh's `limit` stub mode.
    echo "usage limit reached"
    exit 1
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
  bash "$DRIVER" "$SB2" 5 >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 1 "$rc" "breaker stop exits 1 (backlog not drained)"
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
assert_eq 1 "$rc" "timed-out sessions end in a breaker stop with exit 1 (item still pending)"
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

# --- log rotation: >30-day session logs pruned, oversized rolling log capped ---
# touch -t (not GNU-only `touch -d '40 days ago'`) so the fake-old mtime also
# works on BSD/macOS CI; any fixed past date is always >30 days old.
SB6=$(mk_sandbox_repo); trap 'rm -rf "$SB" "$SB2" "$SB3" "$SB4" "$SB5" "$SB6" "$SD" "$TD"' EXIT
mkdir -p "$SB6/.loop"; printf -- '- [ ] one\n' > "$SB6/.loop/backlog.md"
OLD_SLOG="$SB6/.loop/unattended-session-20200101-000000.log"
echo "ancient session" > "$OLD_SLOG"
touch -t 202001010000 "$OLD_SLOG"
{ head -c 1200000 /dev/zero | tr '\0' 'x'; echo; echo "TAIL-MARKER-SURVIVES"; } > "$SB6/.loop/unattended.log"
STUB_MODE=progress LOOP_ENG_ALLOW_AUTOBUILD=1 LOOP_ENG_CLAUDE_BIN="$STUB" \
  bash "$DRIVER" "$SB6" 5 >/dev/null 2>&1
assert_eq 0 $? "rotation run exits 0"
if [ -e "$OLD_SLOG" ]; then
  assert_eq "pruned" "still-present" ">30-day session log is pruned"
else
  assert_eq 0 0 ">30-day session log is pruned"
fi
ROLL_SIZE=$(wc -c < "$SB6/.loop/unattended.log")
if [ "$ROLL_SIZE" -le 1048576 ]; then
  assert_eq 0 0 "oversized unattended.log truncated to <=1MB (now $ROLL_SIZE bytes)"
else
  assert_eq "<=1048576" "$ROLL_SIZE" "oversized unattended.log truncated to <=1MB"
fi
assert_file_contains "$SB6/.loop/unattended.log" "TAIL-MARKER-SURVIVES" "truncation keeps the tail (marker survives)"

# --- gave-up exit code: stopping at the session cap with items left exits 1 ---
# (pre-fix, every break path fell through to the same exit-0 "driver done" line,
# so a systemd timer / exit-code monitor could not tell "converged" from "gave
# up with N items pending" — the stuck backlog stayed green indefinitely)
SB7=$(mk_sandbox_repo); trap 'rm -rf "$SB" "$SB2" "$SB3" "$SB4" "$SB5" "$SB6" "$SB7" "$SD" "$TD"' EXIT
mkdir -p "$SB7/.loop"; printf -- '- [ ] one\n- [ ] two\n' > "$SB7/.loop/backlog.md"
STUB_MODE=progress LOOP_ENG_ALLOW_AUTOBUILD=1 LOOP_ENG_CLAUDE_BIN="$STUB" \
  bash "$DRIVER" "$SB7" 1 >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 1 "$rc" "session cap with pending items exits 1 (gave up, not done)"
assert_file_contains "$SB7/.loop/unattended.log" "session cap" "cap stop is named in the log"
assert_file_contains "$SB7/.loop/unattended.log" "not drained" "non-zero exit reason is logged"

# --- provider limit twice: retries once (zero wait) then stops with exit 75 ---
# (driver lines ~162-168: a failed session whose log mentions a usage/rate limit
# increments limit_hits; the first hit waits LOOP_ENG_LIMIT_WAIT_MIN then retries,
# the second hit stops with exit 75 (EX_TEMPFAIL). LIMIT_WAIT_MIN=0 keeps the
# retry wait at `sleep 0` so this test never actually sleeps — 0 is accepted by
# _num_or_default for LIMIT_WAIT_MIN; only MAX_MINUTES=0 is rejected. Exactly two
# sessions run: one per hit, and the second hit exits before a third launches.)
SB8=$(mk_sandbox_repo); trap 'rm -rf "$SB" "$SB2" "$SB3" "$SB4" "$SB5" "$SB6" "$SB7" "$SB8" "$SD" "$TD"' EXIT
mkdir -p "$SB8/.loop"; printf -- '- [ ] one\n' > "$SB8/.loop/backlog.md"
STUB_MODE=limit LOOP_ENG_ALLOW_AUTOBUILD=1 LOOP_ENG_LIMIT_WAIT_MIN=0 LOOP_ENG_CLAUDE_BIN="$STUB" \
  bash "$DRIVER" "$SB8" 5 >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 75 "$rc" "provider limit hit twice exits 75 (EX_TEMPFAIL)"
assert_file_contains "$SB8/.loop/unattended.log" "provider limit hit twice" "second limit hit is logged and stops the driver"
assert_eq 2 "$(grep -c 'session .* starting' "$SB8/.loop/unattended.log")" "driver ran exactly 2 sessions before the limit stop"

report "test-unattended-autoloop"
