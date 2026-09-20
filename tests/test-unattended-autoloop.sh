#!/usr/bin/env bash
# unattended-autoloop: fresh-session-per-item, commit-keyed circuit breaker,
# auth env requirement, dirty-tree refusal. Uses a stub claude.
set -u
. "$(dirname "$0")/lib.sh"

DRIVER="$PLUGIN_ROOT/skills/loop-eng/scripts/unattended-autoloop.sh"

# --- bash floor: the header's "requires bash >= 4.4" is now enforced ---
# Pre-fix it was a comment, so on stock macOS bash 3.2 this driver STARTED and
# could let a session COMMIT before dying on the first empty-array expansion
# under set -u. Two arms are runnable anywhere: a non-bash shell (BASH_VERSION
# empty), and this machine's bash, which the suite itself requires to be >= 4.4
# and which must therefore NOT trip it. The genuine old-BASH arm needs a 3.2
# interpreter; CLAUDE.md's docker recipe covers it (verified exit 78 on 3.2.57)
# and the 3.2 CI leg does not run this suite, so it is deliberately not
# asserted here.
guard_out=$(sh "$DRIVER" 2>&1 >/dev/null); guard_rc=$?
assert_eq 78 "$guard_rc" "bash floor: a non-bash shell is refused with EX_CONFIG"
case "$guard_out" in
  *"bash >= 4.4"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: non-bash refusal does not name the requirement: $guard_out" >&2 ;;
esac
bash "$DRIVER" >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 78 ]; then PASS=$((PASS+1)); else
  FAIL=$((FAIL+1)); echo "  FAIL: the bash floor fired on this machine's bash ($BASH_VERSION)" >&2; fi

# ORDER, asserted structurally — this is the invariant, and the `sh` arm above
# cannot carry it. `set -o pipefail` is not POSIX: some sh implementations take
# it, others answer "Illegal option" and exit 2 before any guard below it runs.
# The two dashes disagreed (local accepted, the CI runner refused), so the arm
# above passed here and failed there. Whichever sh this machine has, the guard
# must sit ABOVE the set line or it is unreachable on the shells it exists for.
guard_ln=$(grep -n 'if \[ -z "${BASH_VERSION:-}" \]' "$DRIVER" | head -1 | cut -d: -f1)
setopt_ln=$(grep -n '^set -euo pipefail' "$DRIVER" | head -1 | cut -d: -f1)
if [ -n "$guard_ln" ] && [ -n "$setopt_ln" ] && [ "$guard_ln" -lt "$setopt_ln" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  echo "  FAIL: bash-floor guard (line ${guard_ln:-none}) must precede 'set -euo pipefail' (line ${setopt_ln:-none})" >&2
fi

SD=$(mktemp -d "${TMPDIR:-/tmp}/loop-eng-stub.XXXXXX")

mk_stub() { # $1 = stub dir OUTSIDE any sandbox repo (untracked stub inside
            #      the repo would trip the driver's dirty-tree refusal)
  cat > "$1/stub-claude" <<'EOF'
#!/usr/bin/env bash
# stub claude: "progress" marks the first backlog item done and commits;
# "stall" produces no commit. Runs inside the repo cwd set by the driver.
# STUB_ARGV_LOG, when set, captures the FULL argv one argument per line — the
# only way a test can see WHICH command and WHICH permission flags the driver
# handed claude. See the argv block below for what that hid.
[ -n "${STUB_ARGV_LOG:-}" ] && printf '%s\n' "$@" > "$STUB_ARGV_LOG"
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
  commit-no-tick)
    # The shape the commit-keyed breaker cannot see: real work, a real commit,
    # and the backlog line left unticked. HEAD moves, so no_progress resets to
    # 0 every session and the SAME item is handed to the next one — for as many
    # sessions as the cap allows. $$-unique for the same BSD-date reason as the
    # progress mode above.
    echo "worked on it" > "wip-$$.txt"
    git add -A >/dev/null
    git commit -qm "stub: committed work, box left unticked"
    echo "still working on it"
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

# --- WHICH command and WHICH permission flags reach claude ---
# This argv IS the driver's entire contract with the session: the /autoloop
# command that scopes it to ONE backlog item, the bypassPermissions mode that
# lets it write unattended, and the turn cap that bounds it. None of it was
# asserted — swapping `/autoloop` for `/polish` and `bypassPermissions` for
# `default` left this suite at 41 passed / 0 failed, so a driver that no longer
# does what its own name says would have shipped green. Mirrors the same block
# in tests/test-unattended-polish.sh.
argv_after() { # $1=argv file  $2=flag -> the argument that FOLLOWS that flag
  awk -v f="$2" 'p { print; exit } $0 == f { p = 1 }' "$1"
}
printf -- '- [ ] argv probe item\n' > "$SB/.loop/backlog.md"
STUB_MODE=progress LOOP_ENG_ALLOW_AUTOBUILD=1 LOOP_ENG_CLAUDE_BIN="$STUB" \
  STUB_ARGV_LOG="$SD/argv" bash "$DRIVER" "$SB" 1 >/dev/null 2>&1
prompt=$(argv_after "$SD/argv" -p)
case "$prompt" in
  "/autoloop "*) assert_eq 0 0 "session is driven by /autoloop, not some other command" ;;
  *) assert_eq "/autoloop …" "$prompt" "session is driven by /autoloop, not some other command" ;;
