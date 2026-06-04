#!/usr/bin/env bash
# smart-compact.sh — PreCompact hook: custom context compaction
# Blocks native compaction, provides decision-focused summary.
# Exit 2 = blocks compaction. Stdout = replacement context.
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${CLAUDE_PLUGIN_DATA:-$(pwd)/.claude/julius}"
FLASH="$PLUGIN_ROOT/scripts/flash-client.sh"

# Read tier
TIER_FILE="$STATE_DIR/active-tier"
[ -f "$TIER_FILE" ] || exit 0
TIER=$(cat "$TIER_FILE")
CONFIG="$PLUGIN_ROOT/lib/tier-config.json"
ENABLED=$(jq -r ".\"$TIER\".smart_compact.enabled // false" "$CONFIG" 2>/dev/null)
[ "$ENABLED" = "true" ] || exit 0

PRESERVE_LAST=$(jq -r ".\"$TIER\".smart_compact.preserve_last_turns // 15" "$CONFIG" 2>/dev/null)

# Read conversation data from stdin
CONVERSATION=""
if [ ! -t 0 ]; then
  CONVERSATION=$(cat)
fi

# Block native compaction regardless
# Simplify: inject context-preserving instruction
cat << 'INJECT'
[HISTORY NOTE] Previous context was compacted by Julius. The following was preserved:

INJECT

# If we have conversation data, summarize it
if [ -n "$CONVERSATION" ] && [ -x "$FLASH" ]; then
  # Try to extract decisions and facts from the conversation
  PROMPT="You are a lossy compressor for an AI agent's conversation history.
Read the conversation and extract ONLY:
1. KEY DECISIONS made (what was decided, not the discussion leading to it)
2. ERRORS FOUND and their fixes (file paths, line numbers)
3. FACTS DISCOVERED about the codebase
4. CURRENT TASK STATE (what is being worked on now)

Return in this format:
[DECISIONS]
- decision 1
- decision 2

[ERRORS FIXED]
- path:file:line — description

[FACTS]
- fact 1

[CURRENT]
What is being worked on right now

Drop all dialogue, verbose explanations, thinking, and irrelevant chatter."

  SUMMARY=$(echo "$PROMPT

--- Conversation to compress ---
$CONVERSATION" | "$FLASH" 2>/dev/null) || SUMMARY=""

  if [ -n "$SUMMARY" ]; then
    echo "$SUMMARY"
    exit 2
  fi
fi

# Fallback: simple instruction to the model
cat << 'FALLBACK'
If you need to re-establish context, use Glob + Grep to locate files and Read to load current state. The most recent interaction before compaction should be intact.
FALLBACK

exit 2
