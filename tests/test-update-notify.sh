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
# STUB_CURL_MODE drives the failure paths the hook documents but nothing
# exercised: every run before this suite grew the modes below got a successful
# body, so `curl` failing, returning nothing, or returning a tag the hook cannot
# compare were three branches asserted only by reading them.
mk_curl() {
  cat > "$BIN/curl" <<'EOF'
#!/usr/bin/env bash
# ignore all args; record the call, then behave per STUB_CURL_MODE
printf 'x' >> "$STUB_COUNT"
case "${STUB_CURL_MODE:-ok}" in
  fail)  exit 7 ;;                       # curl(1)'s "failed to connect to host"
  empty) exit 0 ;;                       # 200 with nothing in the body
  *)     printf '{"url":"x","tag_name":"v%s","name":"loop-eng %s"}\n' "$STUB_TAG" "$STUB_TAG" ;;
esac
EOF
  chmod +x "$BIN/curl"
}
mk_curl

# --- a PATH with the real coreutils but NO curl (for the "curl missing" case) -
NOBIN="$WORK/nocurl"
mkdir -p "$NOBIN"
for c in bash sh env grep sed head date mkdir cat rm printf ln; do
  p=$(command -v "$c" 2>/dev/null) && ln -sf "$p" "$NOBIN/$c"
done

# WHICH bash runs the hook is load-bearing, because CI's macOS test-bash32 leg
# runs this suite through /bin/bash (3.2) to prove the hook works there. A `bash`
# resolved from PATH could be a 5.x build that happens to be installed, and the
# leg would then report a 3.2 claim it never tested. $BASH is the interpreter
# running THIS suite, so the hook is always checked under the bash the caller
# chose — including the NOBIN arm, whose symlink is overridden for the same reason.
SUITE_BASH="${BASH:-$(command -v bash)}"
ln -sf "$SUITE_BASH" "$NOBIN/bash"

STUB_COUNT="$WORK/curl-count"
# Set once here and flipped by the failure cases below. Deliberately a plain
# variable and not a `VAR=x out=$(...)` prefix: in `A=1 B=$(cmd)` both halves
# are assignments, so A persists for the whole suite instead of scoping to the
# command — which is how an `empty` stub mode leaked forward and turned three
# later, unrelated assertions red.
STUB_CURL_MODE=ok

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
    STUB_CURL_MODE="${STUB_CURL_MODE:-ok}" \
    "$SUITE_BASH" "$HOOK" </dev/null 2>"$WORK/err"
}