esac
case "$prompt" in
  *'"argv probe item"'*) assert_eq 0 0 "prompt names the one backlog item this session may take" ;;
  *) assert_eq 'quoted "argv probe item"' "$prompt" "prompt names the one backlog item this session may take" ;;
esac
assert_eq "bypassPermissions" "$(argv_after "$SD/argv" --permission-mode)" \
  "session runs under --permission-mode bypassPermissions"
assert_eq "150" "$(argv_after "$SD/argv" --max-turns)" \
  "session is capped at --max-turns 150"

# The write-mode opt-in must gate the session itself, not just the exit code:
# without LOOP_ENG_ALLOW_AUTOBUILD=1 no claude may be invoked at all.
printf -- '- [ ] argv probe item\n' > "$SB/.loop/backlog.md"
rm -f "$SD/argv-noenv"
LOOP_ENG_CLAUDE_BIN="$STUB" STUB_ARGV_LOG="$SD/argv-noenv" \
  bash "$DRIVER" "$SB" 1 >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 1 "$rc" "refuses without AUTOBUILD env (again, with argv capture armed)"
if [ -e "$SD/argv-noenv" ]; then
  assert_eq "no session" "session launched" "refused run never invokes claude"
else
  assert_eq 0 0 "refused run never invokes claude"
fi

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

# --- a stop-gate left armed by a previous session is reclaimed, not inherited ---
# .loop/active is lifted only when the contract goes green. A session that was
# killed (this driver's own timeout, a TERM, a crash) or that hit the 3-block
# ceiling leaves it behind with a clean tree. The NEXT session then tries to
# write its own criteria.tsv and the evidence-gate denies it — through Write and
# through Bash, because that file is the armed contract — so the session arms
# nothing, commits nothing, and two of those open the circuit breaker with only
# `NO new commits` in the log to explain a backlog that stopped moving.
#
# The stub here stands in for that blocked session: it writes NO commit, exactly
# like a real one that could not arm. What is asserted is that the driver clears
# the leftover instead of handing it to the next session.
SBG=$(mk_sandbox_repo); trap 'rm -rf "$SB" "$SB2" "$SB3" "$SB4" "$SB5" "$SB6" "$SB7" "$SB8" "$SBG" "$SD" "$TD"' EXIT
mkdir -p "$SBG/.loop"; printf -- '- [ ] one\n' > "$SBG/.loop/backlog.md"
: > "$SBG/.loop/active"                       # leftover from a killed session
printf 'stale\tred\tfalse\n' > "$SBG/.loop/criteria.tsv"
sha_of "$SBG/.loop/criteria.tsv" > "$SBG/.loop/criteria.sha256"
echo 2 > "$SBG/.loop/gate-count"
STUB_MODE=progress LOOP_ENG_ALLOW_AUTOBUILD=1 LOOP_ENG_CLAUDE_BIN="$STUB" \
  bash "$DRIVER" "$SBG" 1 >/dev/null 2>&1 || true
