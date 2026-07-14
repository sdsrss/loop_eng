#!/usr/bin/env bash
# update-notify.sh — SessionStart update NOTIFIER. Everything is sandboxed:
# a fake CLAUDE_PLUGIN_ROOT (with a plugin.json we write), a fake XDG_CACHE_HOME
# for the throttle state file, and a fake `curl` on PATH that emits canned
# releases JSON while incrementing a counter file. NO real network, NO real
# ~/.cache or ~/.claude writes. The hook must fail OPEN on every error path and
# never touch the network more than once per 24h.
set -u
. "$(dirname "$0")/lib.sh"

HOOK="$PLUGIN_ROOT/hooks/update-notify.sh"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/loop-eng-notify.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# --- fake plugin root: installed version 1.2.3 -------------------------------
PROOT="$WORK/plugin"
mkdir -p "$PROOT/.claude-plugin"
printf '{\n  "name": "loop-eng",\n  "version": "1.2.3",\n  "license": "MIT"\n}\n' \
  > "$PROOT/.claude-plugin/plugin.json"

# --- fake curl on PATH: emits {"tag_name":"v$STUB_TAG"} + bumps a counter -----
BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
# ignore all args; record the call, emit a canned GitHub releases body
printf 'x' >> "$STUB_COUNT"
printf '{"url":"x","tag_name":"v%s","name":"loop-eng %s"}\n' "$STUB_TAG" "$STUB_TAG"
EOF
chmod +x "$BIN/curl"

# --- a PATH with the real coreutils but NO curl (for the "curl missing" case) -
NOBIN="$WORK/nocurl"
mkdir -p "$NOBIN"
for c in bash sh env grep sed head date mkdir cat rm printf ln; do
  p=$(command -v "$c" 2>/dev/null) && ln -sf "$p" "$NOBIN/$c"
done

STUB_COUNT="$WORK/curl-count"

# A sandbox HOME so the "never writes into ~/.claude" guarantee is checkable
# without depending on where the test's TMPDIR happens to live (in some hosts
# TMPDIR itself sits under the real ~/.claude/tmp).
FHOME="$WORK/home"
mkdir -p "$FHOME"

# run_hook <cache_dir> <stub_tag> <use_nocurl:0|1>  -> stdout=notice, sets RC
run_hook() {
  local cache="$1" tag="$2" nocurl="$3" path
  if [ "$nocurl" = "1" ]; then path="$NOBIN"; else path="$BIN:$PATH"; fi
  CLAUDE_PLUGIN_ROOT="$PROOT" XDG_CACHE_HOME="$cache" HOME="$FHOME" \
    STUB_TAG="$tag" STUB_COUNT="$STUB_COUNT" PATH="$path" \
    bash "$HOOK" </dev/null 2>"$WORK/err"
}

count_calls() { [ -f "$STUB_COUNT" ] && wc -c < "$STUB_COUNT" | tr -d ' ' || echo 0; }

# json_ok <string>: 1 if valid single-line JSON with SessionStart, else 0
json_ok() {
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$1" | python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print("0"); sys.exit(0)
print("1" if d.get("hookSpecificOutput",{}).get("hookEventName")=="SessionStart" else "0")'
  elif command -v jq >/dev/null 2>&1; then
    printf '%s' "$1" | jq -e '.hookSpecificOutput.hookEventName=="SessionStart"' >/dev/null 2>&1 \
      && echo 1 || echo 0
  else
    echo SKIP
  fi
}

