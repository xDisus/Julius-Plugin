#!/usr/bin/env bash
# tier-setter.sh — Sets the active Julius tier
# Called by: commands/julius.md (via Claude Code executing the slash command)
# Writes to: .claude/julius/active-tier
set -euo pipefail

TIER="${1:-}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PLUGIN_DATA="${CLAUDE_PLUGIN_DATA:-.claude/julius}"
STATE_DIR="$(pwd)/${PLUGIN_DATA}"

# Validate tier
if [ -z "$TIER" ]; then
  echo "Usage: tier-setter.sh <normal|pro|beast>"
  exit 1
fi

case "$TIER" in
  normal|pro|beast) ;;
  *)
    echo "Error: Invalid tier '$TIER'. Must be: normal, pro, or beast."
    exit 1
    ;;
esac

# Verify config exists
CONFIG="$PLUGIN_ROOT/lib/tier-config.json"
if [ ! -f "$CONFIG" ]; then
  echo "Error: tier-config.json not found at $CONFIG" >&2
  exit 1
fi

# Validate JSON
if ! jq -e ".$TIER" "$CONFIG" >/dev/null 2>&1; then
  echo "Error: tier '$TIER' not found in tier-config.json" >&2
  exit 1
fi

# Create state directory
mkdir -p "$STATE_DIR"

# Write active tier
echo -n "$TIER" > "$STATE_DIR/active-tier"

echo "✅ Julius $TIER"
