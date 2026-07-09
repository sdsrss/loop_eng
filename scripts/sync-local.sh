#!/usr/bin/env bash
# Sync the canonical plugin source (repo root) into .claude/ for local
# dogfooding in THIS repo without installing the plugin.
# Direction: root -> .claude/ (root is canonical; edit root, then sync).
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p .claude/commands .claude/agents .claude/hooks .claude/skills
cp commands/*.md .claude/commands/
cp agents/*.md .claude/agents/
cp hooks/stop-gate.sh .claude/hooks/
rm -rf .claude/skills/loop-eng
cp -r skills/loop-eng .claude/skills/loop-eng
chmod +x .claude/hooks/stop-gate.sh .claude/skills/loop-eng/scripts/unattended-polish.sh
echo "synced root -> .claude/ (settings.json left untouched)"
