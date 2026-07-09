#!/usr/bin/env bash
# unattended-autoloop: fresh-session-per-item, commit-keyed circuit breaker,
# auth env requirement, dirty-tree refusal. Uses a stub claude.
set -u
. "$(dirname "$0")/lib.sh"

DRIVER="$PLUGIN_ROOT/skills/loop-eng/scripts/unattended-autoloop.sh"
SD=$(mktemp -d "${TMPDIR:-/tmp}/loop-eng-stub.XXXXXX")

mk_stub() { # $1 = stub dir OUTSIDE any sandbox repo (untracked stub inside
            #      the repo would trip the driver's dirty-tree refusal)
  cat > "$1/stub-claude" <<'EOF'
#!/usr/bin/env bash
# stub claude: "progress" marks the first backlog item done and commits;
# "stall" produces no commit. Runs inside the repo cwd set by the driver.
case "${STUB_MODE:-progress}" in
  progress)
    sed -i.bak '0,/^- \[ \]/s//- [x]/' .loop/backlog.md && rm -f .loop/backlog.md.bak
    echo "done one item" > "progress-$(date +%s%N).txt"
    git add -A >/dev/null
    git commit -qm "stub: item done"
    echo "ALL GREEN"
    ;;
  stall)
    echo "no progress made"
    ;;
esac
exit 0
EOF
  chmod +x "$1/stub-claude"
}

mk_stub "$SD"
STUB="$SD/stub-claude"

# --- refuses without LOOP_ENG_ALLOW_AUTOBUILD=1 ---
SB=$(mk_sandbox_repo); trap 'rm -rf "$SB" "$SD"' EXIT
mkdir -p "$SB/.loop"
printf -- '- [ ] item A\n' > "$SB/.loop/backlog.md"
LOOP_ENG_CLAUDE_BIN="$STUB" bash "$DRIVER" "$SB" 2>/dev/null && rc=0 || rc=$?
assert_eq 1 "$rc" "refuses without AUTOBUILD env"

# --- happy path: consumes backlog, one session per item, exits 0 ---
printf -- '- [ ] item A\n- [ ] item B\n' > "$SB/.loop/backlog.md"
STUB_MODE=progress LOOP_ENG_ALLOW_AUTOBUILD=1 LOOP_ENG_CLAUDE_BIN="$STUB" \
  bash "$DRIVER" "$SB" 5 >/dev/null 2>&1
assert_eq 0 $? "happy path exits 0"
assert_eq 0 "$(grep -c '^- \[ \]' "$SB/.loop/backlog.md")" "backlog fully consumed"
assert_file_contains "$SB/.loop/unattended.log" "backlog empty" "logs completion"

# --- circuit breaker: stall stub -> stops after exactly 2 sessions ---
SB2=$(mk_sandbox_repo); trap 'rm -rf "$SB" "$SB2" "$SD"' EXIT
mkdir -p "$SB2/.loop"
printf -- '- [ ] never done\n' > "$SB2/.loop/backlog.md"
STUB_MODE=stall LOOP_ENG_ALLOW_AUTOBUILD=1 LOOP_ENG_CLAUDE_BIN="$STUB" \
  bash "$DRIVER" "$SB2" 5 >/dev/null 2>&1
assert_eq 0 $? "breaker stop is a clean exit"
assert_file_contains "$SB2/.loop/unattended.log" "circuit breaker OPEN" "breaker logged"
assert_eq 2 "$(grep -c 'session .* starting' "$SB2/.loop/unattended.log")" "exactly 2 sessions before breaker"

# --- dirty tree refusal ---
echo dirty > "$SB2/untracked-src.txt"
STUB_MODE=stall LOOP_ENG_ALLOW_AUTOBUILD=1 LOOP_ENG_CLAUDE_BIN="$STUB" \
  bash "$DRIVER" "$SB2" 5 >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq 1 "$rc" "dirty tree refused"

report "test-unattended-autoloop"
