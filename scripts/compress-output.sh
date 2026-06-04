#!/usr/bin/env bash
# compress-output.sh — PostToolUse hook: summarizes large tool outputs
# Skips small outputs, calls flash-client for big ones.
# Preserves errors, stack traces, file paths, line numbers.
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${CLAUDE_PLUGIN_DATA:-$(pwd)/.claude/julius}"
FLASH="$PLUGIN_ROOT/scripts/flash-client.sh"

# Read tier
TIER_FILE="$STATE_DIR/active-tier"
[ -f "$TIER_FILE" ] || exit 0
TIER=$(cat "$TIER_FILE")
CONFIG="$PLUGIN_ROOT/lib/tier-config.json"
ENABLED=$(jq -r ".\"$TIER\".compress_output.enabled // false" "$CONFIG" 2>/dev/null)
[ "$ENABLED" = "true" ] || exit 0

THRESHOLD=$(jq -r ".\"$TIER\".compress_output.threshold_lines // 999999" "$CONFIG" 2>/dev/null)
PRESERVE_ERRORS=$(jq -r ".\"$TIER\".compress_output.preserve_errors // true" "$CONFIG" 2>/dev/null)
PRESERVE_STACKS=$(jq -r ".\"$TIER\".compress_output.preserve_stacktraces // true" "$CONFIG" 2>/dev/null)

# Read tool output from stdin
OUTPUT=""
if [ ! -t 0 ]; then
  OUTPUT=$(cat)
fi

[ -n "$OUTPUT" ] || exit 0

# Count lines
LINES=$(echo "$OUTPUT" | wc -l | tr -d ' ')
[ "$LINES" -gt "$THRESHOLD" ] || exit 0

# Check if flash client exists and is executable
[ -x "$FLASH" ] || { echo "$OUTPUT"; exit 0; }

# Build compression prompt
PROMPT="You are a compression assistant. Summarize the following tool output.
Rules:
- Keep ALL errors, stack traces, file paths, and line numbers intact
- Drop progress bars, ANSI codes, repeated headers, and decorative lines
- Drop verbose logs (info, debug) but keep warnings and errors intact
- Drop test pass/fail lists longer than 5 items — summarize as '15 passed, 3 failed'
- Drop file contents — report structure instead: 'File X: 3 classes, 5 functions'
- Keep anything with: ERROR, FATAL, Traceback, Warning, FAILED
- Return ONLY the compressed output, no explanations"

# Build full input
FULL_INPUT="$PROMPT

--- Output to compress ($LINES lines) ---
$OUTPUT"

# Call flash and output result, fallback to original on failure
RESULT=$(echo "$FULL_INPUT" | "$FLASH" 2>/dev/null) || RESULT=""
if [ -n "$RESULT" ] && [ "${RESULT#ERROR}" = "$RESULT" ]; then
  echo "$RESULT"
else
  # Fallback: just keep last N lines with errors
  echo "$OUTPUT" | grep -iE 'error|fail|traceback|warning|exception' | tail -20 2>/dev/null || echo "$OUTPUT" | tail -20
fi