assert_file_contains "$SBG/.loop/unattended.log" "left the gate armed" "the driver says it found a stale armed gate"
if [ -f "$SBG/.loop/active" ]; then
  assert_eq "disarmed" "still armed" "the driver clears .loop/active before the next session"
else
  assert_eq 0 0 "the driver clears .loop/active before the next session"
fi
# all three, not just active: a lone criteria.sha256 makes the NEXT arm's own
# criteria.tsv read as tampered (exit 77 on every stop), and a lone gate-count
# starts that loop partway to the 3-block ceiling.
if [ -f "$SBG/.loop/criteria.sha256" ]; then
  assert_eq "cleared" "left behind" "the driver clears the stale hash-lock too"
else
  assert_eq 0 0 "the driver clears the stale hash-lock too"
fi
if [ -f "$SBG/.loop/gate-count" ]; then
  assert_eq "cleared" "left behind" "the driver clears the stale block counter too"
else
  assert_eq 0 0 "the driver clears the stale block counter too"
fi

# ...and a session that ends with the gate STILL armed must be reclaimed before
# the next one starts, not left for the next driver run — otherwise one killed
# session costs every remaining session of this run.
SBG2=$(mk_sandbox_repo); trap 'rm -rf "$SB" "$SB2" "$SB3" "$SB4" "$SB5" "$SB6" "$SB7" "$SB8" "$SBG" "$SBG2" "$SD" "$TD"' EXIT
mkdir -p "$SBG2/.loop"; printf -- '- [ ] one\n- [ ] two\n' > "$SBG2/.loop/backlog.md"
ARMER="$SD/stub-armer"
cat > "$ARMER" <<'EOF'
#!/usr/bin/env bash
# a session that arms the gate and then dies without reaching green
: > .loop/active
printf 'x\tred\tfalse\n' > .loop/criteria.tsv
exit 1
EOF
chmod +x "$ARMER"
LOOP_ENG_ALLOW_AUTOBUILD=1 LOOP_ENG_CLAUDE_BIN="$ARMER" \
  bash "$DRIVER" "$SBG2" 2 >/dev/null 2>&1 || true
assert_eq 2 "$(grep -c 'left the gate armed' "$SBG2/.loop/unattended.log")" "each session's leftover is reclaimed in the same run, not carried to the next"
if [ -f "$SBG2/.loop/active" ]; then
  assert_eq "disarmed" "still armed" "the run does not end with the gate armed"
else
  assert_eq 0 0 "the run does not end with the gate armed"
fi

# --- one driver per repo: the second concurrent run is refused, not run ---
# Same finding and same two mechanisms as the block in
# tests/test-unattended-polish.sh; this driver is the one whose sessions WRITE
# CODE, so two of them on one tree interleave commits. Reproduced pre-fix with
# two concurrent drivers: both started a session.
SBL=$(mk_sandbox_repo); trap 'rm -rf "$SB" "$SB2" "$SB3" "$SB4" "$SB5" "$SB6" "$SB7" "$SB8" "$SBL" "$SD" "$TD"' EXIT
mkdir -p "$SBL/.loop"; printf -- '- [ ] one\n' > "$SBL/.loop/backlog.md"
LOCK_STUB="$SD/stub-slow"
cat > "$LOCK_STUB" <<'EOF'
#!/usr/bin/env bash
echo "session $$ started" >> "$CONC_LOG"
sleep 3
EOF
chmod +x "$LOCK_STUB"
NOFLOCK="$SD/noflock"; mkdir -p "$NOFLOCK"
for b in bash sh git grep sed awk cat cut head tail wc mktemp rm mkdir rmdir \
         dirname basename find chmod touch date env tee sleep kill; do
  bp=$(command -v "$b" 2>/dev/null) || bp=""
  if [ -n "$bp" ]; then ln -sf "$bp" "$NOFLOCK/$b"; else
    FAIL=$((FAIL+1)); echo "  FAIL: test prerequisite '$b' is not on PATH" >&2; fi
