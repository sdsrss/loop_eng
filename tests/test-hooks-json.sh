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
# supports the tiny subset of jq paths this test uses: .a.B[i].c[j].d
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

json_len() { # $1 = jq-style path to an array -> element count (0 if absent/not-a-list)
  if command -v jq >/dev/null 2>&1; then
    jq -r "$1 | length" "$HOOKS_JSON" 2>/dev/null || echo 0
  else
    python3 - "$1" "$HOOKS_JSON" <<'EOF'
import json, sys
expr, path = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(path))
except Exception:
    print(0); sys.exit(0)
cur = d
for part in expr.lstrip(".").replace("]", "").split("."):
    for key in part.split("["):
        if key == "":
            continue
        try:
            cur = cur[int(key)] if key.isdigit() else cur[key]
        except Exception:
            print(0); sys.exit(0)
print(len(cur) if isinstance(cur, list) else 0)
EOF
  fi
}

if [ "$(json_get '.hooks')" = "SKIP" ]; then
  echo "  SKIP: neither jq nor python3 available — cannot validate hooks.json" >&2
  report "test-hooks-json"
  exit $?
fi

# --- the file parses at all ---
if [ "$(json_get '.hooks')" = "BROKEN" ]; then
  assert_eq "valid-json" "broken-json" "hooks.json must parse as JSON"
else
  assert_eq 0 0 "hooks.json parses as JSON"
fi

# stop-gate.sh runs the contract under LOOP_ENG_GATE_TIMEOUT (default 100s) and
# the comment contract in both files says the hook timeout must stay ABOVE it.
gate_budget=$(grep -oE 'LOOP_ENG_GATE_TIMEOUT:-[0-9]+' "$PLUGIN_ROOT/hooks/stop-gate.sh" | grep -oE '[0-9]+$' | head -1)

# --- Stop: EVERY block runs stop-gate.sh via CLAUDE_PLUGIN_ROOT with a timeout
# above the gate's internal budget. Loops over all blocks and each block's
# hooks array — a future second block cannot slip in unchecked.
stop_n=$(json_len '.hooks.Stop')
case "$stop_n" in *[!0-9]*|"") stop_n=0 ;; esac
if [ "$stop_n" -ge 1 ]; then
  assert_eq 1 1 "hooks.Stop has at least one block (found $stop_n)"
else
  assert_eq "1+ Stop blocks" "$stop_n" "hooks.Stop has at least one block"
fi
i=0
while [ "$i" -lt "$stop_n" ]; do
  entry_n=$(json_len ".hooks.Stop[$i].hooks")
  case "$entry_n" in *[!0-9]*|"") entry_n=0 ;; esac
  if [ "$entry_n" -ge 1 ]; then
    assert_eq 1 1 "Stop[$i] has at least one hook entry (found $entry_n)"
  else
    assert_eq "1+ hook entries" "$entry_n" "Stop[$i] has at least one hook entry"
  fi
  j=0
  while [ "$j" -lt "$entry_n" ]; do
    assert_eq command "$(json_get ".hooks.Stop[$i].hooks[$j].type")" "Stop[$i].hooks[$j] is type=command"
    stop_cmd=$(json_get ".hooks.Stop[$i].hooks[$j].command")
    case "$stop_cmd" in
      *stop-gate.sh*) assert_eq 1 1 "Stop[$i].hooks[$j] command points at stop-gate.sh" ;;
      *) assert_eq "stop-gate.sh" "$stop_cmd" "Stop[$i].hooks[$j] command points at stop-gate.sh" ;;
    esac
    case "$stop_cmd" in
      *'${CLAUDE_PLUGIN_ROOT}'*) assert_eq 1 1 "Stop[$i].hooks[$j] command resolves via CLAUDE_PLUGIN_ROOT" ;;
      *) assert_eq "plugin-root-path" "$stop_cmd" "Stop[$i].hooks[$j] command resolves via CLAUDE_PLUGIN_ROOT" ;;
    esac
    stop_to=$(json_get ".hooks.Stop[$i].hooks[$j].timeout")
    assert_eq 120 "$stop_to" "Stop[$i].hooks[$j] timeout is 120s"
    if [ -n "${gate_budget:-}" ] && [ "$stop_to" -gt "$gate_budget" ] 2>/dev/null; then
      assert_eq 1 1 "Stop[$i].hooks[$j] timeout ($stop_to) stays above the gate's internal budget ($gate_budget)"
    else
      assert_eq "timeout>budget" "timeout=$stop_to budget=${gate_budget:-unknown}" "Stop[$i].hooks[$j] timeout must exceed the gate's internal budget"
    fi
    j=$((j+1))
  done
  i=$((i+1))
done

# --- PreToolUse: EVERY block covers all write-capable tools + Bash and runs
# evidence-gate.sh via CLAUDE_PLUGIN_ROOT ---
ptu_n=$(json_len '.hooks.PreToolUse')
case "$ptu_n" in *[!0-9]*|"") ptu_n=0 ;; esac
if [ "$ptu_n" -ge 1 ]; then
  assert_eq 1 1 "hooks.PreToolUse has at least one block (found $ptu_n)"
else
  assert_eq "1+ PreToolUse blocks" "$ptu_n" "hooks.PreToolUse has at least one block"
fi
i=0
while [ "$i" -lt "$ptu_n" ]; do
  ptu_matcher=$(json_get ".hooks.PreToolUse[$i].matcher")
  for tool in Write Edit MultiEdit NotebookEdit Bash; do
    case "$ptu_matcher" in
      *"$tool"*) assert_eq 1 1 "PreToolUse[$i] matcher covers $tool" ;;
      *) assert_eq "covers-$tool" "$ptu_matcher" "PreToolUse[$i] matcher covers $tool" ;;
    esac
  done
  entry_n=$(json_len ".hooks.PreToolUse[$i].hooks")
  case "$entry_n" in *[!0-9]*|"") entry_n=0 ;; esac
  if [ "$entry_n" -ge 1 ]; then
    assert_eq 1 1 "PreToolUse[$i] has at least one hook entry (found $entry_n)"
  else
    assert_eq "1+ hook entries" "$entry_n" "PreToolUse[$i] has at least one hook entry"
  fi
  j=0
  while [ "$j" -lt "$entry_n" ]; do
    assert_eq command "$(json_get ".hooks.PreToolUse[$i].hooks[$j].type")" "PreToolUse[$i].hooks[$j] is type=command"
    ptu_cmd=$(json_get ".hooks.PreToolUse[$i].hooks[$j].command")
    case "$ptu_cmd" in
      *evidence-gate.sh*) assert_eq 1 1 "PreToolUse[$i].hooks[$j] command points at evidence-gate.sh" ;;
      *) assert_eq "evidence-gate.sh" "$ptu_cmd" "PreToolUse[$i].hooks[$j] command points at evidence-gate.sh" ;;
    esac
    case "$ptu_cmd" in
      *'${CLAUDE_PLUGIN_ROOT}'*) assert_eq 1 1 "PreToolUse[$i].hooks[$j] command resolves via CLAUDE_PLUGIN_ROOT" ;;
      *) assert_eq "plugin-root-path" "$ptu_cmd" "PreToolUse[$i].hooks[$j] command resolves via CLAUDE_PLUGIN_ROOT" ;;
    esac
    ptu_to=$(json_get ".hooks.PreToolUse[$i].hooks[$j].timeout")
    assert_eq 30 "$ptu_to" "PreToolUse[$i].hooks[$j] timeout is 30s"
    j=$((j+1))
  done
  i=$((i+1))
done

report "test-hooks-json"
