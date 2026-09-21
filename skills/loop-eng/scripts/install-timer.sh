#!/usr/bin/env bash
# loop-eng systemd --user timer installer — makes the dogfood scheduler a
# tracked, one-command-removable artifact instead of a hand-created orphan.
#
# The problem it fixes: unit files hand-dropped into ~/.config/systemd/user/
# during dogfooding leave no install/uninstall record. They get forgotten
# (worse: "installed but never `enable`d", so they silently never run). This
# script writes the pair AND enables the timer, and uninstall-timer.sh reverses
# it exactly.
#
# Usage:
#   install-timer.sh polish   <repo-dir> [scope]        [--time HH:MM] [--allow-write]
#   install-timer.sh autoloop <repo-dir> [max-sessions] [--time HH:MM]  --allow-write
#
#   --allow-write is OPTIONAL for polish and REQUIRED for autoloop — that
#   driver has no report-only mode, so an autoloop install without it is
#   refused (see the gate further down).
#     polish    arg = scope passed to unattended-polish.sh   (default src/)
#     autoloop  arg = max-sessions for unattended-autoloop.sh (default 8, min 1
#                     — 0 is no budget, not a small one; see the check below)
#     --time HH:MM   OnCalendar daily trigger time            (default 03:00)
#     --allow-write  opt into the mode's write path (OFF by default):
#                      polish   -> ExecStart gets --auto-fix + LOOP_ENG_ALLOW_AUTOFIX=1
#                      autoloop -> Environment gets LOOP_ENG_ALLOW_AUTOBUILD=1
#                    Without it, polish is report-only, so a scheduled run
#                    cannot write. An autoloop install without it is REFUSED:
#                    that driver has no report-only mode, so the unit could
#                    never do anything but exit 1 every night.
#
# Safety / testability:
#   - unit dir honors $XDG_CONFIG_HOME (falls back to $HOME/.config)
#   - LOOP_ENG_TIMER_NO_SYSTEMCTL=1 writes the files but skips every systemctl
#     call (used by the test suite; also handy on a box with no user D-Bus)
#   - a failed `systemctl enable` is LOUD and exits non-zero — we never leave
#     you with the "installed but not scheduled" trap this script exists to kill

set -euo pipefail

die() { echo "install-timer: $*" >&2; exit 1; }

MODE="${1:-}"; REPO="${2:-}"
case "$MODE" in
  polish|autoloop) ;;
  *) die "usage:
  install-timer.sh polish   <repo-dir> [scope]        [--time HH:MM] [--allow-write]
  install-timer.sh autoloop <repo-dir> [max-sessions] [--time HH:MM]  --allow-write
--allow-write is optional for polish and REQUIRED for autoloop, which has no report-only mode." ;;
esac
[ -n "$REPO" ] || die "missing <repo-dir>"
shift 2

TIME="03:00"
ALLOW_WRITE=0
ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    # Check for the value BEFORE shifting: `shift 2` with one arg left fails,
    # and under `set -e` that killed the script right here — exit 1, empty
    # stderr, before the HH:MM validation below could name what was wrong.
    --time)
      [ $# -ge 2 ] || die "--time requires an HH:MM value (24h), e.g. --time 03:00"
      TIME="$2"; shift 2 ;;
    --allow-write) ALLOW_WRITE=1; shift ;;
    --*) die "unknown option: $1" ;;
    *) [ -z "$ARG" ] || die "unexpected extra argument: $1"; ARG="$1"; shift ;;
  esac
done

# HH:MM, 00:00–23:59 — a bad value would make systemd reject the unit at load.
case "$TIME" in
  [0-2][0-9]:[0-5][0-9]) [ "${TIME%%:*}" -le 23 ] || die "--time hour out of range: $TIME" ;;
  *) die "--time must be HH:MM (24h), got: $TIME" ;;
esac

