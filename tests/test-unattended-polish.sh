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
# stub claude: behavior driven by STUB_MODE.
# STUB_ARGV_LOG, when set, captures the FULL argv one argument per line. Without
# it nothing downstream could see WHICH prompt and WHICH permission flags the
# driver handed claude — see the argv block below for what that hid.
[ -n "${STUB_ARGV_LOG:-}" ] && printf '%s\n' "$@" > "$STUB_ARGV_LOG"
# STUB_ENV_LOG captures the ENV bounds. argv is not the whole contract a driver
# hands a session: the CLI's print-mode background ceiling is an environment
# knob, and a bound the driver never sets is still a bound it runs under.
[ -n "${STUB_ENV_LOG:-}" ] && printf 'CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=%s\n' \
  "${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS-<unset>}" > "$STUB_ENV_LOG"
case "${STUB_MODE:-ok}" in
  ok)    echo "polish report: 0 findings"; exit 0 ;;
  fail)  echo "boom"; exit 3 ;;
  limit) echo "${STUB_LIMIT_MSG:-Claude AI usage limit reached}"; exit 1 ;;
  # An auto-fix session that edits the tree and never commits — what
  # --max-turns exhaustion mid-fix leaves behind. `claude -p` still exits 0,
  # which is the whole problem: the driver reported success for a run whose
  # changes are unattributable and which will make every later run refuse the
  # tree as dirty.
  dirty) echo "applied a fix"; echo "half-applied" > leftover-fix.txt; exit 0 ;;
  # The same abandonment, at SCALE — see the wide-tree block at the bottom of
  # this file. The post-run truth check reads `git status --porcelain` through
  # the same pipeline the pre-run guard does, so it has the same blind spot,
  # and a session that abandons thousands of files is the one the check most
  # has to catch. Only meaningful in a mk_wide_sandbox_repo tree.
  dirty-wide)
    echo "applied fixes"
    for f in wide/*; do echo "half-applied" > "$f"; done
    exit 0 ;;
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

# --- WHICH prompt and WHICH permission flags reach claude ---
# `report-only` is this driver's ONLY write protection and it lives entirely in
# the `-p "/polish $SCOPE $MODE"` string. Nothing asserted it: deleting `$MODE`
# from that line — i.e. auto-fixing the repo unattended under bypassPermissions
# every night, the exact failure the two-key opt-in above exists to prevent —
# left this suite at 39 passed / 0 failed. The argv shape tests above check the
# flags going IN; these check the command going OUT, which is where the default
# actually is. Same blind spot covered for the permission mode and the turn cap,
# the two other bounds on an unattended session.
argv_after() { # $1=argv file  $2=flag -> the argument that FOLLOWS that flag
  awk -v f="$2" 'p { print; exit } $0 == f { p = 1 }' "$1"
}
STUB_MODE=ok LOOP_ENG_CLAUDE_BIN="$STUB" STUB_ARGV_LOG="$SD/argv-report" \
  bash "$SCRIPT" "$SB" src/ >/dev/null
assert_eq "/polish src/ report-only" "$(argv_after "$SD/argv-report" -p)" \
  "default run asks for report-only (the write protection is the prompt)"
assert_eq "bypassPermissions" "$(argv_after "$SD/argv-report" --permission-mode)" \
  "session runs under --permission-mode bypassPermissions"
assert_eq "120" "$(argv_after "$SD/argv-report" --max-turns)" \
  "session is capped at --max-turns 120"

# ...and the bound that is NOT in argv. `claude -p` terminates still-running
# background subagents after CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS and exits 0;
# the CLI default is 600000 (10 minutes), against this driver's MAX_MINUTES
# default of 120. A loop whose subagents the harness runs in the background is
# therefore cut off by a bound the driver never set, twelve times sooner than
# the one it did, and the truncated run is indistinguishable from a finished one
# — report-only is even exempt from the post-run check. Measured 2026-09-20 on
# CLI 2.1.278: a headless `/polish hooks/` reported subagent_stats
# killed.system=1 with 4 of 5 dispatches completed, and exited 0.
STUB_MODE=ok LOOP_ENG_CLAUDE_BIN="$STUB" STUB_ENV_LOG="$SD/env-report" \
  bash "$SCRIPT" "$SB" src/ >/dev/null
assert_file_contains "$SD/env-report" "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0" \
  "session gets an unbounded background ceiling, leaving timeout the only budget"

# ...and the opted-in write mode is the ONLY way report-only comes off.
STUB_MODE=ok LOOP_ENG_ALLOW_AUTOFIX=1 LOOP_ENG_CLAUDE_BIN="$STUB" STUB_ARGV_LOG="$SD/argv-fix" \
  bash "$SCRIPT" "$SB" src/ --auto-fix >/dev/null
if grep -qF 'report-only' "$SD/argv-fix"; then
  assert_eq "report-only dropped" "report-only still sent" \
    "--auto-fix with LOOP_ENG_ALLOW_AUTOFIX=1 drops report-only"
else
  assert_eq 0 0 "--auto-fix with LOOP_ENG_ALLOW_AUTOFIX=1 drops report-only"
fi
assert_file_contains "$SD/argv-fix" "/polish src/" "write-mode run still targets the requested scope"

# The flag WITHOUT the env var must not reach claude at all — the refusal is
# supposed to happen before the session starts, not inside it.
rm -f "$SD/argv-noenv"
STUB_MODE=ok LOOP_ENG_CLAUDE_BIN="$STUB" STUB_ARGV_LOG="$SD/argv-noenv" \
  bash "$SCRIPT" "$SB" src/ --auto-fix >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 1 "$rc" "--auto-fix without LOOP_ENG_ALLOW_AUTOFIX=1 is refused"
if [ -e "$SD/argv-noenv" ]; then
  assert_eq "no session" "session launched" "refused --auto-fix never invokes claude"
else
  assert_eq 0 0 "refused --auto-fix never invokes claude"
fi

# --- non-git target: the dirty-tree guard must not fail OPEN ---
# `git status --porcelain` in a non-repo writes its fatal to stderr and leaves
# stdout EMPTY, so the guard found no line, reported "not dirty", and the run
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

# --- a failure whose REVIEW TEXT mentions a quota is not a provider limit ---
# "The grep only runs on failed runs, which bounds the false-positive surface"
# was the stated reasoning and it does not hold: a polish session reviews code,
# so its log is full of the text under review. Any real failure while reviewing
# a rate limiter came back as EX_TEMPFAIL 75 — "try again later" — and the
# actual failure never surfaced to whatever watches exit codes. Reproduced: a
# stub printing `checkQuota() { /* the quota is never reset */ }` and exiting 2
# was reported exit 75, `rate-limited`.
FP_STUB="$SD/stub-reviewtext"
cat > "$FP_STUB" <<'EOF'
#!/usr/bin/env bash
cat <<'OUT'
reviewing src/quota.js ...
  function checkQuota() { /* the quota is never reset */ }
finding: the rate-limiter is overloaded on retry
OUT
exit 2
EOF
chmod +x "$FP_STUB"
LOOP_ENG_CLAUDE_BIN="$FP_STUB" bash "$SCRIPT" "$SB" src/ >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 2 "$rc" "a real failure is passed through, not relabelled EX_TEMPFAIL, when the reviewed code mentions quotas"
# The LAST line, not the whole log: the legitimate rate-limit cases above appended
# real `rate-limited` entries to this same rolling log, so a whole-file grep
# would report this run as marked no matter what it did.
if tail -1 "$SB/.loop/unattended.log" | grep -qF 'rate-limited'; then
  assert_eq "plain failure entry" "rate-limited entry" "no rate-limited marker for a failure that is not one"
else
  assert_eq 0 0 "no rate-limited marker for a failure that is not one"
fi

# --- and a run killed by OUR OWN wall-clock cap is a timeout, not a limit ---
# 0.14.0's release notes recorded this as a known consequence of enforcing the
# cap on macOS: a killed run exits 124 and its partial log may carry anything.
TO_STUB="$SD/stub-124"
printf '#!/usr/bin/env bash\necho "usage limit reached"\nexit 124\n' > "$TO_STUB"
chmod +x "$TO_STUB"
LOOP_ENG_CLAUDE_BIN="$TO_STUB" bash "$SCRIPT" "$SB" src/ >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 124 "$rc" "a 124 run reports the timeout, not a provider limit, whatever its partial log says"

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

# --- one driver per repo: the second concurrent run is refused, not run ---
# Nothing enforced this. Two drivers launched against one tree both passed the
# dirty-tree check (the tree IS clean at that instant) and both started a
# `bypassPermissions` session — two claudes interleaving edits and commits in
# one working copy. Reproduced with two concurrent drivers: 2 sessions started.
# install-timer.sh defaults BOTH modes to --time 03:00, so installing a polish
# timer and an autoloop timer on one repo is the documented route to it.
#
# Both lock mechanisms are exercised: `flock` where the host has it, and the
# atomic-`mkdir` fallback that stock macOS (no flock(1)) actually runs. Testing
# only whichever this host happens to have would leave the other unasserted on
# every leg of CI — which is how a fallback rots.
LOCK_STUB="$SD/stub-slow"
cat > "$LOCK_STUB" <<'EOF'
#!/usr/bin/env bash
echo "session $$ started" >> "$CONC_LOG"
sleep 3
EOF
chmod +x "$LOCK_STUB"
# a PATH with no flock, so the mkdir fallback is reachable on a host that has it
NOFLOCK="$SD/noflock"; mkdir -p "$NOFLOCK"
for b in bash sh git grep sed awk cat cut head tail wc mktemp rm mkdir rmdir \
         dirname basename find chmod touch date env tee sleep kill; do
  bp=$(command -v "$b" 2>/dev/null) || bp=""
  if [ -n "$bp" ]; then ln -sf "$bp" "$NOFLOCK/$b"; else
    FAIL=$((FAIL+1)); echo "  FAIL: test prerequisite '$b' is not on PATH" >&2; fi
done
if [ -e "$NOFLOCK/flock" ]; then
  assert_eq "no flock" "flock present" "the fallback PATH really has no flock(1)"
else
  assert_eq 0 0 "the fallback PATH really has no flock(1)"
fi

lock_race() { # $1 = PATH to run both drivers under -> sets LOCK_SESSIONS, LOCK_RC2
  : > "$SD/conc"
  CONC_LOG="$SD/conc" PATH="$1" LOOP_ENG_CLAUDE_BIN="$LOCK_STUB" \
    bash "$SCRIPT" "$SB" src/ >/dev/null 2>&1 &
  local a=$!
  sleep 1   # let the first driver take the lock before the second starts
  CONC_LOG="$SD/conc" PATH="$1" LOOP_ENG_CLAUDE_BIN="$LOCK_STUB" \
    bash "$SCRIPT" "$SB" src/ >/dev/null 2>&1 &
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
assert_file_contains "$SB/.loop/unattended.log" "already running" "the refusal is recorded in the rolling log"
if [ -d "$SB/.loop/driver.lock" ]; then
  assert_eq "released" "still held" "the mkdir lock is released when the driver exits"
else
  assert_eq 0 0 "the mkdir lock is released when the driver exits"
fi

# A driver killed with SIGKILL runs no trap, so the mkdir lock outlives it. The
# pid inside is what tells "held" from "abandoned" — without that check the
# first hard kill would wedge every future scheduled run.
mkdir -p "$SB/.loop/driver.lock"
echo 999999 > "$SB/.loop/driver.lock/pid"   # a pid no live process can have here
: > "$SD/conc"
CONC_LOG="$SD/conc" PATH="$NOFLOCK" LOOP_ENG_CLAUDE_BIN="$LOCK_STUB" \
  bash "$SCRIPT" "$SB" src/ >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 0 "$rc" "mkdir fallback: a stale lock left by a SIGKILLed driver is reclaimed, not obeyed forever"
assert_eq 1 "$(grep -c 'started' "$SD/conc" 2>/dev/null || echo 0)" "mkdir fallback: the reclaiming driver actually runs its session"

# --- SIGTERM to the driver must not leave the session running ---
# Pre-fix neither driver had a trap (`grep -c trap` = 0 in both) and GNU
# `timeout` puts itself in its own process group, so `systemctl stop` on a host
# whose unit does not cgroup-kill, a cron `kill <pid>`, or a hand-typed Ctrl-C
# killed the driver and left a `bypassPermissions` claude running to its own
# budget with nobody watching it. Reproduced exactly this way: driver dead,
# stub alive.
#
# The stub records its pid and then BECOMES `sleep` via exec, so the recorded
# pid is the process a terminating driver actually has to reach — not a bash
# wrapper that could die while its child survives, which is the failure mode.
TERM_STUB="$SD/stub-sleeper"
cat > "$TERM_STUB" <<'EOF'
#!/usr/bin/env bash
echo $$ > "$STUB_PIDFILE"
exec sleep 30
EOF
chmod +x "$TERM_STUB"
rm -f "$SD/termpid"
STUB_PIDFILE="$SD/termpid" LOOP_ENG_CLAUDE_BIN="$TERM_STUB" \
  bash "$SCRIPT" "$SB" src/ >/dev/null 2>&1 &
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
    assert_eq "session terminated" "session orphaned" "TERM to the driver terminates the claude session"
  else
    assert_eq 0 0 "TERM to the driver terminates the claude session"
  fi
  assert_file_contains "$SB/.loop/unattended.log" "interrupted by signal" "the interruption is recorded in the rolling log"
else
  kill -TERM "$TERM_DRV" 2>/dev/null || true
  wait "$TERM_DRV" 2>/dev/null || true
  FAIL=$((FAIL+1)); echo "  FAIL: the sleeping stub never recorded a pid — the SIGTERM arm did not run" >&2
fi

# --- wall-clock budget: WHICH binary wraps the session, and what a host with
# neither is told. `timeout` is GNU coreutils; on macOS-with-Homebrew-coreutils
# it is installed as `gtimeout`, which this driver alone among its three
# budget-wrapping siblings did not probe — so a scheduled polish on that host
# ran UNBOUNDED while autoloop did not, and nothing on any stream said so.
#
# Both "absent" arms need a PATH holding no timeout of either name, which the
# real PATH cannot provide, so build a minimal bin dir with symlinks to exactly
# what the driver and the stub exec BY NAME. A missing entry here would look like
# a driver bug, so each one is asserted rather than assumed. The one prerequisite
# no symlink can cover is /usr/bin/env, which the stub's and the fake wrapper's
# shebangs reach by absolute path — outside PATH, so outside this list.
TD=$(mktemp -d "${TMPDIR:-/tmp}/loop-eng-polishto.XXXXXX")
SBF=$(mk_sandbox_repo)
# One trap naming every sandbox this suite creates. Growing the list beside each
# new sandbox is how the autoloop suite ended up dropping names from its own
# final trap — only the last trap installed runs.
trap 'rm -rf "$SB" "$SBF" "$SD" "$TD"' EXIT
mkdir -p "$TD/bin"
for b in bash git grep mkdir rm find wc tail cat date tee; do
  bp=$(command -v "$b" 2>/dev/null) || bp=""
  if [ -n "$bp" ]; then ln -sf "$bp" "$TD/bin/$b"; else
    FAIL=$((FAIL+1)); echo "  FAIL: test prerequisite '$b' is not on PATH" >&2; fi
done

# A fake timeout/gtimeout records the name it was called by, then execs the
# wrapped command — the wiring is verified without waiting out a real budget.
mk_fake_timeout() { # $1: binary name to install
  cat > "$TD/bin/$1" <<'FAKE'
#!/usr/bin/env bash
echo "$0 $*" >> "$TIMEOUT_RECORD"
shift 3   # -k 30 <N>m
exec "$@"
FAKE
  chmod +x "$TD/bin/$1"
}
run_restricted() { # $1: stderr file -> exit status of the driver
  STUB_MODE=ok LOOP_ENG_CLAUDE_BIN="$STUB" TIMEOUT_RECORD="$TD/record" PATH="$TD/bin" \
    bash "$SCRIPT" "$SB" src/ >/dev/null 2>"$1" && return 0 || return $?
}

# both present -> GNU `timeout` wins (probe order), and the harness is sound
mk_fake_timeout timeout; mk_fake_timeout gtimeout
: > "$TD/record"
run_restricted "$TD/err-both" && rc=0 || rc=$?
assert_eq 0 "$rc" "restricted-PATH run completes (the minimal bin dir is sufficient)"
# `-k 30` is part of the shape, not decoration: plain `timeout` sends TERM and
# then waits forever if the child ignores it, so a wedged session with a TERM
# handler made the budget advisory. Its autoloop sibling always had the -k.
assert_file_contains "$TD/record" "/timeout -k 30 120m" "with both installed, GNU timeout wraps the session with a kill-after"
# ONE wrapper, not two: the assertion above is a substring test on an append-only
# record, so a driver that wrapped the session twice would satisfy it unnoticed.
assert_eq 1 "$(wc -l < "$TD/record" | tr -d ' ')" "exactly one wrapper ran (gtimeout did not also fire)"

# gtimeout only (the macOS-with-coreutils shape) -> budget still enforced
rm -f "$TD/bin/timeout"; : > "$TD/record"
run_restricted "$TD/err-gt" && rc=0 || rc=$?
assert_eq 0 "$rc" "gtimeout-only run completes"
assert_file_contains "$TD/record" "/gtimeout -k 30 120m" "no timeout(1): the session falls back to gtimeout, kill-after included"

# neither -> degrade (run unwrapped) but SAY so; silence is what hid this
rm -f "$TD/bin/gtimeout"; : > "$TD/record"
run_restricted "$TD/err-none" && rc=0 || rc=$?
assert_eq 0 "$rc" "no timeout of either name: the run still happens (degrade, not refuse)"
assert_file_contains "$TD/err-none" "UNBOUNDED" "a dropped wall-clock budget is announced on stderr"
# ...and lands in the rolling log, because this script's own cron example ends
# `>/dev/null 2>&1`: a stderr-only warning is discarded by the very invocation it
# is written for, leaving a plain `exit=0` behind for an uncapped run.
assert_file_contains "$SB/.loop/unattended.log" "UNBOUNDED" "the warning survives a cron line that discards stderr"
assert_eq 0 "$(wc -c < "$TD/record" | tr -d ' ')" "nothing wrapped the session when neither binary exists"

# --- P2-8: --auto-fix had no post-run truth check ---
# Whatever the session did — converged, stopped on a regression, or ran out of
# --max-turns halfway through applying a fix — the driver's exit was `claude
# -p`'s, which is 0 in all three cases. An operator watching exit codes could
# not tell a completed nightly fix run from one that abandoned the tree
# mid-edit, and the abandoned one poisons every later run (dirty tree, refusing).
mkdir -p "$SBF/src"; printf '#!/usr/bin/env bash\ntrue\n' > "$SBF/src/a.sh"
(cd "$SBF" && git add -A >/dev/null && git commit -qm "src")
STUB_MODE=dirty LOOP_ENG_ALLOW_AUTOFIX=1 LOOP_ENG_CLAUDE_BIN="$STUB" \
  bash "$SCRIPT" "$SBF" src/ --auto-fix >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 70 "$rc" "an auto-fix run that leaves the tree dirty exits 70, not 0"
