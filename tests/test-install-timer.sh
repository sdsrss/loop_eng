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

# The installer checks that a polish scope actually exists in the target repo,
# so the sandbox needs the source dirs a real polish target would have. (Before
# that check existed these tests passed src/ and lib/ into a repo containing
# neither — a fixture that quietly asserted the very gap being closed.)
mkdir -p "$SB/src" "$SB/lib"
printf '#!/usr/bin/env bash\ntrue\n' > "$SB/src/a.sh"

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

# --- autoloop WITHOUT --allow-write: refused at install time ---
# unattended-autoloop.sh has no report-only mode: it exits 1 unless
# LOOP_ENG_ALLOW_AUTOBUILD=1 is in the environment. A unit installed without
# --allow-write therefore fails on EVERY trigger for the life of the install —
# the same "enables cleanly, does nothing every night" family as the missing
# polish scope and the same-minute collision, and refused the same way.
#
# No --time on purpose. A polish timer already holds 03:00 on this repo, so this
# is also the collision shape — and the gate must still answer, because it is
# argv-only and the collision check is not. Run BEFORE the --allow-write case
# below so no autoloop unit exists yet and "wrote nothing" means what it says.
nw_err=$(run_install autoloop "$SB" 2>&1 >/dev/null); rc=$?
assert_eq 1 "$rc" "autoloop without --allow-write is refused"
assert_eq no "$(exists "$UNIT_DIR/loop-eng-autoloop.service")" "the refused autoloop install writes no .service"
assert_eq no "$(exists "$UNIT_DIR/loop-eng-autoloop.timer")" "the refused autoloop install writes no .timer"
case "$nw_err" in
  *--allow-write*) assert_eq 0 0 "the refusal names --allow-write as the fix" ;;
  *) assert_eq "a message naming --allow-write" "[$nw_err]" "the refusal names --allow-write as the fix" ;;
esac
case "$nw_err" in
  *report-only*) assert_eq 0 0 "the refusal says autoloop has no report-only mode" ;;
  *) assert_eq "a message naming report-only" "[$nw_err]" "the refusal says autoloop has no report-only mode" ;;
esac
# ...and it beat the collision check, which would otherwise have claimed this
# exact shape (polish holds 03:00 on $SB and no --time was passed). Asserted by
# the strings only the collision refusal carries.
case "$nw_err" in
  *uninstall-timer*) assert_eq "the write-mode refusal" "the collision refusal" "the argv-only gate answers before the collision check" ;;
  *) assert_eq 0 0 "the argv-only gate answers before the collision check" ;;
esac

# --- and before the environment probes: a box with no claude hears the gate ---
# The gate needs nothing but argv, so it must not sit behind the claude probe —
# which resolves AND executes the binary. When it did, this shape answered
# "claude CLI not found", sending the user to install a CLI the request never
# needed, only to learn on the retry that it was never installable.
np_err=$(XDG_CONFIG_HOME="$XDG" LOOP_ENG_TIMER_NO_SYSTEMCTL=1 \
  LOOP_ENG_CLAUDE_BIN="$XDG/no-such-claude" bash "$INSTALL" autoloop "$SB" 2>&1 >/dev/null); rc=$?
assert_eq 1 "$rc" "autoloop without --allow-write is refused even with no claude installed"
case "$np_err" in
  *"claude CLI not found"*) assert_eq "the write-mode refusal" "claude CLI not found" "the gate answers before the claude probe, so no CLI is demanded for an uninstallable request" ;;
  *--allow-write*) assert_eq 0 0 "the gate answers before the claude probe, so no CLI is demanded for an uninstallable request" ;;
  *) assert_eq "a message naming --allow-write" "[$np_err]" "the gate answers before the claude probe, so no CLI is demanded for an uninstallable request" ;;
esac

