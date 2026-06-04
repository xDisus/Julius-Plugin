#!/usr/bin/env bash
# large-file-guard.sh — PreToolUse hook on Read
# Blocks Read of large files, suggests caveman-reader agent instead.
# Exit 2 = block. Stdout = feedback to model.
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${CLAUDE_PLUGIN_DATA:-$(pwd)/.claude/julius}"

# Read tier
TIER_FILE="$STATE_DIR/active-tier"
[ -f "$TIER_FILE" ] || exit 0
TIER=$(cat "$TIER_FILE")
CONFIG="$PLUGIN_ROOT/lib/tier-config.json"
ENABLED=$(jq -r ".\"$TIER\".subagent_reader.enabled // false" "$CONFIG" 2>/dev/null)
[ "$ENABLED" = "true" ] || exit 0

THRESHOLD=$(jq -r ".\"$TIER\".subagent_reader.threshold_lines // 999999" "$CONFIG" 2>/dev/null)

# Get file path from hook env
FILE_PATH="${CLAUDE_HOOK_TOOL_ARGS:-}"
if [ -z "$FILE_PATH" ]; then
  FILE_PATH=$(cat 2>/dev/null || echo "")
fi

# If we can't determine the file, let it pass
[ -n "$FILE_PATH" ] || exit 0

# Try to extract path from various formats
# Common: "path/to/file.py" or {"file_path": "..."}
CLEAN_PATH=$(echo "$FILE_PATH" | jq -r '.file_path // .path // .file // .target // empty' 2>/dev/null || echo "$FILE_PATH" | tr -d '"' | xargs)

# Still no path? try first word
if [ -z "$CLEAN_PATH" ]; then
  CLEAN_PATH=$(echo "$FILE_PATH" | awk '{print $1}' | tr -d '"')
fi

[ -n "$CLEAN_PATH" ] || exit 0

# Check file size
if [ -f "$CLEAN_PATH" ]; then
  LINES=$(wc -l < "$CLEAN_PATH" 2>/dev/null | tr -d ' ')
elif [ -f "$(pwd)/$CLEAN_PATH" ]; then
  LINES=$(wc -l < "$(pwd)/$CLEAN_PATH" 2>/dev/null | tr -d ' ')
  CLEAN_PATH="$(pwd)/$CLEAN_PATH"
else
  # Can't find file, let it pass
  exit 0
fi

# Skip if within threshold or couldn't count lines
[ -n "$LINES" ] && [ "$LINES" -gt "$THRESHOLD" ] 2>/dev/null || exit 0

# Block the Read and redirect to caveman-reader agent
cat << BLOCK
[JULIUS] File '$CLEAN_PATH' has $LINES lines (threshold: $THRESHOLD).
Instead of reading it directly, delegate to the **caveman-reader** agent.
It will return a structured summary with: structure, notable lines, and edit targets.

Usage: delegate this task to caveman-reader agent:
"Read and summarize $CLEAN_PATH. Return JSON with: summary, structure, notable, edit_targets"
BLOCK

exit 2
