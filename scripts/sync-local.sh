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

# Dogfood parity check: the hooks must be REGISTERED, not just copied — a synced
# but unregistered hook means this repo dogfoods only part of the enforcement
# layer (audit 2026-07-14, finding N1: evidence-gate had zero live mileage).
for h in stop-gate.sh evidence-gate.sh; do
  if ! grep -q "$h" .claude/settings.json 2>/dev/null; then
    echo "WARNING: .claude/settings.json does not register $h — dogfood enforcement is incomplete. See README 'register manually' example." >&2
  fi
done