# ============================================================================
# 1. latest > installed  ->  notice with both versions, valid SessionStart JSON
# ============================================================================
C1="$WORK/cache1"; : > "$STUB_COUNT"
out=$(run_hook "$C1" 1.3.0 0); rc=$?
assert_eq 0 "$rc" "case1: hook exits 0"
printf '%s' "$out" > "$WORK/out1"
assert_file_contains "$WORK/out1" '"hookEventName":"SessionStart"' "case1: envelope names SessionStart"
assert_file_contains "$WORK/out1" 'update available: v1.3.0' "case1: notice cites latest v1.3.0"
assert_file_contains "$WORK/out1" 'installed v1.2.3' "case1: notice cites installed v1.2.3"
assert_file_contains "$WORK/out1" '/plugin update loop-eng' "case1: notice tells user how to update"
assert_eq 1 "$(printf '%s\n' "$out" | grep -c .)" "case1: envelope is a single line"
jok=$(json_ok "$out")
case "$jok" in SKIP) assert_eq 1 1 "case1: JSON validity SKIP (no jq/python3)" ;; *) assert_eq 1 "$jok" "case1: output is valid JSON w/ SessionStart" ;; esac

# ============================================================================
# 2. latest == installed  ->  no notice, exit 0
# ============================================================================
C2="$WORK/cache2"; : > "$STUB_COUNT"
out=$(run_hook "$C2" 1.2.3 0); rc=$?
assert_eq 0 "$rc" "case2: hook exits 0"
assert_eq "" "$out" "case2: up-to-date emits no notice"

# ============================================================================
# 3. latest < installed  ->  no notice, exit 0
# ============================================================================
C3="$WORK/cache3"; : > "$STUB_COUNT"
out=$(run_hook "$C3" 1.2.0 0); rc=$?
assert_eq 0 "$rc" "case3: hook exits 0"
assert_eq "" "$out" "case3: older remote emits no notice"

# ============================================================================
# 4. curl missing (PATH without curl)  ->  no notice, exit 0, no error output
# ============================================================================
C4="$WORK/cache4"; : > "$STUB_COUNT"
out=$(run_hook "$C4" 1.3.0 1); rc=$?
assert_eq 0 "$rc" "case4: hook exits 0 with curl absent"
assert_eq "" "$out" "case4: no curl -> no notice (fail-open)"
assert_eq "" "$(cat "$WORK/err")" "case4: no curl -> no error on stderr"
assert_eq 0 "$(count_calls)" "case4: network stub never invoked when curl absent"

# ============================================================================
# 5. THROTTLE: a second immediate run must NOT hit the network again.
#    Proof A: the curl counter stays at 1 across two runs.
#    Proof B: with the stub REMOVED, the cached notice still appears.
#    Also: the state file lives under XDG_CACHE_HOME, never under ~/.claude.
# ============================================================================
C5="$WORK/cache5"; : > "$STUB_COUNT"
out1=$(run_hook "$C5" 1.3.0 0); rc=$?
assert_eq 0 "$rc" "case5: first run exits 0"
assert_file_contains <(printf '%s' "$out1") 'update available: v1.3.0' "case5: first run shows the notice"
assert_eq 1 "$(count_calls)" "case5: first run made exactly one network call"

STATE="$C5/loop-eng/update-check.json"
assert_eq yes "$([ -f "$STATE" ] && echo yes || echo no)" "case5: state file written under XDG_CACHE_HOME"
# The hook must NEVER write into ~/.claude — with a sandbox HOME, that dir must
# not even exist after the run.
assert_eq no "$([ -e "$FHOME/.claude" ] && echo yes || echo no)" "case5: hook created nothing under ~/.claude"
assert_file_contains "$STATE" '"latest":"1.3.0"' "case5: state file caches the latest version"

# second immediate run — network must be skipped (counter unchanged)
out2=$(run_hook "$C5" 1.3.0 0); rc=$?
assert_eq 0 "$rc" "case5: second run exits 0"
assert_eq 1 "$(count_calls)" "case5: THROTTLE — second run did NOT call the network (counter still 1)"
assert_file_contains <(printf '%s' "$out2") 'update available: v1.3.0' "case5: second run reuses the cached notice"

# Proof B: remove the stub entirely; a throttled run still emits the cached notice
rm -f "$BIN/curl"
out3=$(run_hook "$C5" 1.3.0 0); rc=$?
assert_eq 0 "$rc" "case5: throttled run with stub removed exits 0"
assert_file_contains <(printf '%s' "$out3") 'update available: v1.3.0' "case5: cached notice survives with no curl reachable (network truly skipped)"

report "test-update-notify"
