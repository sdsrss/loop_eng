#!/usr/bin/env bash
# sync-local.sh: root -> .claude/ sync fidelity + parity warning. Runs against
# a COPY of the plugin tree in a sandbox — never the real repo's .claude/.
# History: pre-v0.2.2 the sync silently omitted evidence-gate.sh; this suite
# is the regression fence for that class.
set -u
. "$(dirname "$0")/lib.sh"

SB=$(mktemp -d "${TMPDIR:-/tmp}/loop-eng-sync.XXXXXX")
trap 'rm -rf "$SB"' EXIT
SB=$(cd "$SB" && pwd) # macOS /var -> /private/var (see lib.sh mk_sandbox_repo)

# Stage a copy of the canonical source + the sync script itself, preserving the
# layout sync-local.sh expects (it cd's to its own parent's parent).
mkdir -p "$SB/scripts"
cp -r "$PLUGIN_ROOT/commands" "$PLUGIN_ROOT/agents" "$PLUGIN_ROOT/hooks" "$PLUGIN_ROOT/skills" "$SB/"
cp "$PLUGIN_ROOT/scripts/sync-local.sh" "$SB/scripts/"

# settings.json registering BOTH hooks -> the parity check must stay silent.
mkdir -p "$SB/.claude"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"x/stop-gate.sh"}]}],"PreToolUse":[{"hooks":[{"type":"command","command":"x/evidence-gate.sh"}]}]}}\n' \
  > "$SB/.claude/settings.json"
SETTINGS_BEFORE=$(cat "$SB/.claude/settings.json")

# --- sync succeeds ---
err=$(bash "$SB/scripts/sync-local.sh" 2>&1 >/dev/null); rc=$?
assert_eq 0 "$rc" "sync exits 0"

# --- every synced artifact is byte-identical to its source ---
drift=""
for f in "$SB"/commands/*.md; do
  diff -q "$f" "$SB/.claude/commands/$(basename "$f")" >/dev/null 2>&1 || drift="$drift $f"
done
for f in "$SB"/agents/*.md; do
  diff -q "$f" "$SB/.claude/agents/$(basename "$f")" >/dev/null 2>&1 || drift="$drift $f"
done
for f in stop-gate.sh evidence-gate.sh; do
  diff -q "$SB/hooks/$f" "$SB/.claude/hooks/$f" >/dev/null 2>&1 || drift="$drift hooks/$f"
done
assert_eq "" "$drift" "commands/agents/hooks synced byte-identical"
diff -rq "$SB/skills/loop-eng" "$SB/.claude/skills/loop-eng" >/dev/null 2>&1
assert_eq 0 $? "skills tree synced byte-identical"

# --- executables stay executable ---
xfail=""
for f in "$SB/.claude/hooks/stop-gate.sh" "$SB/.claude/hooks/evidence-gate.sh" \
         "$SB/.claude/skills/loop-eng/scripts/run-contract.sh"; do
  [ -x "$f" ] || xfail="$xfail $f"
done
assert_eq "" "$xfail" "synced scripts keep the executable bit"

# --- settings.json is never touched ---
assert_eq "$SETTINGS_BEFORE" "$(cat "$SB/.claude/settings.json")" "settings.json left untouched"

# --- parity check: both hooks registered -> silent ---
case "$err" in
  *WARNING*) assert_eq "silent" "warned: $err" "no parity warning when both hooks are registered" ;;
  *) assert_eq 1 1 "no parity warning when both hooks are registered" ;;
esac

# --- parity check: evidence-gate missing from settings -> loud warning ---
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"x/stop-gate.sh"}]}]}}\n' \
  > "$SB/.claude/settings.json"
err=$(bash "$SB/scripts/sync-local.sh" 2>&1 >/dev/null); rc=$?
assert_eq 0 "$rc" "sync still exits 0 with unregistered hook (warning, not error)"
case "$err" in
  *"does not register evidence-gate.sh"*) assert_eq 1 1 "warns about unregistered evidence-gate" ;;
  *) assert_eq "evidence-gate-warning" "missing: $err" "warns about unregistered evidence-gate" ;;
esac

# --- a source file edited after sync shows up as drift on re-diff (sanity) ---
echo "# drift" >> "$SB/hooks/evidence-gate.sh"
diff -q "$SB/hooks/evidence-gate.sh" "$SB/.claude/hooks/evidence-gate.sh" >/dev/null 2>&1 && drc=0 || drc=1
assert_eq 1 "$drc" "post-sync source edit is detectable as drift"
bash "$SB/scripts/sync-local.sh" >/dev/null 2>&1
diff -q "$SB/hooks/evidence-gate.sh" "$SB/.claude/hooks/evidence-gate.sh" >/dev/null 2>&1
assert_eq 0 $? "re-sync clears the drift"

report "test-sync-local"
