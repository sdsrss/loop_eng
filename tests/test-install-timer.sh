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

# The installer requires the mode's runner to exist + be executable in the repo.
mkdir -p "$SB/skills/loop-eng/scripts"
for m in polish autoloop; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$SB/skills/loop-eng/scripts/unattended-$m.sh"
  chmod +x "$SB/skills/loop-eng/scripts/unattended-$m.sh"
done

UNIT_DIR="$XDG/systemd/user"
run_install()   { XDG_CONFIG_HOME="$XDG" LOOP_ENG_TIMER_NO_SYSTEMCTL=1 bash "$INSTALL" "$@"; }
run_uninstall() { XDG_CONFIG_HOME="$XDG" LOOP_ENG_TIMER_NO_SYSTEMCTL=1 bash "$UNINSTALL" "$@"; }
exists() { [ -e "$1" ] && echo yes || echo no; }

# --- polish install: files written, report-only (no --auto-fix), default time ---
run_install polish "$SB" >/dev/null; rc=$?
assert_eq 0 "$rc" "polish install exits 0"
assert_eq yes "$(exists "$UNIT_DIR/loop-eng-polish.service")" "polish .service written"
assert_eq yes "$(exists "$UNIT_DIR/loop-eng-polish.timer")" "polish .timer written"
assert_file_contains "$UNIT_DIR/loop-eng-polish.service" "ExecStart=$SB/skills/loop-eng/scripts/unattended-polish.sh $SB src/" "ExecStart has abs runner + repo + default scope"
assert_file_contains "$UNIT_DIR/loop-eng-polish.timer" "OnCalendar=*-*-* 03:00:00" "default OnCalendar 03:00"
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

# --- nonexistent repo-dir: refused AND the error names the offending path (not blank) ---
err=$(run_install polish /no/such/repo-dir-xyz 2>&1 >/dev/null); rc=$?
assert_eq 0 "$(( rc != 0 ? 0 : 1 ))" "nonexistent repo-dir refused"
case "$err" in
  *"/no/such/repo-dir-xyz"*) assert_eq 1 1 "error names the offending repo-dir path" ;;
  *) assert_eq "path-named" "path-blank" "error must include the offending repo-dir path" ;;
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