# ...and it leaves no DIRECTORY behind either. "$UNIT_DIR" is only named before
# the refusals; the mkdir waits until past the last one. This needs its own
# config home because every case above has already created the shared one, so
# the residue would be invisible there — which is exactly how the first version
# of this change shipped an empty ~/.config/systemd/user onto a box that had
# never had one.
FRESH_XDG=$(mktemp -d "${TMPDIR:-/tmp}/loop-eng-xdg-fresh.XXXXXX")
trap 'rm -rf "$SB" "$XDG" "$FRESH_XDG"' EXIT
XDG_CONFIG_HOME="$FRESH_XDG" LOOP_ENG_TIMER_NO_SYSTEMCTL=1 LOOP_ENG_CLAUDE_BIN="$FAKE_CLAUDE" \
  bash "$INSTALL" autoloop "$SB" >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 1 "$rc" "refused autoloop install exits 1 on a never-used config home too"
assert_eq no "$(exists "$FRESH_XDG/systemd")" "the refused install creates no systemd config dir"

# --- autoloop --allow-write: max-sessions + autobuild env ---
# --time 04:00: a polish timer already holds 03:00 on this repo, and two modes
# on one repo at the same minute are refused (see the collision block at the
# end of this file). This case is about the autoloop unit's own contents.
run_install autoloop "$SB" 5 --allow-write --time 04:00 >/dev/null
assert_file_contains "$UNIT_DIR/loop-eng-autoloop.service" "unattended-autoloop.sh $SB 5" "autoloop ExecStart has max-sessions"
assert_file_contains "$UNIT_DIR/loop-eng-autoloop.service" "LOOP_ENG_ALLOW_AUTOBUILD=1" "autoloop allow-write injects autobuild env"
# The ONLY autoloop unit that can now exist is a writing one, so its
# Description must say so. Nothing asserted on Description= before this, which
# is how "report-only: refuses to build" survived in the source describing a
# mode the driver has never had.
assert_file_contains "$UNIT_DIR/loop-eng-autoloop.service" "Description=loop-eng autoloop driver (dogfood, WRITES code unattended)" "the only installable autoloop unit describes itself as writing"

# --- validation: bad mode / bad time / non-git repo / bad max-sessions all refuse ---
# Captured rather than discarded: this is the only message a user who typos the
# mode ever sees, and it is now where the "--allow-write is REQUIRED for
# autoloop" fact lives. Nothing asserted a character of it before — the same
# "prose drifts away from the mechanism" shape the gate below exists to close,
# and uninstall-timer.sh's equivalent message has been pinned all along.
merr=$(run_install bogus "$SB" 2>&1 >/dev/null); rc=$?
assert_eq 0 "$(( rc != 0 ? 0 : 1 ))" "bad mode refused"
case "$merr" in
  *usage*) assert_eq 0 0 "bad-mode refusal shows usage" ;;
  *) assert_eq "a usage message" "[$merr]" "bad-mode refusal shows usage" ;;
esac
case "$merr" in
  *"REQUIRED for autoloop"*) assert_eq 0 0 "the usage synopsis says --allow-write is REQUIRED for autoloop" ;;
  *) assert_eq "a synopsis naming --allow-write as REQUIRED for autoloop" "[$merr]" "the usage synopsis says --allow-write is REQUIRED for autoloop" ;;
esac
run_install polish "$SB" --time 25:00 2>/dev/null && rc=0 || rc=$?; assert_eq 0 "$(( rc != 0 ? 0 : 1 ))" "bad --time refused"
# --time with its value omitted: `shift 2` on a single remaining arg fails, and
# under `set -e` that aborted the script BEFORE the HH:MM validation could speak
# — a bare exit 1 with nothing on stderr, indistinguishable from a crash.
terr=$(run_install polish "$SB" --time 2>&1 >/dev/null); rc=$?
assert_eq 0 "$(( rc != 0 ? 0 : 1 ))" "--time with no value refused"
case "$terr" in
  *--time*) assert_eq 0 0 "--time with no value says what is missing" ;;
  *) assert_eq "a message naming --time" "[$terr]" "--time with no value says what is missing" ;;