done

lock_race() { # $1 = PATH to run both drivers under -> sets LOCK_SESSIONS, LOCK_RC2
  : > "$SD/conc"
  CONC_LOG="$SD/conc" PATH="$1" LOOP_ENG_ALLOW_AUTOBUILD=1 LOOP_ENG_CLAUDE_BIN="$LOCK_STUB" \
    bash "$DRIVER" "$SBL" 1 >/dev/null 2>&1 &
  local a=$!
  sleep 1   # let the first driver take the lock before the second starts
  CONC_LOG="$SD/conc" PATH="$1" LOOP_ENG_ALLOW_AUTOBUILD=1 LOOP_ENG_CLAUDE_BIN="$LOCK_STUB" \
    bash "$DRIVER" "$SBL" 1 >/dev/null 2>&1 &
  local b=$!
  wait "$a" || true
  wait "$b" && LOCK_RC2=0 || LOCK_RC2=$?
  LOCK_SESSIONS=$(grep -c 'started' "$SD/conc" 2>/dev/null || echo 0)
}

lock_race "$PATH"
assert_eq 1 "$LOCK_SESSIONS" "flock: exactly one of two concurrent drivers starts a session"
assert_eq 69 "$LOCK_RC2" "flock: the refused driver exits 69 (EX_UNAVAILABLE), not 0 and not 75"
lock_race "$NOFLOCK"
assert_eq 1 "$LOCK_SESSIONS" "mkdir fallback: exactly one of two concurrent drivers starts a session"
assert_eq 69 "$LOCK_RC2" "mkdir fallback: the refused driver exits 69 (EX_UNAVAILABLE)"
assert_file_contains "$SBL/.loop/unattended.log" "already running" "the refusal is recorded in the rolling log"

# --- SIGTERM to the driver must not leave the session running ---
# Pre-fix neither driver had a trap (`grep -c trap` = 0 in both) and GNU
# `timeout` puts itself in its own process group, so `systemctl stop` on a host
# whose unit does not cgroup-kill, a cron `kill <pid>`, or a hand-typed Ctrl-C
# killed the driver and left a `bypassPermissions` claude running to its own
# budget — and THIS driver's session writes code. Reproduced exactly this way:
# driver dead, stub alive. Mirrors the same block in test-unattended-polish.sh.
#
# The stub records its pid and then BECOMES `sleep` via exec, so the recorded
# pid is the process a terminating driver actually has to reach through its
# `timeout -k 30 <budget>` wrapper — not a bash shell that could die while its
# own child survives, which is the failure mode under test.
SB9=$(mk_sandbox_repo); trap 'rm -rf "$SB" "$SB2" "$SB3" "$SB4" "$SB5" "$SB6" "$SB7" "$SB8" "$SB9" "$SD" "$TD"' EXIT
mkdir -p "$SB9/.loop"; printf -- '- [ ] one\n' > "$SB9/.loop/backlog.md"
TERM_STUB="$SD/stub-sleeper"
cat > "$TERM_STUB" <<'EOF'
#!/usr/bin/env bash
echo $$ > "$STUB_PIDFILE"
exec sleep 30
EOF
chmod +x "$TERM_STUB"
rm -f "$SD/termpid"
STUB_PIDFILE="$SD/termpid" LOOP_ENG_ALLOW_AUTOBUILD=1 LOOP_ENG_CLAUDE_BIN="$TERM_STUB" \
  bash "$DRIVER" "$SB9" 5 >/dev/null 2>&1 &
