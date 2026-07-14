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

report "test-install-timer"