# ---------------------------------------------------------------------------
# Last of the argv-only checks. Everything BELOW this block touches the machine
# (resolving the repo, finding the runner, resolving and then EXECUTING the
# claude binary); everything above it is answerable from the command line alone.
#
# The --allow-write gate lives here for that reason. It depends on nothing but
# MODE and ALLOW_WRITE, both fixed by the parse loop above — yet it used to sit
# after all seven environment checks, so on a box without the claude CLI
# `install-timer.sh autoloop <repo>` answered "claude CLI not found". The user
# then installed a CLI this request never needed, re-ran, and only at that point
# learned the request had never been installable. A question the arguments
# already answer must not be deferred behind the machine's state.
#
# max-sessions moves up with it and stays FIRST of the two: same class of check,
# and a user who typed both mistakes should hear about the number they can see.
# Pinned by an assertion on the message — exit code alone cannot tell two
# refusals apart.
#
# The collision check is NOT argv-only (it reads $UNIT_DIR), so it stays below.
# Consequence, deliberate: a colliding autoloop install must be otherwise valid
# before it is told about the collision.
#
# polish is untouched: its no-flag mode runs report-only and does real work,
# which is why it is the documented safe default.
if [ "$MODE" = autoloop ]; then
  MAX_SESSIONS="${ARG:-8}"
  case "$MAX_SESSIONS" in ''|*[!0-9]*) die "autoloop max-sessions must be an integer: $MAX_SESSIONS" ;; esac
  # ...and at least 1. A digit-class check alone accepts 0, which is not a
  # smaller budget but no budget: unattended-autoloop.sh opens at session=0 and
  # its loop head reads `[ "$session" -ge "$MAX_SESSIONS" ]`, so 0 -ge 0 breaks
  # before the first session starts. The unit then exits 1 on every trigger
  # having launched nothing — the same harm the --allow-write gate below
  # refuses, reached through a number instead of a missing flag.
  #
  # Tested by glob, not by `[ "$MAX_SESSIONS" -eq 0 ]`: test's operands are
  # evaluated as arithmetic, where a leading zero is octal, so the arithmetic
  # form dies on a legitimate `08` ("value too great for base") under set -e
  # instead of refusing anything. The value is already known non-empty and
  # all-digits here, so "contains no non-zero digit" is exactly "is zero" —
  # and it catches 00 and 000 the same way it catches 0. Nonzero leading-zero
  # counts pass through unchanged; the driver normalizes them with 10#.
  case "$MAX_SESSIONS" in *[!0]*) ;;
    *) die "autoloop max-sessions must be at least 1, got: $MAX_SESSIONS. Zero is not a smaller budget, it is no budget: unattended-autoloop.sh checks the session cap before starting a session, so a cap of 0 breaks out of the loop immediately and the driver exits 1 with sessions=0 and the backlog untouched — no work, a status=1/FAILURE record in the journal on every trigger, every night, and the sentence explaining why buried in the repo's .loop/cron.log. Pass the number of sessions one nightly run may use (default 8)." ;;
  esac
  [ "$ALLOW_WRITE" = 1 ] || die "autoloop has no report-only mode, so this timer could never do anything: unattended-autoloop.sh refuses to build unless LOOP_ENG_ALLOW_AUTOBUILD=1 is set, and the unit would exit 1 on every trigger, every night — no work, a status=1/FAILURE record in the journal, and the sentence explaining why buried in the repo's .loop/cron.log. Re-run with --allow-write to schedule real unattended builds — they modify and commit to the target repo with no human in the loop — or install a polish timer instead, whose no-flag mode is report-only and does useful work."
fi
# ---------------------------------------------------------------------------

# Resolve repo to an absolute path — systemd ExecStart/WorkingDirectory reject
# relative paths, and a scheduled run has no inherited cwd.
# Keep the user's original argument: the command substitution below overwrites
# REPO with an empty string when `cd` fails, so `die` would otherwise print a
# blank path. Report the value the user actually passed.
REPO_IN="$REPO"
REPO="$(cd "$REPO" 2>/dev/null && pwd)" || die "repo-dir does not exist: $REPO_IN"
[ -d "$REPO/.git" ] || die "not a git repo (no .git): $REPO"

# Resolve the unattended runner from THIS script's own directory (the plugin),
# not from the target repo. When loop-eng is installed as a marketplace plugin
# the runners live in the plugin cache next to this script, and the target
# project has no skills/loop-eng/ tree of its own — the pre-v0.4.1 lookup under
# "$REPO/skills/..." only worked when the target repo WAS the plugin repo.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$SCRIPT_DIR/unattended-$MODE.sh"
[ -x "$RUNNER" ] || die "runner not found or not executable: $RUNNER"

