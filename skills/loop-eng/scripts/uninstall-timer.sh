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

# Derive $REPO/.loop/cron.log from the unit file BEFORE it is deleted. uninstall
# is invoked with a mode only (never the repo path), so the .service — which
# records `StandardOutput=append:$REPO/.loop/cron.log` — is the sole surviving
# record of where install-timer pre-created that .loop. Parse it now; the orphan
# cleanup at the end acts on it after the unit files are gone.
CRON_LOG=""
if [ -f "$SVC" ]; then
  CRON_LOG="$(sed -n 's|^StandardOutput=append:||p' "$SVC" | head -n1)"
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

# Orphan cleanup. install-timer pre-creates $REPO/.loop purely so systemd can
# open cron.log for the unit's StandardOutput before ExecStart runs; a timer
# installed but never run leaves that cron.log (and an otherwise-empty .loop)
# behind. Remove ONLY the install-created cron.log, and the .loop dir only if it
# now holds nothing else. A live loop's state (criteria.tsv, results.json,
# active, evidence/) must NEVER be destroyed by a timer uninstall — so if .loop
# contains anything besides cron.log we remove nothing and leave cron.log too
# (err on preservation; rmdir, never rm -r). CRON_LOG was parsed from the unit
# file above, before it was deleted.
case "$CRON_LOG" in
  */.loop/cron.log)
    LOOP_DIR="${CRON_LOG%/cron.log}"
    if [ -d "$LOOP_DIR" ]; then
      (
        shopt -s nullglob dotglob
        only_cron=1
        for entry in "$LOOP_DIR"/*; do
          [ "$entry" = "$CRON_LOG" ] || { only_cron=0; break; }
        done
        if [ "$only_cron" = 1 ]; then
          rm -f "$CRON_LOG"
          rmdir "$LOOP_DIR" 2>/dev/null || true
          echo "uninstall-timer: removed install-created cron.log orphan under $LOOP_DIR"
        else
          echo "uninstall-timer: kept $LOOP_DIR (holds live loop state besides cron.log)"
        fi
      )
    fi
    ;;
esac