assert_file_contains "$SBF/.loop/unattended.log" "uncommitted changes" "the log says what the exit code means"
# The tree is deliberately left as the session left it — deleting a half-applied
# fix behind the operator's back would destroy the only evidence of what
# happened. Clean it here so the assertions below start from a committed tree.
(cd "$SBF" && git checkout -- . >/dev/null 2>&1; git clean -qfd >/dev/null 2>&1)

# A clean auto-fix run is still a plain exit 0 — the check must not turn every
# write-mode run red.
STUB_MODE=ok LOOP_ENG_ALLOW_AUTOFIX=1 LOOP_ENG_CLAUDE_BIN="$STUB" \
  bash "$SCRIPT" "$SBF" src/ --auto-fix >/dev/null 2>&1
assert_eq 0 $? "an auto-fix run that leaves the tree clean still exits 0"

# report-only never gets the check: it is not supposed to write, and the exit
# code it passes through is `claude -p`'s by design.
STUB_MODE=dirty LOOP_ENG_CLAUDE_BIN="$STUB" bash "$SCRIPT" "$SBF" src/ >/dev/null 2>&1
assert_eq 0 $? "report-only passes the session's own exit through, unchecked"
(cd "$SBF" && git checkout -- . >/dev/null 2>&1; git clean -qfd >/dev/null 2>&1)

