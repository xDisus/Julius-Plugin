#!/usr/bin/env bash
# test-all.sh — Julius smoke tests
# Validates: config, scripts parse, hooks, tier switching
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0
FAIL=0

green() { echo -e "\033[32m✓ $1\033[0m"; PASS=$((PASS+1)); }
red()   { echo -e "\033[31m✗ $1\033[0m"; FAIL=$((FAIL+1)); }

echo "=== Julius Smoke Tests ==="
echo ""

# 1. plugin.json
echo "[plugin.json]"
if jq -e '.name == "julius"' "$ROOT/plugin.json" >/dev/null 2>&1; then
  green "Name is 'julius'"
else
  red "Missing or wrong name"
fi
if jq -e '.version' "$ROOT/plugin.json" >/dev/null 2>&1; then
  green "Has version"
else
  red "Missing version"
fi

# 2. tier-config.json
echo "[tier-config.json]"
for tier in normal pro beast; do
  if jq -e ".$tier" "$ROOT/lib/tier-config.json" >/dev/null 2>&1; then
    green "Tier '$tier' defined"
  else
    red "Tier '$tier' missing"
  fi
done

# 3. hooks.json
echo "[hooks.json]"
for hook in SessionStart UserPromptSubmit PreToolUse PostToolUse PostToolBatch PreCompact Stop TeammateIdle TaskCreated TaskCompleted; do
  if jq -e ".hooks.\"$hook\"" "$ROOT/hooks/hooks.json" >/dev/null 2>&1; then
    green "Hook '$hook' registered"
  else
    red "Hook '$hook' missing"
  fi
done

# 4. All scripts exist
echo "[scripts/]"
for script in flash-client.sh tier-setter.sh turn-coach.sh task-manifest.sh compress-output.sh smart-compact.sh large-file-guard.sh batch-synthesizer.sh docs-compressor.sh oracle-preprocess.sh keep-busy.sh; do
  if [ -f "$ROOT/scripts/$script" ]; then
    green "Script '$script' exists"
  else
    red "Script '$script' missing"
  fi
done

# 5. All agents exist
echo "[agents/]"
for agent in tier-router.md julius-reader.md julius-executor.md julius-researcher.md; do
  if [ -f "$ROOT/agents/$agent" ]; then
    green "Agent '$agent' exists"
  else
    red "Agent '$agent' missing"
  fi
done

# 6. Commands exist
echo "[commands/]"
if [ -f "$ROOT/commands/julius.md" ]; then
  green "Command 'julius.md' exists"
else
  red "Command 'julius.md' missing"
fi

# 7. Scripts are executable
echo "[executability]"
for script in "$ROOT/scripts/"*.sh; do
  if [ -x "$script" ]; then
    green "$(basename "$script") executable"
  else
    red "$(basename "$script") NOT executable"
  fi
done

# 8. Marketplace
echo "[marketplace]"
if jq -e '.name == "julius-plugin"' "$ROOT/.claude-plugin/marketplace.json" >/dev/null 2>&1; then
  green "Marketplace name correct"
else
  red "Marketplace name wrong"
fi

# 9. package.json
echo "[package.json]"
if jq -e '.bin."julius-plugin" == "./bin/install.sh"' "$ROOT/package.json" >/dev/null 2>&1; then
  green "npm bin points to install.sh"
else
  red "npm bin missing or wrong"
fi

# 10. tier-setter.sh smoke test
echo "[tier-setter.sh]"
TMPDIR=$(mktemp -d)
pushd "$TMPDIR" >/dev/null
CLAUDE_PLUGIN_ROOT="$ROOT" CLAUDE_PLUGIN_DATA="$TMPDIR/.claude/julius" bash "$ROOT/scripts/tier-setter.sh" "pro" >/dev/null 2>&1
if [ -f "$TMPDIR/.claude/julius/active-tier" ] && [ "$(cat "$TMPDIR/.claude/julius/active-tier")" = "pro" ]; then
  green "tier-setter.sh writes tier correctly"
else
  red "tier-setter.sh failed"
fi
popd >/dev/null
rm -rf "$TMPDIR"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