esac
run_install polish "$XDG" 2>/dev/null && rc=0 || rc=$?; assert_eq 0 "$(( rc != 0 ? 0 : 1 ))" "non-git repo refused"
# Deliberately WITHOUT --allow-write, and asserted by CAUSE: the max-sessions
# parse must answer before the write-mode gate, or this line silently stops
# testing max-sessions and starts testing the gate instead. Exit code alone
# cannot tell the two refusals apart — the message can.
nerr=$(run_install autoloop "$SB" abc 2>&1 >/dev/null); rc=$?
assert_eq 0 "$(( rc != 0 ? 0 : 1 ))" "non-numeric max-sessions refused"
case "$nerr" in
  *max-sessions*) assert_eq 0 0 "non-numeric max-sessions is refused for ITS OWN cause, not the write-mode gate" ;;
  *) assert_eq "a message naming max-sessions" "[$nerr]" "non-numeric max-sessions is refused for ITS OWN cause, not the write-mode gate" ;;
esac

# --- argv beats the machine, in both directions, pinned by cause ---
# The rule the argv-only block encodes: a fault the command line already shows
# is reported before anything that inspects the machine. Nothing pinned the
# precedence, so a future reshuffle could flip it back silently — which is how
# the claude probe came to answer for a request argv had already invalidated.
# Both shapes below are refused either way; only the MESSAGE distinguishes which
# rule won.
aerr=$(run_install autoloop "$XDG/no-such-dir" abc 2>&1 >/dev/null); rc=$?
assert_eq 0 "$(( rc != 0 ? 0 : 1 ))" "bad max-sessions on a nonexistent repo is refused"
case "$aerr" in
  *max-sessions*) assert_eq 0 0 "argv wins: bad max-sessions answers before the repo is looked for" ;;
  *) assert_eq "a message naming max-sessions" "[$aerr]" "argv wins: bad max-sessions answers before the repo is looked for" ;;
esac
gerr=$(run_install autoloop "$XDG/no-such-dir" 2>&1 >/dev/null); rc=$?
assert_eq 0 "$(( rc != 0 ? 0 : 1 ))" "no-write autoloop on a nonexistent repo is refused"
case "$gerr" in
  *--allow-write*) assert_eq 0 0 "argv wins: the write-mode gate answers before the repo is looked for" ;;
  *) assert_eq "a message naming --allow-write" "[$gerr]" "argv wins: the write-mode gate answers before the repo is looked for" ;;
esac

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