# LOOP_ENG_POST_CHECK is the other half: the driver cannot know a project's test
# command, so the operator names one and a red one makes the run red.
STUB_MODE=ok LOOP_ENG_ALLOW_AUTOFIX=1 LOOP_ENG_CLAUDE_BIN="$STUB" \
  LOOP_ENG_POST_CHECK='exit 4' bash "$SCRIPT" "$SBF" src/ --auto-fix >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 70 "$rc" "a failing LOOP_ENG_POST_CHECK turns a clean-looking auto-fix run red"
assert_file_contains "$SBF/.loop/unattended.log" "post-check" "the log names the post-check as the cause"
STUB_MODE=ok LOOP_ENG_ALLOW_AUTOFIX=1 LOOP_ENG_CLAUDE_BIN="$STUB" \
  LOOP_ENG_POST_CHECK='true' bash "$SCRIPT" "$SBF" src/ --auto-fix >/dev/null 2>&1
assert_eq 0 $? "a passing LOOP_ENG_POST_CHECK leaves the run green"
# ...and it is auto-fix-scoped too: a report-only run changes nothing, so there
# is nothing for a project check to vet.
STUB_MODE=ok LOOP_ENG_CLAUDE_BIN="$STUB" LOOP_ENG_POST_CHECK='exit 4' \
  bash "$SCRIPT" "$SBF" src/ >/dev/null 2>&1
