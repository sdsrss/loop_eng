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
#   install-timer.sh <polish|autoloop> <repo-dir> [arg] [--time HH:MM] [--allow-write]
#     polish    arg = scope passed to unattended-polish.sh   (default src/)
#     autoloop  arg = max-sessions for unattended-autoloop.sh (default 8)
#     --time HH:MM   OnCalendar daily trigger time            (default 03:00)
#     --allow-write  opt into the mode's write path (OFF by default):
#                      polish   -> ExecStart gets --auto-fix + LOOP_ENG_ALLOW_AUTOFIX=1
#                      autoloop -> Environment gets LOOP_ENG_ALLOW_AUTOBUILD=1
#                    Without it, polish is report-only and autoloop refuses to
#                    build (its own env guard), so a scheduled run cannot write.
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
  *) die "usage: install-timer.sh <polish|autoloop> <repo-dir> [arg] [--time HH:MM] [--allow-write]" ;;
esac
[ -n "$REPO" ] || die "missing <repo-dir>"
shift 2

TIME="03:00"
ALLOW_WRITE=0
ARG=""
while [ $# -gt 0 ]; do
  case "$1" in
    --time) TIME="${2:-}"; shift 2 ;;
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

# Resolve repo to an absolute path — systemd ExecStart/WorkingDirectory reject
# relative paths, and a scheduled run has no inherited cwd.
REPO="$(cd "$REPO" 2>/dev/null && pwd)" || die "repo-dir does not exist: $REPO"
[ -d "$REPO/.git" ] || die "not a git repo (no .git): $REPO"

RUNNER="$REPO/skills/loop-eng/scripts/unattended-$MODE.sh"
[ -x "$RUNNER" ] || die "runner not found or not executable: $RUNNER"

# Build the mode-specific ExecStart tail + write-enable Environment lines.
ENV_LINES=""
if [ "$MODE" = polish ]; then
  SCOPE="${ARG:-src/}"
  EXEC_ARGS="$REPO $SCOPE"
  if [ "$ALLOW_WRITE" = 1 ]; then
    EXEC_ARGS="$EXEC_ARGS --auto-fix"
    ENV_LINES="Environment=LOOP_ENG_ALLOW_AUTOFIX=1"
  fi
  DESC="loop-eng nightly report-only polish (dogfood)"
  [ "$ALLOW_WRITE" = 1 ] && DESC="loop-eng nightly auto-fix polish (dogfood)"
else
  MAX_SESSIONS="${ARG:-8}"
  case "$MAX_SESSIONS" in ''|*[!0-9]*) die "autoloop max-sessions must be an integer: $MAX_SESSIONS" ;; esac
  EXEC_ARGS="$REPO $MAX_SESSIONS"
  DESC="loop-eng autoloop driver (dogfood, report-only: refuses to build)"
  if [ "$ALLOW_WRITE" = 1 ]; then
    ENV_LINES="Environment=LOOP_ENG_ALLOW_AUTOBUILD=1"
    DESC="loop-eng autoloop driver (dogfood, WRITES code unattended)"
  fi
fi

UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="loop-eng-$MODE"
mkdir -p "$UNIT_DIR"

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
  echo "Environment=PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
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
