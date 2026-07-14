#!/usr/bin/env bash
# install-timer / uninstall-timer: unit-file generation + install/uninstall
# symmetry. Never touches real systemd — LOOP_ENG_TIMER_NO_SYSTEMCTL=1 skips
# every systemctl call and a throwaway XDG_CONFIG_HOME redirects the unit dir.
set -u
. "$(dirname "$0")/lib.sh"

INSTALL="$PLUGIN_ROOT/skills/loop-eng/scripts/install-timer.sh"
UNINSTALL="$PLUGIN_ROOT/skills/loop-eng/scripts/uninstall-timer.sh"

SB=$(mk_sandbox_repo)
XDG=$(mktemp -d "${TMPDIR:-/tmp}/loop-eng-xdg.XXXXXX")
trap 'rm -rf "$SB" "$XDG"' EXIT

# As of v0.4.1 the installer resolves the unattended runner from ITS OWN
# directory (the plugin), not from the target repo — so no runner is staged in
# $SB; the real plugin runners under $PLUGIN_ROOT are what ExecStart points at.
RUNNER_DIR="$PLUGIN_ROOT/skills/loop-eng/scripts"

UNIT_DIR="$XDG/systemd/user"
# Hermetic claude: the installer resolves the claude CLI at install time (and
# dies if it can't) — point it at a stub so the tests don't depend on a real
# claude being on PATH (CI runners don't have one).
FAKE_CLAUDE="$XDG/fake-claude"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_CLAUDE" && chmod +x "$FAKE_CLAUDE"
run_install()   { XDG_CONFIG_HOME="$XDG" LOOP_ENG_TIMER_NO_SYSTEMCTL=1 LOOP_ENG_CLAUDE_BIN="$FAKE_CLAUDE" bash "$INSTALL" "$@"; }
run_uninstall() { XDG_CONFIG_HOME="$XDG" LOOP_ENG_TIMER_NO_SYSTEMCTL=1 bash "$UNINSTALL" "$@"; }
exists() { [ -e "$1" ] && echo yes || echo no; }

# --- polish install: files written, report-only (no --auto-fix), default time ---
run_install polish "$SB" >/dev/null; rc=$?
assert_eq 0 "$rc" "polish install exits 0"
assert_eq yes "$(exists "$UNIT_DIR/loop-eng-polish.service")" "polish .service written"
assert_eq yes "$(exists "$UNIT_DIR/loop-eng-polish.timer")" "polish .timer written"
assert_file_contains "$UNIT_DIR/loop-eng-polish.service" "ExecStart=$RUNNER_DIR/unattended-polish.sh $SB src/" "ExecStart has plugin runner + repo + default scope"
assert_eq yes "$(exists "$SB/.loop")" "install pre-creates repo .loop for unit logging"
assert_file_contains "$UNIT_DIR/loop-eng-polish.timer" "OnCalendar=*-*-* 03:00:00" "default OnCalendar 03:00"
assert_file_contains "$UNIT_DIR/loop-eng-polish.service" "Environment=LOOP_ENG_CLAUDE_BIN=$FAKE_CLAUDE" "unit pins the install-time-resolved claude path"
if grep -q "Persistent=true" "$UNIT_DIR/loop-eng-polish.timer"; then
  assert_eq no-persistent has-persistent "timer must NOT be Persistent (avoids catch-up run on mid-day install)"
else assert_eq 1 1 "timer omits Persistent=true (no catch-up run on install)"; fi
if grep -q -- "--auto-fix" "$UNIT_DIR/loop-eng-polish.service"; then
  assert_eq report-only auto-fix "report-only install must NOT contain --auto-fix"
else assert_eq 1 1 "report-only install omits --auto-fix"; fi

# --- custom time ---
run_install polish "$SB" --time 04:30 >/dev/null
assert_file_contains "$UNIT_DIR/loop-eng-polish.timer" "OnCalendar=*-*-* 04:30:00" "custom --time 04:30 honored"

# --- polish --allow-write: --auto-fix + autofix env injected ---
run_install polish "$SB" lib/ --allow-write >/dev/null
assert_file_contains "$UNIT_DIR/loop-eng-polish.service" "unattended-polish.sh $SB lib/ --auto-fix" "allow-write appends --auto-fix + custom scope"
assert_file_contains "$UNIT_DIR/loop-eng-polish.service" "LOOP_ENG_ALLOW_AUTOFIX=1" "allow-write injects autofix env"