# Resolve the claude CLI to an ABSOLUTE path at install time. The unit hardcodes
# a minimal PATH, so a claude living elsewhere (nvm, custom npm prefix) makes the
# runner fail with exit 127 at first trigger — with the error only in cron.log,
# the exact "installed but silently never runs" trap this script exists to kill.
# Fail here, at install time, where the human can see it.
CLAUDE_IN="${LOOP_ENG_CLAUDE_BIN:-claude}"
CLAUDE_ABS="$(command -v "$CLAUDE_IN")" \
  || die "claude CLI not found (looked for: $CLAUDE_IN). Install it, or set LOOP_ENG_CLAUDE_BIN to the binary the scheduled run should use."

# The unit's PATH, declared once and used twice: written into the unit below,
# and used right now to prove the binary can actually RUN under it.
UNIT_PATH="$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"

# Resolving the binary is not the same as proving it runs. `command -v` searches
# the INSTALLING shell's PATH; the unit hardcodes the minimal one above. A
# claude installed by npm or nvm is an `#!/usr/bin/env node` shim, so it
# resolves here and exits 127 at 03:00 with the error only in cron.log — the
# same "enables cleanly, breaks at first trigger" family as the whitespace and
# percent guards above, and the reason those all fail at install time instead.
#
# `env -i` plus the variables a `systemd --user` service reliably gets. Not a
# bare `env -i`: that is stricter than reality, and a probe that refuses
# installs systemd would have run is worse than no probe. A binary whose
# environment this still cannot reproduce is what LOOP_ENG_TIMER_SKIP_PROBE is
# for — the probe is a guard, not a gate the operator cannot open.
if [ "${LOOP_ENG_TIMER_SKIP_PROBE:-0}" != 1 ]; then
  if ! env -i HOME="${HOME:-}" USER="${USER:-}" LOGNAME="${LOGNAME:-}" \
         LANG="${LANG:-}" XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-}" \
         PATH="$UNIT_PATH" "$CLAUDE_ABS" --version >/dev/null 2>&1; then
    die "the claude CLI at $CLAUDE_ABS does not run under the unit's PATH, so the scheduled run would fail at its first trigger with the error only in $REPO/.loop/cron.log.
Reproduce it with:
  env -i HOME=\"\$HOME\" PATH=\"$UNIT_PATH\" $CLAUDE_ABS --version
