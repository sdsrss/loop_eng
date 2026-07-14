#!/usr/bin/env bash
# sync-local.sh: root -> .claude/ sync fidelity + cache-currency warning. Runs
# against a COPY of the plugin tree in a sandbox — never the real repo's
# .claude/ or ~/.claude/ (every invocation pins LOOP_ENG_PLUGIN_CACHE_DIR to a
# sandbox fixture). History: pre-v0.2.2 the sync silently omitted
# evidence-gate.sh; this suite is the regression fence for that class.
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

# Pre-existing settings.json -> the sync must leave it byte-identical.
mkdir -p "$SB/.claude"
printf '{"comment":"dogfood settings — sync must never touch this file"}\n' \
  > "$SB/.claude/settings.json"
SETTINGS_BEFORE=$(cat "$SB/.claude/settings.json")

# Sandbox plugin manifest with a controlled version (the cache-currency check
# reads it); NEVER the real ~/.claude/ — every run pins LOOP_ENG_PLUGIN_CACHE_DIR.
mkdir -p "$SB/.claude-plugin"
printf '{\n  "name": "loop-eng",\n  "version": "0.9.0"\n}\n' > "$SB/.claude-plugin/plugin.json"
NO_CACHE="$SB/no-such-cache"

# --- sync succeeds ---
err=$(LOOP_ENG_PLUGIN_CACHE_DIR="$NO_CACHE" bash "$SB/scripts/sync-local.sh" 2>&1 >/dev/null); rc=$?
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

# --- cache-currency (c): cache dir absent -> silent, exit 0 (fresh clone) ---
case "$err" in
  *WARNING*) assert_eq "silent" "warned: $err" "no cache warning when cache dir is absent" ;;
  *) assert_eq 1 1 "no cache warning when cache dir is absent" ;;
esac

# --- cache-currency (a): stale cache -> warning names cache + repo versions ---
# Two version dirs; the HIGHEST by sort -V (0.8.0) differs from the repo (0.9.0).
STALE_CACHE="$SB/fixture-cache-stale"
for v in 0.5.0 0.8.0; do
  mkdir -p "$STALE_CACHE/cache/loop-eng/loop-eng/$v/.claude-plugin"
  printf '{\n  "name": "loop-eng",\n  "version": "%s"\n}\n' "$v" \
    > "$STALE_CACHE/cache/loop-eng/loop-eng/$v/.claude-plugin/plugin.json"
done
err=$(LOOP_ENG_PLUGIN_CACHE_DIR="$STALE_CACHE" bash "$SB/scripts/sync-local.sh" 2>&1 >/dev/null); rc=$?
assert_eq 0 "$rc" "sync still exits 0 on stale cache (warning, not error)"
case "$err" in
  *WARNING*) assert_eq 1 1 "stale cache triggers a warning" ;;
  *) assert_eq "cache-lag-warning" "missing: $err" "stale cache triggers a warning" ;;
esac
case "$err" in
  *0.8.0*) assert_eq 1 1 "warning cites the highest cache version (0.8.0)" ;;
  *) assert_eq "cites-0.8.0" "missing: $err" "warning cites the highest cache version (0.8.0)" ;;
esac
case "$err" in
  *0.9.0*) assert_eq 1 1 "warning cites the repo version (0.9.0)" ;;
  *) assert_eq "cites-0.9.0" "missing: $err" "warning cites the repo version (0.9.0)" ;;
esac
case "$err" in
  *0.5.0*) assert_eq "no-0.5.0" "cited lower version: $err" "sort -V picks the highest dir, not 0.5.0" ;;
  *) assert_eq 1 1 "sort -V picks the highest dir, not 0.5.0" ;;
esac

# --- cache-currency (b): highest cache version == repo version -> silent ---
CURRENT_CACHE="$SB/fixture-cache-current"
for v in 0.5.0 0.9.0; do
  mkdir -p "$CURRENT_CACHE/cache/loop-eng/loop-eng/$v/.claude-plugin"
  printf '{\n  "name": "loop-eng",\n  "version": "%s"\n}\n' "$v" \
    > "$CURRENT_CACHE/cache/loop-eng/loop-eng/$v/.claude-plugin/plugin.json"
done
err=$(LOOP_ENG_PLUGIN_CACHE_DIR="$CURRENT_CACHE" bash "$SB/scripts/sync-local.sh" 2>&1 >/dev/null); rc=$?
assert_eq 0 "$rc" "sync exits 0 with a current cache"
case "$err" in
  *WARNING*) assert_eq "silent" "warned: $err" "no warning when highest cache version matches the repo" ;;
  *) assert_eq 1 1 "no warning when highest cache version matches the repo" ;;
esac

# --- a source file edited after sync shows up as drift on re-diff (sanity) ---
echo "# drift" >> "$SB/hooks/evidence-gate.sh"
diff -q "$SB/hooks/evidence-gate.sh" "$SB/.claude/hooks/evidence-gate.sh" >/dev/null 2>&1 && drc=0 || drc=1
assert_eq 1 "$drc" "post-sync source edit is detectable as drift"
LOOP_ENG_PLUGIN_CACHE_DIR="$NO_CACHE" bash "$SB/scripts/sync-local.sh" >/dev/null 2>&1
diff -q "$SB/hooks/evidence-gate.sh" "$SB/.claude/hooks/evidence-gate.sh" >/dev/null 2>&1
assert_eq 0 $? "re-sync clears the drift"

report "test-sync-local"