# --- scope that does not exist in the repo: refused at INSTALL time ---
# Same "enables cleanly, breaks at first trigger" family as the two guards above,
# and the one this installer was least able to see: the unit loads, `systemctl
# enable` succeeds, and every nightly run reviews a path that isn't there — finds
# nothing, exits 0, forever. unattended-polish.sh's own header records this having
# happened (a flag mistaken for the scope); it now rejects THAT shape, but a plain
# typo'd or moved-away directory still sailed through.
err=$(run_install polish "$SB" nosuchdir/ 2>&1 >/dev/null); rc=$?
assert_eq 0 "$(( rc != 0 ? 0 : 1 ))" "scope missing from the repo refused"
case "$err" in
  *nosuchdir/*) assert_eq 1 1 "missing-scope refusal names the offending scope" ;;
  *) assert_eq "scope-named" "other-error" "missing-scope refusal must cite the scope" ;;
esac
# zero false positives on the scope shapes that ARE legitimate: an existing dir
# (asserted throughout above), and a glob, which /polish takes as scope paths and
# which never matches `test -e` literally
run_install polish "$SB" 'src/*.sh' >/dev/null 2>&1
assert_eq 0 $? "a glob scope that matches real files is accepted"
run_install polish "$SB" src/a.sh >/dev/null 2>&1
assert_eq 0 $? "a single-file scope is accepted"

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
# --time 04:00 because two modes on one repo at the SAME minute is now refused
# (the losing driver would exit 69 and do nothing, silently, every night). This
# test is about uninstall symmetry between two coexisting timers, and staggered
# times are how a real user makes them coexist.
run_install autoloop "$SB" --allow-write --time 04:00 >/dev/null
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
run_install autoloop "$SB" --allow-write --time 04:00 >/dev/null   # polish still holds 03:00 on this repo
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
run_install autoloop "$SB" --allow-write --time 04:00 >/dev/null   # polish still holds 03:00 on this repo
: > "$SB/.loop/cron.log"
echo '{"passes":true}' > "$SB/.loop/results.json"
run_uninstall autoloop >/dev/null; rc=$?
assert_eq 0 "$rc" "preservation uninstall exits 0"
assert_eq yes "$(exists "$SB/.loop")" "uninstall preserved .loop dir holding live state"
assert_eq yes "$(exists "$SB/.loop/results.json")" "uninstall preserved live loop state (results.json)"
assert_eq yes "$(exists "$SB/.loop/cron.log")" "cron.log-only cleanup does not fire beside other loop state"

# --- same repo, same minute, both modes: refused at install time ---
# Both modes default to --time 03:00 and both unit names are per-USER, not
# per-repo, so installing a polish timer and then an autoloop timer on one repo
# — the documented way to use this script twice — scheduled two drivers against
# one working tree at the same instant. The drivers now refuse to overlap (the
# loser exits 69), which makes the tree safe and the collision SILENT: the
# losing timer does no work, every night, while systemctl status stays green.
run_uninstall polish >/dev/null 2>&1 || true
run_uninstall autoloop >/dev/null 2>&1 || true
run_install polish "$SB" src/ >/dev/null
# --allow-write is required to REACH this check: the argv-only gate now answers
# first, so a colliding autoloop install must be otherwise valid before it is
# told about the collision. Without the flag this case would assert the gate's
# message instead of the collision's.
run_install autoloop "$SB" --allow-write >/dev/null 2>"$XDG/collide.err" && rc=0 || rc=$?
assert_eq 1 "$rc" "second mode on the same repo at the same time is refused"
assert_file_contains "$XDG/collide.err" "--time" "the refusal names --time as the fix"
assert_file_contains "$XDG/collide.err" "uninstall-timer.sh polish" "the refusal names the other timer and how to remove it"
assert_eq no "$(exists "$UNIT_DIR/loop-eng-autoloop.service")" "the refused install writes no unit file"

# ...and the two legitimate shapes are NOT refused.
run_install autoloop "$SB" --allow-write --time 04:00 >/dev/null && rc=0 || rc=$?
assert_eq 0 "$rc" "same repo at a DIFFERENT time is allowed (this is how you run both)"
assert_file_contains "$UNIT_DIR/loop-eng-autoloop.timer" "OnCalendar=*-*-* 04:00:00" "the allowed install wrote its own time"
run_uninstall autoloop >/dev/null
SB2=$(mk_sandbox_repo); trap 'rm -rf "$SB" "$SB2" "$XDG" "$FRESH_XDG"' EXIT
run_install autoloop "$SB2" --allow-write >/dev/null && rc=0 || rc=$?
assert_eq 0 "$rc" "a DIFFERENT repo at the same time is allowed (different tree, different lock)"
# re-installing the SAME mode is an overwrite, not a collision
run_install autoloop "$SB2" --allow-write >/dev/null && rc=0 || rc=$?
assert_eq 0 "$rc" "re-installing the same mode on the same repo is an overwrite, not a collision"
run_uninstall autoloop >/dev/null; run_uninstall polish >/dev/null

# --- P2-7: resolving the claude binary is not the same as proving it RUNS ---
# The unit hardcodes a minimal PATH, and the installer only checked that
# `command -v claude` found something. A claude installed by npm or nvm is an
# `#!/usr/bin/env node` shim: it resolves fine in the installing shell and exits
# 127 at 03:00, with the error only in cron.log — the exact "installed but
# silently never runs" trap every other guard in this script exists to kill.
# The stub below reproduces that shape faithfully: it needs a helper that lives
# on the AMBIENT path and not on the unit's.
NODEISH="$XDG/nodeish"; mkdir -p "$NODEISH"
printf '#!/bin/sh\nexit 0\n' > "$NODEISH/nodeish" && chmod +x "$NODEISH/nodeish"
SHIM_CLAUDE="$XDG/shim-claude"
printf '#!/bin/sh\ncommand -v nodeish >/dev/null 2>&1 || { echo "env: node: No such file or directory" >&2; exit 127; }\nexit 0\n' \
  > "$SHIM_CLAUDE" && chmod +x "$SHIM_CLAUDE"
err=$(PATH="$NODEISH:$PATH" XDG_CONFIG_HOME="$XDG" LOOP_ENG_TIMER_NO_SYSTEMCTL=1 \
  LOOP_ENG_CLAUDE_BIN="$SHIM_CLAUDE" bash "$INSTALL" polish "$SB" 2>&1 >/dev/null) && rc=0 || rc=$?
assert_eq 1 "$rc" "install refuses a claude that resolves but cannot RUN under the unit's PATH"
case "$err" in
  *"unit's PATH"*|*"unit PATH"*) PASS=$((PASS+1)) ;;
  *) FAIL=$((FAIL+1)); echo "  FAIL: the probe refusal does not name the unit PATH as the cause: $err" >&2 ;;
esac
assert_eq no "$(exists "$UNIT_DIR/loop-eng-polish.service")" "the refused install writes no unit files"

# The escape hatch: a claude whose environment the probe cannot reproduce must
# not be un-installable.
PATH="$NODEISH:$PATH" XDG_CONFIG_HOME="$XDG" LOOP_ENG_TIMER_NO_SYSTEMCTL=1 \
  LOOP_ENG_TIMER_SKIP_PROBE=1 LOOP_ENG_CLAUDE_BIN="$SHIM_CLAUDE" \
  bash "$INSTALL" polish "$SB" >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 0 "$rc" "LOOP_ENG_TIMER_SKIP_PROBE=1 installs anyway"
run_uninstall polish >/dev/null

# --- P3-3: `disable --now <unit>.timer` does not stop a RUNNING oneshot service ---
# systemd's --now applies to the unit named. Uninstalling at 03:05, while that
# night's run is still going, removed the schedule and left a bypassPermissions
# session running against the tree the operator just unscheduled. The service
# has to be stopped by name. Asserted through a systemctl stub that records its
# argv — the suite must never touch real systemd.
FAKEBIN="$XDG/fakebin"; mkdir -p "$FAKEBIN"
SYSTEMCTL_LOG="$XDG/systemctl.log"
cat > "$FAKEBIN/systemctl" <<'EOS'
#!/bin/sh
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
exit 0
EOS
chmod +x "$FAKEBIN/systemctl"
: > "$SYSTEMCTL_LOG"
XDG_CONFIG_HOME="$XDG" PATH="$FAKEBIN:$PATH" SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  LOOP_ENG_CLAUDE_BIN="$FAKE_CLAUDE" bash "$INSTALL" polish "$SB" >/dev/null 2>&1
# That install ran without LOOP_ENG_TIMER_NO_SYSTEMCTL, so this is the one place
# the installer's sole side effect is observable: writing the unit files is not
# installing. A timer that is written but never `enable`d silently never runs —
# the exact trap install-timer.sh exists to kill. Assert it before the log is
# truncated for the uninstall half below.
assert_file_contains "$SYSTEMCTL_LOG" "--user enable --now loop-eng-polish.timer" "install actually enables the timer, not just writes the unit files"
: > "$SYSTEMCTL_LOG"
XDG_CONFIG_HOME="$XDG" PATH="$FAKEBIN:$PATH" SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
  bash "$UNINSTALL" polish >/dev/null 2>&1
assert_file_contains "$SYSTEMCTL_LOG" "--user disable --now loop-eng-polish.timer" "uninstall still disables the timer"
assert_file_contains "$SYSTEMCTL_LOG" "--user stop loop-eng-polish.service" "uninstall also stops the service that may be mid-run"
# Order is load-bearing: unschedule first, so the timer cannot start a new run
# in the gap between stopping the service and deleting the unit files.
dis_ln=$(grep -n -- '--user disable --now loop-eng-polish.timer' "$SYSTEMCTL_LOG" | head -1 | cut -d: -f1)
stop_ln=$(grep -n -- '--user stop loop-eng-polish.service' "$SYSTEMCTL_LOG" | head -1 | cut -d: -f1)
if [ -n "$dis_ln" ] && [ -n "$stop_ln" ] && [ "$dis_ln" -lt "$stop_ln" ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  echo "  FAIL: the timer must be disabled (line ${dis_ln:-none}) before the service is stopped (line ${stop_ln:-none})" >&2
fi


# --- the enable that FAILS: "unit files written" is not "scheduled" ---
# The block above pins that `enable --now` is CALLED. This one pins what the
# installer does when it comes back NON-ZERO, which the suite had never seen.
# Not hypothetical: on a box with no user bus (no session, no lingering)
# `systemctl --user` exits 1 with "Failed to connect to bus", and this repo's
# own nightly-timer setup hit exactly that. The install-time answer has to be a
# refusal — otherwise the installer prints "enabled ... (next run 03:00 daily)"
# over a timer that does not exist: the header's "installed but never `enable`d,
# so they silently never run" trap, wearing a success message.
# LOOP_ENG_TIMER_NO_SYSTEMCTL=1 is useless here — it returns before this branch
# — so a stubbed systemctl on PATH is the only way in.
FAILBIN="$XDG/failbin"; mkdir -p "$FAILBIN"
FAIL_LOG="$XDG/systemctl-fail.log"
cat > "$FAILBIN/systemctl" <<'EOS'
#!/bin/sh
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
case "$*" in
  *"enable --now"*) exit 1 ;;
esac
exit 0
EOS
chmod +x "$FAILBIN/systemctl"
run_uninstall polish >/dev/null 2>&1 || true
: > "$FAIL_LOG"
XDG_CONFIG_HOME="$XDG" PATH="$FAILBIN:$PATH" SYSTEMCTL_LOG="$FAIL_LOG" \
  LOOP_ENG_CLAUDE_BIN="$FAKE_CLAUDE" bash "$INSTALL" polish "$SB" \
  > "$XDG/enable-fail.out" 2>&1 && rc=0 || rc=$?
assert_eq 1 "$rc" "an enable that FAILS fails the install"
# Anchors the case to the branch it claims to cover: had the install died
# earlier (scope, claude probe, collision) the assertions around this one would
# be measuring some other refusal entirely.
assert_file_contains "$FAIL_LOG" "--user enable --now loop-eng-polish.timer" "the failing case really got as far as the enable"
assert_file_contains "$XDG/enable-fail.out" "NOT scheduled" "the failed enable tells the operator the timer is NOT scheduled"
if grep -qF -- "install-timer: enabled loop-eng-polish.timer" "$XDG/enable-fail.out"; then
  FAIL=$((FAIL+1)); echo "  FAIL: the install announced it enabled a timer systemctl had just refused to enable" >&2
else
  PASS=$((PASS+1))
fi
# The refusal says the files WERE written and offers a manual enable as the fix
# — true only if it leaves them on disk. (Contrast the probe refusal above,
# which writes none: that one answers before the files exist.)
assert_eq yes "$(exists "$UNIT_DIR/loop-eng-polish.timer")" "the refusal leaves the unit files it says it wrote, so its manual-enable advice can work"

# ...and the same for daemon-reload, the OTHER half of that condition — a
# separate arm, because `! daemon-reload || ! enable` short-circuits and decides
# on the reload before enable is ever consulted. This stub lets enable SUCCEED,
# which is what makes the case distinguishing: stop checking the reload and the
# install reports success.
RELOADBIN="$XDG/reloadfailbin"; mkdir -p "$RELOADBIN"
cat > "$RELOADBIN/systemctl" <<'EOS'
#!/bin/sh
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
case "$*" in
  *daemon-reload*) exit 1 ;;
esac
exit 0
EOS
chmod +x "$RELOADBIN/systemctl"
run_uninstall polish >/dev/null 2>&1 || true
: > "$FAIL_LOG"
XDG_CONFIG_HOME="$XDG" PATH="$RELOADBIN:$PATH" SYSTEMCTL_LOG="$FAIL_LOG" \
  LOOP_ENG_CLAUDE_BIN="$FAKE_CLAUDE" bash "$INSTALL" polish "$SB" \
  > "$XDG/reload-fail.out" 2>&1 && rc=0 || rc=$?
assert_eq 1 "$rc" "a daemon-reload that FAILS fails the install too, even though the enable after it would have succeeded"
assert_file_contains "$XDG/reload-fail.out" "NOT scheduled" "the failed daemon-reload also says the timer is NOT scheduled"
run_uninstall polish >/dev/null 2>&1 || true

report "test-install-timer"