TERM_DRV=$!
for _ in $(seq 1 60); do [ -s "$SD/termpid" ] && break; sleep 0.2; done
if [ -s "$SD/termpid" ]; then
  TERM_SESS=$(cat "$SD/termpid")
  assert_eq 0 0 "the sleeping session started (driver reached the claude call)"
  kill -TERM "$TERM_DRV" 2>/dev/null || true
  wait "$TERM_DRV" 2>/dev/null && term_rc=0 || term_rc=$?
  assert_eq 143 "$term_rc" "a TERMed driver exits 143 (128+SIGTERM), not a bare 0 or 1"
  for _ in $(seq 1 60); do kill -0 "$TERM_SESS" 2>/dev/null || break; sleep 0.2; done
  if kill -0 "$TERM_SESS" 2>/dev/null; then
    kill -KILL "$TERM_SESS" 2>/dev/null || true   # never leak it out of the suite
    assert_eq "session terminated" "session orphaned" "TERM to the driver terminates the claude session through the timeout wrapper"
  else
    assert_eq 0 0 "TERM to the driver terminates the claude session through the timeout wrapper"
  fi
  assert_file_contains "$SB9/.loop/unattended.log" "interrupted by signal" "the interruption is recorded, with the pending count"
  assert_file_contains "$SB9/.loop/unattended.log" "item(s) still pending" "the interruption log says how much work was left"
else
  kill -TERM "$TERM_DRV" 2>/dev/null || true
  wait "$TERM_DRV" 2>/dev/null || true
  FAIL=$((FAIL+1)); echo "  FAIL: the sleeping stub never recorded a pid — the SIGTERM arm did not run" >&2
fi

# --- a failed session whose LOG TEXT mentions a quota is not a provider limit ---
# Same finding as in tests/test-unattended-polish.sh: "only runs on failed
# sessions" does not bound the false-positive surface, because a session's log
# carries the code it read and wrote. Here the cost is worse than a mislabelled
# exit code — a detected limit also parks the driver in
# `sleep $((LIMIT_WAIT_MIN * 60))`, so at the default this hands an unattended
# run a full hour of doing nothing before it retries a failure that will not fix
# itself, then stops with exit 75 ("try again later") after the second one.
# LIMIT_WAIT_MIN=0 is pinned here for that reason: it keeps a regression in this
# branch a failing assertion instead of an hour-long hang in the suite.
SBQ=$(mk_sandbox_repo)
mkdir -p "$SBQ/.loop"; printf -- '- [ ] one\n' > "$SBQ/.loop/backlog.md"
FP_STUB="$SD/stub-reviewtext"
cat > "$FP_STUB" <<'EOF'
#!/usr/bin/env bash
echo "editing src/quota.js — the quota is never reset, and the limiter is overloaded"
exit 2
EOF
chmod +x "$FP_STUB"
LOOP_ENG_ALLOW_AUTOBUILD=1 LOOP_ENG_LIMIT_WAIT_MIN=0 LOOP_ENG_CLAUDE_BIN="$FP_STUB" \
  bash "$DRIVER" "$SBQ" 5 >/dev/null 2>&1 && rc=0 || rc=$?   # 5, not 2: the session
  # cap is checked before the breaker, so a cap of 2 would stop the run with
  # "session cap reached" and this block would never see the verdict it is about
assert_eq 1 "$rc" "sessions failing over quota-shaped CODE stop at the breaker (exit 1), not as a provider limit (75)"
assert_eq "" "$(grep -c 'provider limit' "$SBQ/.loop/unattended.log" | grep -v '^0$')" "no provider-limit entry for failures that are not one"
assert_file_contains "$SBQ/.loop/unattended.log" "circuit breaker OPEN" "they are counted as no-progress, which is what they are"

# --- non-git target: refuse with a named reason, not a raw git fatal ---
# The driver reached `git rev-parse HEAD` and died under `set -e` with git's own
# "fatal: not a git repository" (exit 128) — it stopped, but the operator got a
# stack of raw git noise instead of the one fact that matters, and the
# dirty-tree guard above it had already silently passed.
NOGIT_AL="$SD/nogit-autoloop"
mkdir -p "$NOGIT_AL/.loop"; printf -- '- [ ] one\n' > "$NOGIT_AL/.loop/backlog.md"
STUB_MODE=progress LOOP_ENG_ALLOW_AUTOBUILD=1 LOOP_ENG_CLAUDE_BIN="$STUB" \
  bash "$DRIVER" "$NOGIT_AL" 2 >/dev/null 2>"$SD/nogit-al-err" && rc=0 || rc=$?
