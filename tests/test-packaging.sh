#!/usr/bin/env bash
# packaging: what the README tells a user to RUN must actually be runnable from
# a fresh install.
#
# A marketplace install materializes the git tree with its recorded file modes,
# so a script the README documents as a bare-path command (`skills/.../x.sh …`,
# no `bash` prefix) must carry the exec bit IN THE INDEX — otherwise the very
# first thing a new user pastes answers "Permission denied", and no test in the
# suite sees it because every other suite invokes the scripts as `bash <path>`.
#
# The list is DERIVED from README.md rather than hardcoded: a runner documented
# tomorrow is covered tomorrow, without anyone remembering to extend this file.
set -u
. "$(dirname "$0")/lib.sh"

cd "$PLUGIN_ROOT"

# Bare-path invocations in README code fences: an optional ./ then a repo-relative
# *.sh at the start of a line. A line that starts with `bash ` is NOT a bare-path
# invocation and is deliberately not matched — those work at any mode.
DOCUMENTED=$(grep -oE '^(\./)?(skills|scripts)/[A-Za-z0-9_/.-]+\.sh' README.md | sed 's|^\./||' | sort -u)

# Fail closed on a regex that matched nothing: a silently empty candidate set
# would make every assertion below vacuous and this suite would report green
# while checking zero files.
count=$(printf '%s\n' "$DOCUMENTED" | grep -c '[^[:space:]]' || true)
if [ "$count" -eq 0 ]; then
  FAIL=$((FAIL+1))
  echo "  FAIL: README bare-path scan matched no scripts — the pattern has rotted" >&2
else
  PASS=$((PASS+1))
fi

for f in $DOCUMENTED; do
  if [ ! -f "$f" ]; then
    FAIL=$((FAIL+1)); echo "  FAIL: README documents $f but it does not exist" >&2
    continue
  fi
  # The mode that actually ships is the one git records, not the one the working
  # tree happens to have.
  mode=$(git ls-files -s -- "$f" | awk '{print $1}')
  assert_eq "100755" "$mode" "README runs '$f' bare-path, so it must ship executable"
  if [ -x "$f" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "  FAIL: $f is not executable in the working tree" >&2
  fi
done

# Conversely: a script the README only ever invokes via `bash <path>` needs no
# exec bit, and the hooks are always spawned as `bash "${CLAUDE_PLUGIN_ROOT}/..."`
# by hooks.json — assert that contract so nobody "fixes" the hook modes instead
# of the hooks.json command, which is what actually decides how they start.
while IFS= read -r hookcmd; do
  case "$hookcmd" in
    bash\ *) PASS=$((PASS+1)) ;;
    *) FAIL=$((FAIL+1)); echo "  FAIL: hooks.json command not spawned via bash: $hookcmd" >&2 ;;
  esac
done < <(grep -o '"command": "[^"]*"' hooks/hooks.json | sed 's/"command": "//; s/"$//')

report "test-packaging"