# --- autoloop --allow-write: max-sessions + autobuild env ---
run_install autoloop "$SB" 5 --allow-write >/dev/null
assert_file_contains "$UNIT_DIR/loop-eng-autoloop.service" "unattended-autoloop.sh $SB 5" "autoloop ExecStart has max-sessions"
assert_file_contains "$UNIT_DIR/loop-eng-autoloop.service" "LOOP_ENG_ALLOW_AUTOBUILD=1" "autoloop allow-write injects autobuild env"

# --- validation: bad mode / bad time / non-git repo / bad max-sessions all refuse ---
run_install bogus "$SB" 2>/dev/null && rc=0 || rc=$?; assert_eq 0 "$(( rc != 0 ? 0 : 1 ))" "bad mode refused"
run_install polish "$SB" --time 25:00 2>/dev/null && rc=0 || rc=$?; assert_eq 0 "$(( rc != 0 ? 0 : 1 ))" "bad --time refused"
run_install polish "$XDG" 2>/dev/null && rc=0 || rc=$?; assert_eq 0 "$(( rc != 0 ? 0 : 1 ))" "non-git repo refused"
run_install autoloop "$SB" abc 2>/dev/null && rc=0 || rc=$?; assert_eq 0 "$(( rc != 0 ? 0 : 1 ))" "non-numeric max-sessions refused"

# --- repo path containing whitespace: refused (systemd ExecStart is unquoted) ---
SPACE_REPO="$XDG/has space repo"
mkdir -p "$SPACE_REPO" && ( cd "$SPACE_REPO" && git init -q )
err=$(run_install polish "$SPACE_REPO" 2>&1 >/dev/null); rc=$?
assert_eq 0 "$(( rc != 0 ? 0 : 1 ))" "repo path with whitespace refused"
case "$err" in
  *whitespace*) assert_eq 1 1 "whitespace refusal names the reason" ;;
  *) assert_eq "whitespace-named" "other-error" "refusal must cite whitespace" ;;
esac

# --- polish scope containing whitespace: refused like every other ExecStart value ---
# (pre-fix, SCOPE was the one unquoted ExecStart value without the guard: a scope
# like "legacy code/" wrote a unit that split into scope="legacy" plus a stray
# third argument the runner mistakes for its flag — silently report-only with the
# wrong scope, surfacing only at first trigger)
err=$(run_install polish "$SB" "legacy code/" 2>&1 >/dev/null); rc=$?
assert_eq 0 "$(( rc != 0 ? 0 : 1 ))" "scope with whitespace refused"
case "$err" in
  *whitespace*) assert_eq 1 1 "scope refusal names the reason" ;;
  *) assert_eq "whitespace-named" "other-error" "scope refusal must cite whitespace" ;;
esac

# --- value containing %: refused (systemd expands a literal % as a unit specifier) ---
# (pre-fix, a % in any ExecStart=/Environment= value — e.g. a URL-encoded scope
# like "src%2Ffoo/" — misexpanded via specifier substitution or failed unit load,
# the same "enables cleanly, breaks at first trigger" class as whitespace)
err=$(run_install polish "$SB" "src%2Ffoo/" 2>&1 >/dev/null); rc=$?
assert_eq 0 "$(( rc != 0 ? 0 : 1 ))" "scope with percent refused"
case "$err" in
  *percent*) assert_eq 1 1 "percent refusal names the reason" ;;
  *) assert_eq "percent-named" "other-error" "refusal must cite percent" ;;
esac

# --- nonexistent repo-dir: refused AND the error names the offending path (not blank) ---
err=$(run_install polish /no/such/repo-dir-xyz 2>&1 >/dev/null); rc=$?
assert_eq 0 "$(( rc != 0 ? 0 : 1 ))" "nonexistent repo-dir refused"
case "$err" in
  *"/no/such/repo-dir-xyz"*) assert_eq 1 1 "error names the offending repo-dir path" ;;
  *) assert_eq "path-named" "path-blank" "error must include the offending repo-dir path" ;;
esac

# --- unresolvable claude: refused at INSTALL time, error names what was looked for ---
# (pre-fix, the unit's hardcoded PATH could miss claude entirely and the runner
# failed with exit 127 at first trigger, error only in cron.log)
err=$(XDG_CONFIG_HOME="$XDG" LOOP_ENG_TIMER_NO_SYSTEMCTL=1 LOOP_ENG_CLAUDE_BIN=/no/such/claude-bin \
  bash "$INSTALL" polish "$SB" 2>&1 >/dev/null); rc=$?
