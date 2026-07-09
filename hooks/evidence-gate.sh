#!/usr/bin/env bash
# loop-eng evidence-gate — PreToolUse hook.
#
# .loop/results.json and .loop/evidence/ are machine-written by run-contract.sh;
# .loop/criteria.tsv is written once at contract time and fixed afterwards.
# This hook denies model writes to them (exit 2, stderr fed back to the model),
# so a "passes": true can never be typed into existence — only produced by the
# runner actually executing the contract's commands. Weakening the contract by
# rewriting criteria.tsv is likewise mechanically blocked, not just forbidden
# in prompt text.
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
  FILE=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || FILE=""
  CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || CMD=""
elif command -v python3 >/dev/null 2>&1; then
  PARSED=$(printf '%s' "$INPUT" | python3 -c '
import json, sys, shlex
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti = d.get("tool_input") or {}
print("TOOL=%s" % shlex.quote(str(d.get("tool_name", ""))))
print("FILE=%s" % shlex.quote(str(ti.get("file_path", ""))))
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
    echo ".loop/results.json and .loop/evidence/ are machine-written evidence:"
    echo "run 'bash .loop/verify.sh' or let the stop-gate execute the contract"
    echo "instead of writing claims. criteria.tsv is fixed once armed — weakening"
    echo "a check to pass it is a red line."
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
        if [ -f "$FILE" ]; then
          deny "the armed contract .loop/criteria.tsv (already exists)"
        fi ;;
    esac
    ;;
  Bash)
    if printf '%s' "$CMD" | grep -qE '(>>?|\btee\b|\bmv\b|\bcp\b|\bsed\b[^|;&]*-i|\btruncate\b|\brm\b)[^|;&]*\.loop/(results\.json|evidence/|criteria\.tsv)'; then
      deny "a Bash command writing to a gate-protected .loop path"
    fi
    ;;
esac

exit 0
