#!/usr/bin/env bash
# Sync the canonical plugin source (repo root) into .claude/ for local
# dogfooding in THIS repo without installing the plugin.
# Direction: root -> .claude/ (root is canonical; edit root, then sync).
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p .claude/commands .claude/agents .claude/hooks .claude/skills
cp commands/*.md .claude/commands/
cp agents/*.md .claude/agents/
cp hooks/stop-gate.sh hooks/evidence-gate.sh .claude/hooks/
rm -rf .claude/skills/loop-eng
cp -r skills/loop-eng .claude/skills/loop-eng
chmod +x .claude/hooks/*.sh .claude/skills/loop-eng/scripts/*.sh
echo "synced root -> .claude/ (settings.json left untouched)"

# Cache-currency check: hooks load via the INSTALLED plugin's hooks.json
# auto-load, never via this repo's .claude/settings.json — so live enforcement
# runs whatever version sits in the plugin cache, no matter how fresh the repo
# is (audit 2026-07-14: the installed cache was two releases behind the repo).
# Warn-only; never fails the sync. Tests point LOOP_ENG_PLUGIN_CACHE_DIR at a
# fixture so they never touch the real ~/.claude/.
CACHE_ROOT="${LOOP_ENG_PLUGIN_CACHE_DIR:-$HOME/.claude/plugins}"
ver_of() { # manifest-path -> version string (machine-written JSON; no jq dep)
  sed -n 's/.*"version"[^"]*"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -1
}
repo_ver=$(ver_of .claude-plugin/plugin.json || true)
cache_dir=""
if [ -n "$repo_ver" ] && [ -d "$CACHE_ROOT/cache/loop-eng/loop-eng" ]; then
  cache_dir=$(find "$CACHE_ROOT/cache/loop-eng/loop-eng" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
fi
if [ -n "$cache_dir" ]; then
  cache_ver=$(ver_of "$cache_dir/.claude-plugin/plugin.json" || true)
  if [ -n "$cache_ver" ] && [ "$cache_ver" != "$repo_ver" ]; then
    echo "WARNING: installed plugin cache is $cache_ver but the repo is $repo_ver — live enforcement runs the CACHE until you run /plugin update (runtime tell: arm-contract's 'armed from' line cites the executing copy's path)." >&2
  fi
fi
