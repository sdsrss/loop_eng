#!/usr/bin/env bash
# loop-eng systemd --user timer uninstaller — exact reverse of install-timer.sh.
# Every resource install acquires (enabled timer, unit files, daemon state) is
# released here in reverse order. Benign no-op when nothing is installed.
#
# Usage: uninstall-timer.sh <polish|autoloop>
#
# Testability: honors $XDG_CONFIG_HOME; LOOP_ENG_TIMER_NO_SYSTEMCTL=1 removes the
# files but skips every systemctl call (used by the test suite).

set -euo pipefail

die() { echo "uninstall-timer: $*" >&2; exit 1; }

MODE="${1:-}"
case "$MODE" in
  polish|autoloop) ;;
  *) die "usage: uninstall-timer.sh <polish|autoloop>" ;;
esac

UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT="loop-eng-$MODE"
SVC="$UNIT_DIR/$UNIT.service"
TMR="$UNIT_DIR/$UNIT.timer"

if [ ! -e "$SVC" ] && [ ! -e "$TMR" ]; then
  echo "uninstall-timer: $UNIT not installed (nothing to do)"
  exit 0
fi

# Reverse order: stop+disable the running unit BEFORE deleting its files, so
# systemd's enablement symlink is cleaned up rather than orphaned.
if [ "${LOOP_ENG_TIMER_NO_SYSTEMCTL:-0}" != 1 ] && command -v systemctl >/dev/null 2>&1; then
  # disable --now may warn if already inactive/absent; that's fine, keep going.
  systemctl --user disable --now "$UNIT.timer" 2>/dev/null || true
fi

rm -f "$TMR" "$SVC"
echo "uninstall-timer: removed $TMR"
echo "uninstall-timer: removed $SVC"

if [ "${LOOP_ENG_TIMER_NO_SYSTEMCTL:-0}" != 1 ] && command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user reset-failed "$UNIT.service" "$UNIT.timer" 2>/dev/null || true
fi

# Residue check — prove the reversal is complete.
if [ -e "$SVC" ] || [ -e "$TMR" ]; then
  die "files still present after removal: $SVC / $TMR"
fi
echo "uninstall-timer: $UNIT fully removed"