assert_eq 0 $? "LOOP_ENG_POST_CHECK does not run in report-only mode"

# --- the dirty-tree guards vs. a WIDE tree: both of them failed OPEN ---
# `git status --porcelain | grep -vq '^?? \.loop/'` under `set -euo pipefail`.
# `grep -vq` selects the FIRST porcelain line and exits on the spot; git, still
# writing, takes a SIGPIPE and dies 141; pipefail hands the pipeline that 141,
# so the `if` is FALSE and the guard reports the tree CLEAN. PIPESTATUS at the
# moment of failure is `git=141 grep=0` — the producer's death, read as an
# answer. The guard fails open exactly when the tree is at its dirtiest.
#
# Every dirty fixture in this suite is ONE file (~40 bytes of porcelain): git
# finishes writing before grep leaves, so the guard works and the bug is
# invisible — three orders of magnitude below the break point. Measured on the
# pre-fix driver in a 4000-file tree (~72000 bytes): claude invoked with
# --permission-mode bypassPermissions, exit 0, no refusal line, 3/3 runs.
# The small fixtures above stay as they are; they pin the other end.
SBW=$(mk_wide_sandbox_repo)
SBX=$(mk_sandbox_repo)
trap 'rm -rf "$SB" "$SBF" "$SD" "$TD" "$SBW" "$SBX"' EXIT

