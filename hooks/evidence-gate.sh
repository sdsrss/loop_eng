#!/usr/bin/env bash
# loop-eng evidence-gate — PreToolUse hook.
#
# .loop/results.json and .loop/evidence/ are machine-written by run-contract.sh;
# .loop/criteria.tsv is written once at contract time and fixed while the loop
# is armed (.loop/active); after a loop ends the next contract may rewrite it.
# This hook denies model writes to them (exit 2, stderr fed back to the model),
# so a "passes": true can never be typed into existence — only produced by the
# runner actually executing the contract's commands. Weakening the contract by
# rewriting an armed criteria.tsv is likewise mechanically blocked, not just
# forbidden in prompt text.
#
# The contract lock is armed-scoped, not permanent: a model that removes
# .loop/active to unlock criteria.tsv has already escaped the stop-gate the
# same way — the gate guards against drift INSIDE an armed loop, not against
# adversarial disarming; red lines + human review of the diff cover the rest.
#
# Bash coverage is best-effort by design: a conservative pattern (redirect /
# tee / mv / cp / sed -i / truncate / rm targeting a protected path) catches
# the plausible accidents; the red lines in the command prompts remain the
# second layer. Fail-open on missing parser or unparseable input — the gate
# must never brick a session.
#
# Escape hatch (humans, not models): LOOP_ENG_DISABLE_EVIDENCE_GATE=1.
set -u

if [ "${LOOP_ENG_DISABLE_EVIDENCE_GATE:-0}" = "1" ]; then
  cat > /dev/null
  exit 0
fi

INPUT=$(cat)

TOOL=""; FILE=""; CMD=""
if command -v jq >/dev/null 2>&1; then
  TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || TOOL=""
  # NotebookEdit carries its target in .tool_input.notebook_path, every other
  # write tool in .tool_input.file_path — fall through so NotebookEdit is not a
  # blind spot into the ledger.
  FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null) || FILE=""
  CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || CMD=""
elif command -v python3 >/dev/null 2>&1; then
  PARSED=$(printf '%s' "$INPUT" | python3 -c '
import json, sys, shlex
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti = d.get("tool_input") or {}
# file_path for Write/Edit/MultiEdit; notebook_path for NotebookEdit.
fp = ti.get("file_path") or ti.get("notebook_path") or ""
print("TOOL=%s" % shlex.quote(str(d.get("tool_name", ""))))
print("FILE=%s" % shlex.quote(str(fp)))
print("CMD=%s" % shlex.quote(str(ti.get("command", ""))))
' 2>/dev/null) || PARSED=""
  eval "$PARSED"
else
  echo "loop-eng evidence-gate: no jq or python3 available; gate inactive for this call." >&2
  exit 0
fi

deny() {
  {
    echo "loop-eng evidence-gate DENIED: $1"
    echo ".loop/results.json and .loop/evidence/ are machine-written evidence."
    echo "let the stop-gate run the contract on your next stop attempt, or run"
    echo "the plugin's run-contract.sh (skills/loop-eng/scripts/run-contract.sh)"
    echo "yourself instead of writing claims. Weakening a check to pass it is a"
    echo "red line."
    echo "(Human escape hatch: LOOP_ENG_DISABLE_EVIDENCE_GATE=1.)"
  } >&2
  exit 2
}

case "$TOOL" in
  Write|Edit|MultiEdit|NotebookEdit)
    case "$FILE" in
      */.loop/results.json|.loop/results.json)
        deny "the evidence ledger .loop/results.json" ;;
      */.loop/evidence/*|.loop/evidence/*)
        deny "raw evidence under .loop/evidence/" ;;
      */.loop/criteria.tsv|.loop/criteria.tsv)
        # Locked while the loop is armed: the sibling .loop/active next to this
        # criteria.tsv must exist. Derive the marker from $FILE's dir so relative
        # and absolute paths both resolve sensibly. Do NOT require the file to
        # pre-exist — a legacy (verify.sh) loop has no criteria.tsv, and CREATING
        # one while armed hijacks the stop-gate (which prefers criteria.tsv over
        # verify.sh), so the create must be denied as well as the overwrite.
        if [ -e "$(dirname "$FILE")/active" ]; then
          deny "the armed contract .loop/criteria.tsv (loop is active)"
        fi ;;
      */.loop/criteria.sha256|.loop/criteria.sha256)
        # The hash-lock: writing it to match a weakened criteria.tsv would defeat
        # run-contract's tamper check, so lock it while armed too — create as well
        # as overwrite (same reasoning as criteria.tsv above).
        if [ -e "$(dirname "$FILE")/active" ]; then
          deny "the armed contract hash-lock .loop/criteria.sha256 (loop is active)"
        fi ;;
    esac
    ;;
  Bash)
    # results.json + evidence/ are the machine ledger: always protected.
    if printf '%s' "$CMD" | grep -qE '(>>?|\btee\b|\bmv\b|\bcp\b|\bsed\b[^|;&]*-i|\btruncate\b|\brm\b)[^|;&]*\.loop/(results\.json|evidence/)'; then
      deny "a Bash command writing to the .loop evidence ledger"
    fi
    # criteria.tsv + its hash-lock are locked only while the loop is armed
    # (.loop/active in cwd — Bash commands run in the project cwd, so the
    # cwd-relative check suffices). This regex is best-effort (see header): the
    # real integrity guarantee is run-contract's hash re-derivation, which no
    # Bash verb can slip past.
    if [ -e .loop/active ] && printf '%s' "$CMD" | grep -qE '(>>?|\btee\b|\bmv\b|\bcp\b|\bsed\b[^|;&]*-i|\btruncate\b|\brm\b)[^|;&]*\.loop/criteria\.(tsv|sha256)'; then
      deny "a Bash command writing to the armed contract .loop/criteria.tsv or its hash-lock"
    fi
    ;;
esac

exit 0
