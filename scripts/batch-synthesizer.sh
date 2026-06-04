#!/usr/bin/env bash
# batch-synthesizer.sh — PostToolBatch hook
# Cross-references parallel tool outputs and produces a unified synthesis.
# Detects imports, shared entities, and relationships across files.
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${CLAUDE_PLUGIN_DATA:-$(pwd)/.claude/julius}"
FLASH="$PLUGIN_ROOT/scripts/flash-client.sh"

# Read tier
TIER_FILE="$STATE_DIR/active-tier"
[ -f "$TIER_FILE" ] || exit 0
TIER=$(cat "$TIER_FILE")
CONFIG="$PLUGIN_ROOT/lib/tier-config.json"
ENABLED=$(jq -r ".\"$TIER\".batch_synthesis.enabled // false" "$CONFIG" 2>/dev/null)
[ "$ENABLED" = "true" ] || exit 0

MIN_BATCH=$(jq -r ".\"$TIER\".batch_synthesis.min_batch_size // 2" "$CONFIG" 2>/dev/null)

# Read batch data from stdin
BATCH_DATA=""
if [ ! -t 0 ]; then
  BATCH_DATA=$(cat)
fi

[ -n "$BATCH_DATA" ] || exit 0

# Count batch size
BATCH_SIZE=$(echo "$BATCH_DATA" | jq -r '.calls | length // 1' 2>/dev/null || echo 1)

# Skip if batch is too small
[ "$BATCH_SIZE" -ge "$MIN_BATCH" ] 2>/dev/null || exit 0

# Check if flash is available
[ -x "$FLASH" ] || exit 0

# Build synthesis prompt
PROMPT="You received ${BATCH_SIZE} parallel tool outputs. Produce a unified synthesis.

Find and report:
1. CROSS-REFERENCES — files that import or reference each other
2. SHARED ENTITIES — classes, types, or functions mentioned in multiple outputs
3. STRUCTURE RELATIONSHIPS — how the pieces fit together architecturally
4. NOTABLE ITEMS — potential issues, duplications, or missing pieces

Return in this format:
[BATCH SYNTHESIS]
• X imports Y: details
• Entity Z shared by: A, B, C
• Architecture: short description
• Notable: item 1
• Notable: item 2

Drop all verbose framing. Be dense. One fact per line."

FULL_INPUT="$PROMPT

--- Batch of ${BATCH_SIZE} tool outputs ---
$BATCH_DATA"

# Call flash, fallback gracefully
RESULT=$(echo "$FULL_INPUT" | "$FLASH" 2>/dev/null) || RESULT=""

if [ -n "$RESULT" ] && [ "${RESULT#ERROR}" = "$RESULT" ] && [ "${RESULT#error}" = "$RESULT" ]; then
  echo ""
  echo "$RESULT"
fi

exit 0