# Same, with CLAUDE_PLUGIN_ROOT under the caller's control (the "no manifest"
# arms) — the hook's very first guard, and one nothing reached.
run_hook_root() {
  local root="$1" cache="$2"
  CLAUDE_PLUGIN_ROOT="$root" XDG_CACHE_HOME="$cache" HOME="$FHOME" \
    STUB_TAG=9.9.9 STUB_COUNT="$STUB_COUNT" PATH="$BIN:$PATH" \
    "$SUITE_BASH" "$HOOK" </dev/null 2>"$WORK/err"
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

# Proof B: remove the stub entirely; a throttled run still emits the cached notice.
# The third argument selects the PATH: `1` is $NOBIN, the curl-free one. It used
# to be `0`, which is "$BIN:$PATH" — deleting the stub from $BIN then left the
# REAL /usr/bin/curl reachable, so the label below ("no curl reachable") was
# false and a throttle regression would have had this suite fetch
# api.github.com. Measured at the time: `before rm: $BIN/curl` →
# `after rm: /usr/bin/curl`. The suite's own "no real network" promise must not
# depend on the feature under test still working.
rm -f "$BIN/curl"
out3=$(run_hook "$C5" 1.3.0 1); rc=$?
assert_eq 0 "$rc" "case5: throttled run with stub removed exits 0"
assert_file_contains <(printf '%s' "$out3") 'update available: v1.3.0' "case5: cached notice survives with no curl reachable (network truly skipped)"

# ============================================================================
# 6. P2-3: a FAILED check must back off, not retry on every SessionStart.
#    `|| exit 0` sat above the state write, so an offline machine paid a 3s
#    curl at the start of every session, forever, and nothing recorded that it
#    had tried. The backoff window is 1h — short enough that a transient blip
#    does not cost a day of notices, long enough that a plane ride costs one
#    call rather than one per session.
# ============================================================================
mk_curl
C6="$WORK/cache6"; : > "$STUB_COUNT"
STUB_CURL_MODE=fail; out=$(run_hook "$C6" 1.3.0 0); rc=$?
assert_eq 0 "$rc" "case6: a failed curl still exits 0 (fail-open)"
assert_eq "" "$out" "case6: a failed curl emits no notice"
assert_eq 1 "$(count_calls)" "case6: the failed run made its one call"
STATE6="$C6/loop-eng/update-check.json"
assert_eq yes "$([ -f "$STATE6" ] && echo yes || echo no)" "case6: a failed check is RECORDED, not forgotten"
STUB_CURL_MODE=fail; out=$(run_hook "$C6" 1.3.0 0); rc=$?
assert_eq 0 "$rc" "case6: the next session exits 0"
assert_eq 1 "$(count_calls)" "case6: BACKOFF — the next session did not call the network again"

# An empty 200 body is the same class and took the same silent path.
C7="$WORK/cache7"; : > "$STUB_COUNT"
STUB_CURL_MODE=empty; out=$(run_hook "$C7" 1.3.0 0)
assert_eq "" "$out" "case7: an empty body emits no notice"
assert_eq 1 "$(count_calls)" "case7: the empty-body run made its one call"
STUB_CURL_MODE=empty; out=$(run_hook "$C7" 1.3.0 0)
assert_eq 1 "$(count_calls)" "case7: an empty body backs off like any other failed check"
STUB_CURL_MODE=ok

# ============================================================================
# 7. P3-2: a tag with a suffix (v1.3.0-rc1) is not comparable, and was dropped
#    without recording the attempt — so a mis-published pre-release meant a 3s
#    curl every session until someone noticed. Still no notice (telling anyone
#    "1.3.0 is available" when the release is 1.3.0-rc1 would be wrong), but the
#    attempt is now recorded.
# ============================================================================
C8="$WORK/cache8"; : > "$STUB_COUNT"
out=$(run_hook "$C8" 1.3.0-rc1 0); rc=$?
assert_eq 0 "$rc" "case8: a suffixed tag exits 0"
assert_eq "" "$out" "case8: a suffixed tag emits no notice"
assert_eq 1 "$(count_calls)" "case8: the suffixed-tag run made its one call"
out=$(run_hook "$C8" 1.3.0-rc1 0)
assert_eq 1 "$(count_calls)" "case8: BACKOFF — a suffixed tag is not re-fetched every session"

# ...and the backoff expires: an old failure stamp must not silence the check
# forever. Rewritten by hand rather than slept for — the window is the unit
# under test, not the clock.
printf '{"last_check":0,"latest":"","last_fail":%s}\n' "$(( $(date +%s) - 7200 ))" > "$C8/loop-eng/update-check.json"
out=$(run_hook "$C8" 1.4.0 0)
assert_eq 2 "$(count_calls)" "case8: an EXPIRED backoff lets the next session check again"
assert_file_contains <(printf '%s' "$out") 'update available: v1.4.0' "case8: and the recovered check notifies"

# ============================================================================
# 8. P3-7: the remaining unreached branches.
# ============================================================================
# A corrupt state file must not wedge the hook into permanent silence: every
# field is unreadable, so the run is treated as un-throttled and checks.
C9="$WORK/cache9"; : > "$STUB_COUNT"
mkdir -p "$C9/loop-eng"
printf 'not json at all {{{\n' > "$C9/loop-eng/update-check.json"
out=$(run_hook "$C9" 1.3.0 0); rc=$?
assert_eq 0 "$rc" "case9: a corrupt state file does not break the hook"
assert_eq 1 "$(count_calls)" "case9: a corrupt state file is treated as no state — the check runs"
assert_file_contains <(printf '%s' "$out") 'update available: v1.3.0' "case9: and the notice still appears"

# No CLAUDE_PLUGIN_ROOT (the hook's first guard) and a root with no manifest:
# silent, exit 0, and above all no network call.
: > "$STUB_COUNT"
out=$(run_hook_root "" "$WORK/cache10"); rc=$?
assert_eq 0 "$rc" "case10: unset CLAUDE_PLUGIN_ROOT exits 0"
assert_eq "" "$out" "case10: unset CLAUDE_PLUGIN_ROOT is silent"
assert_eq 0 "$(count_calls)" "case10: unset CLAUDE_PLUGIN_ROOT never reaches the network"
mkdir -p "$WORK/emptyroot"
out=$(run_hook_root "$WORK/emptyroot" "$WORK/cache11"); rc=$?
assert_eq 0 "$rc" "case11: a plugin root with no manifest exits 0"
assert_eq 0 "$(count_calls)" "case11: a missing manifest never reaches the network"

# A manifest whose version is unreadable is the same class one level in.
BADROOT="$WORK/badroot"; mkdir -p "$BADROOT/.claude-plugin"
printf '{"name":"loop-eng","version":"not-a-version"}\n' > "$BADROOT/.claude-plugin/plugin.json"
: > "$STUB_COUNT"
out=$(run_hook_root "$BADROOT" "$WORK/cache12"); rc=$?
assert_eq 0 "$rc" "case12: an unreadable installed version exits 0"
assert_eq 0 "$(count_calls)" "case12: nothing to compare against means no network call"

# Two-segment versions: ver_field defaults the missing patch to 0, so 1.3 must
# compare as 1.3.0 and beat the installed 1.2.3.
C13="$WORK/cache13"; : > "$STUB_COUNT"
out=$(run_hook "$C13" 1.3 0)
assert_file_contains <(printf '%s' "$out") 'update available: v1.3' "case13: a two-segment tag compares as <major>.<minor>.0"
C14="$WORK/cache14"; : > "$STUB_COUNT"
out=$(run_hook "$C14" 1.2 0)
assert_eq "" "$out" "case14: a two-segment tag BELOW the installed version stays silent"

# ============================================================================
# 9. HOME unset: the one env shape that broke the fail-open contract.
# ============================================================================
# The hook runs `set -u` and derives its cache dir from
# `${XDG_CACHE_HOME:-$HOME/.cache}`. Bash only evaluates that fallback when
# XDG_CACHE_HOME is unset or empty — so an UNSET HOME (not an empty one, which
# expands fine) made the line itself an unbound-variable fatal: exit 1 from a
# SessionStart hook whose header promises it "never exits nonzero — fail-open
# by construction". Every other case in this file sets both vars, which is why
# nothing reached it.
#
# Driven through the no-curl PATH on purpose: the hook returns at the
# `command -v curl` guard BEFORE any mkdir, so this case asserts the contract
# without creating a cache dir anywhere — including under `/` when the suite
# runs as root, which the documented bash-3.2 docker recipe does.
: > "$STUB_COUNT"
out=$(env -u HOME -u XDG_CACHE_HOME \
        CLAUDE_PLUGIN_ROOT="$PROOT" STUB_TAG=1.3.0 STUB_COUNT="$STUB_COUNT" \
        PATH="$NOBIN" "$SUITE_BASH" "$HOOK" </dev/null 2>"$WORK/err15"); rc=$?
assert_eq 0 "$rc" "case15: an UNSET HOME still exits 0 (fail-open contract)"
assert_eq "" "$out" "case15: and says nothing"
if grep -q 'unbound variable' "$WORK/err15" 2>/dev/null; then
  assert_eq "no unbound-variable fatal" "$(cat "$WORK/err15")" "case15: stderr carries no unbound-variable fatal"
else
  assert_eq 0 0 "case15: stderr carries no unbound-variable fatal"
fi

report "test-update-notify"