# Site 1: the pre-run guard. Refuse, and refuse BEFORE the session starts —
# an exit code alone would not distinguish "refused" from "ran, then failed".
dirty_wide_tree "$SBW"
rm -f "$SD/argv-wide"
STUB_MODE=ok LOOP_ENG_CLAUDE_BIN="$STUB" STUB_ARGV_LOG="$SD/argv-wide" \
  bash "$SCRIPT" "$SBW" src/ >/dev/null 2>"$SD/wide-err" && rc=0 || rc=$?
assert_eq 1 "$rc" "a wide dirty tree is refused (the pre-run guard must not fail open at scale)"
assert_file_contains "$SD/wide-err" "dirty tree, refusing" "the wide-tree refusal names its reason"
if [ -e "$SD/argv-wide" ]; then
  assert_eq "no session" "session launched" "a refused wide dirty tree never invokes claude"
else
  assert_eq 0 0 "a refused wide dirty tree never invokes claude"
fi
(cd "$SBW" && git checkout -- . >/dev/null 2>&1)

# Site 2: the post-run truth check, same pipeline, same blind spot. A session
# that abandons 4000 modified files must come back UNTRUSTWORTHY (70), not 0.
STUB_MODE=dirty-wide LOOP_ENG_ALLOW_AUTOFIX=1 LOOP_ENG_CLAUDE_BIN="$STUB" \
  bash "$SCRIPT" "$SBW" src/ --auto-fix >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 70 "$rc" "an auto-fix session that abandons a WIDE tree exits 70, not 0"