assert_eq 0 "$(( rc != 0 ? 0 : 1 ))" "unresolvable claude refused at install time"
case "$err" in
  *"/no/such/claude-bin"*) assert_eq 1 1 "claude refusal names the binary looked for" ;;
  *) assert_eq "claude-named" "other-error" "refusal must name the claude binary" ;;
esac

# --- uninstall symmetry: install then uninstall leaves NO residue ---
run_install polish "$SB" >/dev/null
run_uninstall polish >/dev/null; rc=$?
assert_eq 0 "$rc" "uninstall exits 0"
assert_eq no "$(exists "$UNIT_DIR/loop-eng-polish.service")" "uninstall removed .service"
assert_eq no "$(exists "$UNIT_DIR/loop-eng-polish.timer")" "uninstall removed .timer"

# autoloop unit is independent — still present after polish uninstall
assert_eq yes "$(exists "$UNIT_DIR/loop-eng-autoloop.service")" "polish uninstall left autoloop untouched"

# --- uninstall when nothing installed is a benign no-op (exit 0) ---
run_uninstall polish >/dev/null; rc=$?
assert_eq 0 "$rc" "uninstall of absent unit is benign no-op"

# --- uninstall symmetry, autoloop mode: both unit files gone, polish untouched ---
# (mirror of the polish symmetry test above — pre-fix, uninstall was only ever
# exercised in polish mode, so an autoloop-specific regression would slip by)
run_install polish "$SB" >/dev/null
run_install autoloop "$SB" >/dev/null
run_uninstall autoloop >/dev/null; rc=$?
assert_eq 0 "$rc" "autoloop uninstall exits 0"
assert_eq no "$(exists "$UNIT_DIR/loop-eng-autoloop.service")" "autoloop uninstall removed .service"
assert_eq no "$(exists "$UNIT_DIR/loop-eng-autoloop.timer")" "autoloop uninstall removed .timer"
assert_eq yes "$(exists "$UNIT_DIR/loop-eng-polish.service")" "autoloop uninstall left polish .service untouched"
assert_eq yes "$(exists "$UNIT_DIR/loop-eng-polish.timer")" "autoloop uninstall left polish .timer untouched"

# --- bad-mode uninstall: refused with usage error, nothing removed ---
err=$(run_uninstall bogus 2>&1 >/dev/null); rc=$?
assert_eq 0 "$(( rc != 0 ? 0 : 1 ))" "bad-mode uninstall refused"
case "$err" in
  *usage*) assert_eq 1 1 "bad-mode uninstall refusal shows usage" ;;
  *) assert_eq "usage-named" "other-error" "bad-mode uninstall must show usage" ;;
esac
assert_eq yes "$(exists "$UNIT_DIR/loop-eng-polish.service")" "bad-mode uninstall removed nothing"

# --- orphan cleanup: uninstall removes the install-created .loop/cron.log ---
# install-timer pre-creates $SB/.loop so systemd can open cron.log before
# ExecStart; under NO_SYSTEMCTL systemd never runs, so we plant the cron.log the
# way a real trigger would. A repo that only ever had a timer (never ran a loop)
# has nothing else in .loop — uninstall must reap both the log and the now-empty
# dir. The cron.log path is parsed out of the .service unit file being removed.
run_install autoloop "$SB" >/dev/null
assert_eq yes "$(exists "$SB/.loop")" "install pre-created repo .loop"
: > "$SB/.loop/cron.log"
run_uninstall autoloop >/dev/null; rc=$?
assert_eq 0 "$rc" "orphan-cleanup uninstall exits 0"
assert_eq no "$(exists "$SB/.loop/cron.log")" "uninstall removed install-created cron.log orphan"
assert_eq no "$(exists "$SB/.loop")" "uninstall removed the now-empty .loop dir"

# --- preservation: cron.log-only cleanup must NOT fire when live loop state exists ---
# Plant real loop state (results.json) alongside cron.log. A live loop's state
# must survive a timer uninstall, so cleanup removes NOTHING here — not the dir,
# not the extra file, and (err on preservation) not even cron.log.
run_install autoloop "$SB" >/dev/null
: > "$SB/.loop/cron.log"
echo '{"passes":true}' > "$SB/.loop/results.json"
run_uninstall autoloop >/dev/null; rc=$?
assert_eq 0 "$rc" "preservation uninstall exits 0"
assert_eq yes "$(exists "$SB/.loop")" "uninstall preserved .loop dir holding live state"
assert_eq yes "$(exists "$SB/.loop/results.json")" "uninstall preserved live loop state (results.json)"
assert_eq yes "$(exists "$SB/.loop/cron.log")" "cron.log-only cleanup does not fire beside other loop state"

report "test-install-timer"
