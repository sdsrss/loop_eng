#!/usr/bin/env bash
# hooks.json: JSON validity + structural contract. A single slipped comma here
# silently kills the ENTIRE enforcement layer (Claude Code skips a hooks.json
# it cannot parse, and an unregistered gate never denies anything) — exactly
# the blind spot the live-install smoke (audit H2) has not yet covered.
set -u
. "$(dirname "$0")/lib.sh"

HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"

# Pick a JSON reader: jq or python3 (same tolerance as evidence-gate itself).
json_get() { # $1 = jq-style path expression -> value or "MISSING"
  if command -v jq >/dev/null 2>&1; then
    jq -r "$1 // \"MISSING\"" "$HOOKS_JSON" 2>/dev/null || echo BROKEN
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$1" "$HOOKS_JSON" <<'EOF'
import json, sys
expr, path = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path))
except Exception:
    print("BROKEN"); sys.exit(0)
# supports the tiny subset of jq paths this test uses: .a.B[0].c[0].d
cur = d
for part in expr.lstrip(".").replace("]", "").split("."):
    for key in part.split("["):
        if key == "":
            continue
        try:
            cur = cur[int(key)] if key.isdigit() else cur[key]
        except Exception:
            print("MISSING"); sys.exit(0)
print(cur)
EOF
  else
    echo "SKIP"
  fi
}

if [ "$(json_get '.hooks')" = "SKIP" ]; then
  echo "  SKIP: neither jq nor python3 available — cannot validate hooks.json" >&2
  report "test-hooks-json"
  exit $?
fi

# --- the file parses at all ---
first=$(json_get '.hooks.Stop[0].hooks[0].type')
if [ "$first" = "BROKEN" ]; then
  assert_eq "valid-json" "broken-json" "hooks.json must parse as JSON"
else
  assert_eq command "$first" "Stop hook entry is type=command"
fi

# --- Stop: runs stop-gate.sh with a timeout above the gate's internal budget ---
stop_cmd=$(json_get '.hooks.Stop[0].hooks[0].command')
case "$stop_cmd" in
  *stop-gate.sh*) assert_eq 1 1 "Stop command points at stop-gate.sh" ;;
  *) assert_eq "stop-gate.sh" "$stop_cmd" "Stop command points at stop-gate.sh" ;;
esac
case "$stop_cmd" in
  *'${CLAUDE_PLUGIN_ROOT}'*) assert_eq 1 1 "Stop command resolves via CLAUDE_PLUGIN_ROOT" ;;
  *) assert_eq "plugin-root-path" "$stop_cmd" "Stop command resolves via CLAUDE_PLUGIN_ROOT" ;;
esac
stop_to=$(json_get '.hooks.Stop[0].hooks[0].timeout')
assert_eq 120 "$stop_to" "Stop timeout is 120s"
# stop-gate.sh runs the contract under LOOP_ENG_GATE_TIMEOUT (default 100s) and
# the comment contract in both files says the hook timeout must stay ABOVE it.
gate_budget=$(grep -oE 'LOOP_ENG_GATE_TIMEOUT:-[0-9]+' "$PLUGIN_ROOT/hooks/stop-gate.sh" | grep -oE '[0-9]+$' | head -1)
if [ -n "${gate_budget:-}" ] && [ "$stop_to" -gt "$gate_budget" ] 2>/dev/null; then
  assert_eq 1 1 "Stop timeout ($stop_to) stays above the gate's internal budget ($gate_budget)"
else
  assert_eq "timeout>budget" "timeout=$stop_to budget=${gate_budget:-unknown}" "Stop timeout must exceed the gate's internal budget"
fi

# --- PreToolUse: evidence-gate on every write-capable tool + Bash ---
ptu_matcher=$(json_get '.hooks.PreToolUse[0].matcher')
for tool in Write Edit MultiEdit NotebookEdit Bash; do
  case "$ptu_matcher" in
    *"$tool"*) assert_eq 1 1 "PreToolUse matcher covers $tool" ;;
    *) assert_eq "covers-$tool" "$ptu_matcher" "PreToolUse matcher covers $tool" ;;
  esac
done
ptu_cmd=$(json_get '.hooks.PreToolUse[0].hooks[0].command')
case "$ptu_cmd" in
  *evidence-gate.sh*) assert_eq 1 1 "PreToolUse command points at evidence-gate.sh" ;;
  *) assert_eq "evidence-gate.sh" "$ptu_cmd" "PreToolUse command points at evidence-gate.sh" ;;
esac
ptu_to=$(json_get '.hooks.PreToolUse[0].hooks[0].timeout')
assert_eq 30 "$ptu_to" "PreToolUse timeout is 30s"

report "test-hooks-json"
