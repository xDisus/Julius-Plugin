#!/usr/bin/env bash
# turn-coach.sh — Post-turn efficiency analysis (Stop hook)
# Fires after each Claude response. Analyzes output for token waste.
# Stdout is injected as feedback to the model for next turn.
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${CLAUDE_PLUGIN_DATA:-$(pwd)/.claude/julius}"

# Read active tier
TIER_FILE="$STATE_DIR/active-tier"
if [ ! -f "$TIER_FILE" ]; then
  exit 0  # Julius not active
fi
TIER=$(cat "$TIER_FILE")

# Load tier config
CONFIG="$PLUGIN_ROOT/lib/tier-config.json"
if ! CONFIG_TIER=$(jq -e ".$TIER" "$CONFIG" 2>/dev/null); then
  exit 0
fi

# Check if coach is enabled for this tier
COACH_ENABLED=$(echo "$CONFIG_TIER" | jq -r '.coach.enabled // false')
if [ "$COACH_ENABLED" != "true" ]; then
  exit 0
fi

MAX_PREAMBLE=$(echo "$CONFIG_TIER" | jq -r '.coach.max_preamble_pct // 20')
CHECK_PARALLEL=$(echo "$CONFIG_TIER" | jq -r '.coach.check_parallel_tools // false')

# Read the response from stdin (if any)
RESPONSE=""
if [ ! -t 0 ]; then
  RESPONSE=$(cat)
fi

# If no response data, exit silently
if [ -z "$RESPONSE" ]; then
  exit 0
fi

VIOLATIONS=()

# Check 1: Preamble ratio
TOTAL_WORDS=$(echo "$RESPONSE" | wc -w | tr -d ' ')
PREAMBLE_WORDS=$(echo "$RESPONSE" | grep -oiE '\b(I.?ll|Let me|First|I need to|I.?m going to|Let\'?s start|I think)\b' | wc -l | tr -d ' ')

if [ "$TOTAL_WORDS" -gt 0 ] 2>/dev/null; then
  PREAMBLE_PCT=$((PREAMBLE_WORDS * 100 / TOTAL_WORDS))
else
  PREAMBLE_PCT=0
fi

if [ "$PREAMBLE_PCT" -gt "$MAX_PREAMBLE" ] 2>/dev/null; then
  # Check if response has tool calls or is just preamble
  TOOL_CALLS=$(echo "$RESPONSE" | grep -cE '(Read|Edit|Bash|Grep|Glob|Write|TaskCreate|TaskUpdate)')
  if [ "$TOOL_CALLS" -gt 0 ]; then
    VIOLATIONS+=("preamble:${PREAMBLE_PCT}% waste — use action verbs, not planning verbs")
  fi
fi

# Check 2: Sequential tool parallelism
if [ "$CHECK_PARALLEL" = "true" ]; then
  SEQ_TOOLS=$(echo "$RESPONSE" | grep -cE '(Read|Grep)', 2>/dev/null || true)
  if [ "$SEQ_TOOLS" -gt 3 ] 2>/dev/null; then
    VIOLATIONS+=("parallel:detected sequential tool calls — batch independent operations")
  fi
fi

# Build output
if [ ${#VIOLATIONS[@]} -gt 0 ]; then
  echo "[JULIUS COACH]"
  for v in "${VIOLATIONS[@]}"; do
    CATEGORY="${v%%:*}"
    MESSAGE="${v#*:}"
    case "$CATEGORY" in
      preamble)   echo "  📝 Preamble: $MESSAGE" ;;
      parallel)   echo "  ⚡ Parallel: $MESSAGE" ;;
      *)          echo "  • $MESSAGE" ;;
    esac
  done
fi

exit 0