assert_eq 1 "$rc" "non-git target refused with the driver's own exit 1, not git's 128"
assert_file_contains "$SD/nogit-al-err" "not a git repository" "refusal says the target is not a git repository"

SBW=$(mk_sandbox_repo)
SBW0=$(mk_sandbox_repo)
SBW3=$(mk_sandbox_repo)
# Every sandbox this suite creates, named once, in the trap that actually
# runs. The previous shape re-installed a longer trap beside each new
# sandbox — a hand-maintained list that had already dropped $SBG/$SBG2 once
# and $SB9 again, so a killed suite leaked exactly the dirs the growing
# trap was supposed to be collecting.
trap 'rm -rf "$SB" "$SB2" "$SB3" "$SB4" "$SB5" "$SB6" "$SB7" "$SB8" "$SB9" "$SBG" "$SBG2" "$SBL" "$SBQ" "$SBW" "$SBW0" "$SBW3" "$SD" "$TD"' EXIT

# --- P2-5: a session that COMMITS but never ticks its box must still stop the
#     driver. ---
# The circuit breaker is keyed to commits, which is the right signal for "did
# anything happen" and the wrong one for "did the backlog move". A session that
# does real work, commits it, and leaves the line unticked resets no_progress to
# 0 — so the next session gets the SAME item, commits again, resets again, and
# the driver spends its entire cap on one backlog entry. Reproduced pre-fix at 8
# sessions on "only item" with `grep -c 'starting: only item'`.
mkdir -p "$SBW/.loop"
printf -- '- [ ] item A\n- [ ] item B\n' > "$SBW/.loop/backlog.md"
STUB_MODE=commit-no-tick LOOP_ENG_ALLOW_AUTOBUILD=1 LOOP_ENG_CLAUDE_BIN="$STUB" \
  bash "$DRIVER" "$SBW" 8 >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 1 "$rc" "commits without a tick end in a give-up exit 1"
assert_eq 2 "$(grep -c 'session .* starting' "$SBW/.loop/unattended.log")" "the same item gets 2 sessions, not the whole 8-session cap"
assert_file_contains "$SBW/.loop/unattended.log" "same backlog item" "the stop reason names what actually stalled"
assert_file_contains "$SBW/.loop/unattended.log" "item A" "the stop reason quotes the item"

# An item that legitimately needs more than one session is the reason the arm
# has an off switch; 0 restores the pre-fix behavior exactly.
mkdir -p "$SBW0/.loop"
printf -- '- [ ] only item\n' > "$SBW0/.loop/backlog.md"
STUB_MODE=commit-no-tick LOOP_ENG_ALLOW_AUTOBUILD=1 LOOP_ENG_CLAUDE_BIN="$STUB" \
  LOOP_ENG_MAX_ITEM_SESSIONS=0 bash "$DRIVER" "$SBW0" 3 >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 1 "$rc" "MAX_ITEM_SESSIONS=0 still gives up with the item pending"
assert_eq 3 "$(grep -c 'session .* starting' "$SBW0/.loop/unattended.log")" "MAX_ITEM_SESSIONS=0 disables the same-item arm (runs to the cap)"

# Ticking the box resets the counter — the healthy path must not trip the arm.
# Three items, three sessions, default MAX_ITEM_SESSIONS=2: with a counter that
# never reset, session 3 would be "the third on the same item" and break early.
mkdir -p "$SBW3/.loop"
printf -- '- [ ] one\n- [ ] two\n- [ ] three\n' > "$SBW3/.loop/backlog.md"
STUB_MODE=progress LOOP_ENG_ALLOW_AUTOBUILD=1 LOOP_ENG_CLAUDE_BIN="$STUB" \
  bash "$DRIVER" "$SBW3" 5 >/dev/null 2>&1
assert_eq 0 $? "three different items in a row do not trip the same-item arm"
assert_eq 0 "$(grep -c '^- \[ \]' "$SBW3/.loop/backlog.md")" "all three items consumed"

report "test-unattended-autoloop"