assert_file_contains "$SBW/.loop/unattended.log" "uncommitted changes" "the wide-tree post-run refusal says what the exit code means"
(cd "$SBW" && git checkout -- . >/dev/null 2>&1; git clean -qfd >/dev/null 2>&1)

# ...and the clean end of the same guard, at the same scale: a wide tree with
# nothing modified still runs. A guard fixed by refusing everything would pass
# the two assertions above and fail here.
rm -f "$SD/argv-wide-clean"
STUB_MODE=ok LOOP_ENG_CLAUDE_BIN="$STUB" STUB_ARGV_LOG="$SD/argv-wide-clean" \
  bash "$SCRIPT" "$SBW" src/ >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 0 "$rc" "a wide but CLEAN tree still runs"
assert_file_contains "$SD/argv-wide-clean" "/polish src/" "the clean wide-tree run still starts a session"

# The `-v` in the pattern is the whole point of it: untracked .loop/
# bookkeeping is NOT dirt, and that exemption has to survive the fix — at
# scale too, where it is 4000 porcelain lines the guard must read past rather
# than one it may stop at. This fixture makes .loop/ VISIBLE to git (the
# standard sandbox gitignores it, so its exemption lines never appear at all):
# .gitignore drops the .loop/ rule and a tracked .loop/keep.md forces git to
# list the untracked siblings individually instead of collapsing the directory.
printf '*.log\n' > "$SBX/.gitignore"
mkdir -p "$SBX/.loop"
printf 'tracked so the untracked siblings are listed one per line\n' > "$SBX/.loop/keep.md"
(cd "$SBX" && git add -A >/dev/null && git commit -qm "visible .loop" >/dev/null)
i=0; while [ "$i" -lt 4000 ]; do printf 'bookkeeping\n' > "$SBX/.loop/note-$i.txt"; i=$((i+1)); done
rm -f "$SD/argv-loop-only"
STUB_MODE=ok LOOP_ENG_CLAUDE_BIN="$STUB" STUB_ARGV_LOG="$SD/argv-loop-only" \
  bash "$SCRIPT" "$SBX" src/ >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 0 "$rc" "a tree dirty only with untracked .loop/ bookkeeping still runs (4000 exempt lines)"
assert_file_contains "$SD/argv-loop-only" "/polish src/" "the .loop/-only run still starts a session"
# ...and one genuinely dirty file among those 4000 exempt lines still refuses,
# so the exemption is a filter and not a blanket.
printf 'real work\n' > "$SBX/README.md"
STUB_MODE=ok LOOP_ENG_CLAUDE_BIN="$STUB" \
  bash "$SCRIPT" "$SBX" src/ >/dev/null 2>"$SD/loop-plus-err" && rc=0 || rc=$?
assert_eq 1 "$rc" "one real modification hiding among 4000 exempt .loop/ lines is still dirt"
assert_file_contains "$SD/loop-plus-err" "dirty tree, refusing" "the mixed-tree refusal names its reason"

report "test-unattended-polish"
