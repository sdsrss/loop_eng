#!/usr/bin/env bash
# hooks.json: JSON validity + structural contract. A single slipped comma here
# silently kills the ENTIRE enforcement layer (Claude Code skips a hooks.json
# it cannot parse, and an unregistered gate never denies anything) — exactly
# the blind spot the live-install smoke (audit H2) has not yet covered.
set -u
. "$(dirname "$0")/lib.sh"

HOOKS_JSON="$PLUGIN_ROOT/hooks/hooks.json"

# Pick a JSON reader: jq or python3 (same tolerance as evidence-gate itself).
# $2 defaults to hooks.json so every existing call site reads unchanged; the
# README-agreement section at the bottom passes the snippet it extracted.
json_get() { # $1 = jq-style path expression, $2 = file -> value or "MISSING"
  if command -v jq >/dev/null 2>&1; then
    jq -r "$1 // \"MISSING\"" "${2:-$HOOKS_JSON}" 2>/dev/null || echo BROKEN
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$1" "${2:-$HOOKS_JSON}" <<'EOF'
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

json_len() { # $1 = jq-style path to an array, $2 = file -> count (0 if absent/not-a-list)
  if command -v jq >/dev/null 2>&1; then
    jq -r "$1 | length" "${2:-$HOOKS_JSON}" 2>/dev/null || echo 0
  else
    python3 - "$1" "${2:-$HOOKS_JSON}" <<'EOF'
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

# --- SessionStart: EVERY block runs update-notify.sh via CLAUDE_PLUGIN_ROOT
# with a sane timeout. This is the fail-open update NOTIFIER; an unregistered or
# mis-pathed block simply means the user is never told about a new version, so
# assert the wiring the same way the enforcement gates are asserted. ---
ss_n=$(json_len '.hooks.SessionStart')
case "$ss_n" in *[!0-9]*|"") ss_n=0 ;; esac
if [ "$ss_n" -ge 1 ]; then
  assert_eq 1 1 "hooks.SessionStart has at least one block (found $ss_n)"
else
  assert_eq "1+ SessionStart blocks" "$ss_n" "hooks.SessionStart has at least one block"
fi
i=0
while [ "$i" -lt "$ss_n" ]; do
  entry_n=$(json_len ".hooks.SessionStart[$i].hooks")
  case "$entry_n" in *[!0-9]*|"") entry_n=0 ;; esac
  if [ "$entry_n" -ge 1 ]; then
    assert_eq 1 1 "SessionStart[$i] has at least one hook entry (found $entry_n)"
  else
    assert_eq "1+ hook entries" "$entry_n" "SessionStart[$i] has at least one hook entry"
  fi
  j=0
  while [ "$j" -lt "$entry_n" ]; do
    assert_eq command "$(json_get ".hooks.SessionStart[$i].hooks[$j].type")" "SessionStart[$i].hooks[$j] is type=command"
    ss_cmd=$(json_get ".hooks.SessionStart[$i].hooks[$j].command")
    case "$ss_cmd" in
      *update-notify.sh*) assert_eq 1 1 "SessionStart[$i].hooks[$j] command points at update-notify.sh" ;;
      *) assert_eq "update-notify.sh" "$ss_cmd" "SessionStart[$i].hooks[$j] command points at update-notify.sh" ;;
    esac
    case "$ss_cmd" in
      *'${CLAUDE_PLUGIN_ROOT}'*) assert_eq 1 1 "SessionStart[$i].hooks[$j] command resolves via CLAUDE_PLUGIN_ROOT" ;;
      *) assert_eq "plugin-root-path" "$ss_cmd" "SessionStart[$i].hooks[$j] command resolves via CLAUDE_PLUGIN_ROOT" ;;
    esac
    ss_to=$(json_get ".hooks.SessionStart[$i].hooks[$j].timeout")
    if [ -n "$ss_to" ] && [ "$ss_to" -ge 1 ] 2>/dev/null && [ "$ss_to" -le 60 ] 2>/dev/null; then
      assert_eq 1 1 "SessionStart[$i].hooks[$j] has a sane timeout ($ss_to s)"
    else
      assert_eq "sane-timeout" "timeout=$ss_to" "SessionStart[$i].hooks[$j] must have a sane timeout"
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

# --- the README's manual-registration snippet must agree with hooks.json ---
# README documents a SECOND registration site ("if your Claude Code version
# does not auto-load plugin hooks, register manually"), and its PreToolUse
# matcher is a hand-copied duplicate of the one asserted above. Nothing kept
# the two equal: add a write tool to hooks.json's matcher and the registration
# the project tells users to paste silently under-matches — a weaker gate on a
# documented path, which is the same hand-written-roster shape that let
# update-notify.sh go unsynced by scripts/sync-local.sh. Every expectation
# below is DERIVED from hooks.json rather than restated here.
#
# What this gate deliberately does NOT cover:
#   (a) that Claude Code honours the snippet at all — that is the platform's
#       contract, exercised only by the live-install smoke in RELEASING.md;
#   (b) the SessionStart update-notify hook. The snippet omits it on purpose:
#       it is a fail-open notifier, not part of the enforcement layer, and the
#       README says so in prose rather than leaving it a silent gap;
#   (c) timeouts. Stop/PreToolUse carry explicit ones in hooks.json; the
#       snippet omits them and inherits the platform default for a command
#       hook (600s per the hooks docs), which is already above stop-gate's own
#       LOOP_ENG_GATE_TIMEOUT budget — so the omission is safe, not a second
#       copy that has to be kept in sync.
README_MD="$PLUGIN_ROOT/README.md"
README_JSON=$(mktemp "${TMPDIR:-/tmp}/loop-eng-readme-hooks.XXXXXX")
trap 'rm -f "$README_JSON"' EXIT
awk '/^```json$/{n++; if(n==1){f=1; next}} f&&/^```$/{exit} f' "$README_MD" > "$README_JSON"

if [ "$(json_get '.hooks' "$README_JSON")" = "BROKEN" ]; then
  assert_eq "valid-json" "broken-json" "the README manual-registration snippet parses as JSON"
else
  assert_eq 0 0 "the README manual-registration snippet parses as JSON"
fi

assert_eq "$(json_get '.hooks.PreToolUse[0].matcher')" \
          "$(json_get '.hooks.PreToolUse[0].matcher' "$README_JSON")" \
          "README PreToolUse matcher is byte-equal to the one in hooks.json"

for ev in Stop PreToolUse; do
  want=$(json_get ".hooks.${ev}[0].hooks[0].command" | sed 's|.*/||; s|".*||')
  got=$(json_get ".hooks.${ev}[0].hooks[0].command" "$README_JSON")
  case "$got" in
    *"$want"*) assert_eq 1 1 "README $ev registers $want (script name derived from hooks.json)" ;;
    *) assert_eq "$want" "$got" "README $ev registers $want (script name derived from hooks.json)" ;;
  esac
done

report "test-hooks-json"