This is what an npm/nvm \`#!/usr/bin/env node\` shim looks like: it resolves in your shell and finds no interpreter in the unit's minimal PATH. Fix it by pointing LOOP_ENG_CLAUDE_BIN at a wrapper that sets up the interpreter, or by putting the interpreter somewhere on that PATH. If the probe is wrong about your setup, re-run with LOOP_ENG_TIMER_SKIP_PROBE=1."
  fi
fi

# systemd ExecStart is whitespace-delimited and both paths below are injected
# unquoted; a space in the repo OR the plugin path yields a unit that passes
# `systemctl enable` but fails at first trigger (error only in the journal).
# Refuse up front so the failure is loud and at install time. (The claude path
# lands in an Environment= line, which is whitespace-sensitive the same way.)
case "$REPO"       in *[[:space:]]*) die "repo-dir path contains whitespace, which the systemd unit cannot represent unquoted: $REPO" ;; esac
case "$RUNNER"     in *[[:space:]]*) die "plugin path contains whitespace, which the systemd unit cannot represent unquoted: $RUNNER" ;; esac
case "$CLAUDE_ABS" in *[[:space:]]*) die "claude path contains whitespace, which the systemd unit cannot represent unquoted: $CLAUDE_ABS" ;; esac

# systemd treats a literal % in unit files as a specifier prefix (%i, %h, ...);
# a % in any value injected into ExecStart=/Environment=/StandardOutput= lines
# misexpands or makes the unit fail to load — the same "enables cleanly, breaks
# at first trigger" class as the whitespace trap above. Refuse at install time.
case "$REPO"       in *%*) die "repo-dir path contains a percent sign, which systemd expands as a unit specifier: $REPO" ;; esac
case "$RUNNER"     in *%*) die "plugin path contains a percent sign, which systemd expands as a unit specifier: $RUNNER" ;; esac
case "$CLAUDE_ABS" in *%*) die "claude path contains a percent sign, which systemd expands as a unit specifier: $CLAUDE_ABS" ;; esac

# Build the mode-specific ExecStart tail + write-enable Environment lines.
ENV_LINES=""
if [ "$MODE" = polish ]; then
  SCOPE="${ARG:-src/}"
  # Same reasoning as the REPO/RUNNER/CLAUDE_ABS guards above: SCOPE lands
  # unquoted in ExecStart, so an embedded space splits it into a wrong scope
  # plus a stray argument the runner mistakes for its flag — silently
  # report-only with the wrong scope, surfacing only at first trigger.
  case "$SCOPE" in *[[:space:]]*) die "polish scope contains whitespace, which the systemd unit cannot represent unquoted: $SCOPE" ;; esac
  case "$SCOPE" in *%*) die "polish scope contains a percent sign, which systemd expands as a unit specifier: $SCOPE" ;; esac
  # A scope that isn't in the repo is the same "enables cleanly, breaks at first
  # trigger" family as the two guards above, and the one hardest to notice: the
  # unit loads, `systemctl enable` succeeds, and every nightly run reviews a path
  # that isn't there — finds nothing, exits 0, logs success, indefinitely.
  # unattended-polish.sh's header records this exact outcome from a flag mistaken
  # for the scope; it rejects that shape now, but a typo'd or since-moved
  # directory still reached the unit file. Check it here, at install time, with a
  # human watching — the same reason the claude binary is resolved here and not
  # left to exit 127 at 03:00.
  # Unquoted on purpose: /polish takes scope PATHS, and a glob like src/*.ts is
  # legitimate input that `test -e` would never match literally. An unmatched
  # glob stays literal, so it fails the check exactly like a plain typo.
  scope_found=0
  # shellcheck disable=SC2086
  for _m in $REPO/$SCOPE; do
    if [ -e "$_m" ]; then scope_found=1; break; fi
  done
  [ "$scope_found" = 1 ] || die "polish scope not found in the repo: $SCOPE (looked for $REPO/$SCOPE). A scheduled run would review a path that does not exist — finding nothing, every night, while reporting success. Pass a path or glob that exists relative to the repo root, e.g. src/ or lib/."
  EXEC_ARGS="$REPO $SCOPE"
  if [ "$ALLOW_WRITE" = 1 ]; then
    EXEC_ARGS="$EXEC_ARGS --auto-fix"
    ENV_LINES="Environment=LOOP_ENG_ALLOW_AUTOFIX=1"
  fi
  DESC="loop-eng nightly report-only polish (dogfood)"
  [ "$ALLOW_WRITE" = 1 ] && DESC="loop-eng nightly auto-fix polish (dogfood)"
else
  # MAX_SESSIONS was parsed and range-checked (integer, >= 1) in the argv-only
  # block above, next to the gate that makes this branch reachable ONLY in write
  # mode. "Range-checked" was aspirational while that block only ran a digit
  # class: 0 passed it and produced a unit that exited 1 at every trigger.
  EXEC_ARGS="$REPO $MAX_SESSIONS"
  # Description and env are unconditional, because that gate already refused
  # every no-write shape. A second arm here used to read "report-only: refuses
  # to build" — a mode this driver has never had, and the exact symptom the gate
  # removes. Deleted rather than left unreachable, so no future reader trusts a
  # string nothing can produce. Both are pinned by assertions in
  # test-install-timer.sh; if a future change gives the gate an escape hatch,
  # these two lines are what starts lying.
  DESC="loop-eng autoloop driver (dogfood, WRITES code unattended)"
  ENV_LINES="Environment=LOOP_ENG_ALLOW_AUTOBUILD=1"
fi

UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="loop-eng-$MODE"
# NOTE: $UNIT_DIR is only NAMED here. Creating it waits until after the last
# refusal below — the collision check merely reads from it, and a refused
# install must leave nothing behind, including an empty config directory on a
# box that never had one.

# Same-repo, same-minute collision with the OTHER mode's timer.
#
# Both modes default to `--time 03:00` and both unit names are per-USER, not
# per-repo, so "install a nightly polish timer, then a nightly autoloop timer on
# the same repo" — the documented way to use this script twice — schedules two
# drivers against one working tree at the same instant. The drivers now refuse
# to overlap (the loser exits 69, EX_UNAVAILABLE), so the tree is safe; but that
# makes the collision SILENT: whichever timer loses the race does no work, every
# night, while `systemctl status` stays green and the only trace is one line in
# .loop/unattended.log. Refuse here instead, where a human can pick a time.
#
# Only an exact same-repo AND same-time pair is refused. Two repos at 03:00 are
# fine (different trees, different locks), and so is the same repo at different
# times — that is the intended way to run both.
OTHER_MODE=autoloop
[ "$MODE" = autoloop ] && OTHER_MODE=polish
OTHER_SVC="$UNIT_DIR/loop-eng-$OTHER_MODE.service"
OTHER_TMR="$UNIT_DIR/loop-eng-$OTHER_MODE.timer"
if [ -f "$OTHER_SVC" ] && [ -f "$OTHER_TMR" ]; then
  # ExecStart=<runner> <repo> <args…> — every path in it is whitespace-free by
  # the guards above, so field 2 is the repo.
  other_repo=$(grep -m1 '^ExecStart=' "$OTHER_SVC" 2>/dev/null | awk '{print $2}')
  other_time=$(grep -m1 '^OnCalendar=' "$OTHER_TMR" 2>/dev/null | sed 's/^OnCalendar=\*-\*-\* //; s/:00$//')
  if [ -n "$other_repo" ] && [ "$other_repo" = "$REPO" ] && [ "$other_time" = "$TIME" ]; then
    die "loop-eng-$OTHER_MODE.timer already runs $REPO at $TIME, and the two drivers cannot share a working tree — the second one to fire would exit 69 (another driver is running) and do nothing, silently, every night. Re-run with a different --time (e.g. --time 04:00), or remove the other timer first: $(dirname "$0")/uninstall-timer.sh $OTHER_MODE"
  fi
fi

# Past the last refusal — now the directory may be created. (Named at $UNIT_DIR
# above; see the note there for why the mkdir waits until here.)
mkdir -p "$UNIT_DIR"

# The unit's StandardOutput/Error append to $REPO/.loop/cron.log; systemd opens
# that file BEFORE ExecStart runs, so the directory must already exist at first
# trigger. The runner's own `mkdir -p .loop` happens inside ExecStart — too late
# for that first run's log redirect. Create it now so the first run isn't lost.
mkdir -p "$REPO/.loop"

SVC="$UNIT_DIR/$UNIT.service"
TMR="$UNIT_DIR/$UNIT.timer"

# StandardOutput/Error append to the repo's own bookkeeping dir (matches the
# unattended runners, which already log there and gitignore it).
{
  echo "[Unit]"
  echo "Description=$DESC"
  echo
  echo "[Service]"
  echo "Type=oneshot"
  echo "Environment=PATH=$UNIT_PATH"
  echo "Environment=LOOP_ENG_CLAUDE_BIN=$CLAUDE_ABS"
  [ -n "$ENV_LINES" ] && echo "$ENV_LINES"
  echo "ExecStart=$RUNNER $EXEC_ARGS"
  echo "StandardOutput=append:$REPO/.loop/cron.log"
  echo "StandardError=append:$REPO/.loop/cron.log"
} > "$SVC"

{
  echo "[Unit]"
  echo "Description=Daily loop-eng $MODE at $TIME"
  echo
  echo "[Timer]"
  echo "OnCalendar=*-*-* $TIME:00"
  # Deliberately NOT Persistent=true: with it, enabling the timer AFTER today's
  # OnCalendar has passed makes systemd immediately "catch up" the missed run —
  # a surprise mid-day execution (and, under --allow-write, a surprise write run)
  # just from installing. A missed nightly polish is not worth catching up; it
  # simply runs at the next OnCalendar. Runs are skipped, never back-filled.
  echo
  echo "[Install]"
  echo "WantedBy=timers.target"
} > "$TMR"

echo "install-timer: wrote $SVC"
echo "install-timer: wrote $TMR"

if [ "${LOOP_ENG_TIMER_NO_SYSTEMCTL:-0}" = 1 ]; then
  echo "install-timer: LOOP_ENG_TIMER_NO_SYSTEMCTL=1 set — skipped enable (files only)"
  exit 0
fi

command -v systemctl >/dev/null 2>&1 || die "systemctl not found; unit files written but NOT scheduled. Enable manually once systemd is available: systemctl --user enable --now $UNIT.timer"

if ! systemctl --user daemon-reload || ! systemctl --user enable --now "$UNIT.timer"; then
  die "unit files written but 'systemctl --user enable --now $UNIT.timer' FAILED — the timer is NOT scheduled. Fix the systemd error above and re-run, or enable manually."
fi

echo "install-timer: enabled $UNIT.timer (next run ${TIME} daily)"
systemctl --user list-timers "$UNIT.timer" --no-pager 2>/dev/null | grep -F "$UNIT" || true
if [ "$ALLOW_WRITE" = 1 ]; then
  echo "install-timer: WRITE MODE is ON — scheduled runs may modify $REPO. Remove with: $(dirname "$0")/uninstall-timer.sh $MODE"
fi
