#!/usr/bin/env bash
# turn-coach.sh — Stop hook: advisory efficiency coaching.
# Stop stdin is JSON: {transcript_path, stop_reason, ...} — NOT the response text.
# We read the last assistant message from the transcript jsonl and flag wasteful
# preamble. Advisory only: always exit 0 (exit 2 would force the model to keep going).
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../lib/julius-common.sh
source "$PLUGIN_ROOT/lib/julius-common.sh"

TIER=$(julius_tier) || exit 0
[ "$(julius_config "$TIER" .coach.enabled false)" = "true" ] || exit 0
MAX_PREAMBLE_WORDS=$(julius_config "$TIER" .coach.max_preamble_words 40)
CHECK_PARALLEL=$(julius_config "$TIER" .coach.check_parallel_tools false)

INPUT=$(julius_stdin)
[ -n "$INPUT" ] || exit 0
julius_is_json "$INPUT" || exit 0
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0

# Last assistant turn.
LAST=$(grep '"type":"assistant"' "$TRANSCRIPT" 2>/dev/null | tail -1)
[ -n "$LAST" ] || exit 0

# Text content and tool-call count from that turn (jq, not regex on prose).
TEXT=$(echo "$LAST" | jq -r '[.message.content[]? | select(.type=="text") | .text] | join(" ")' 2>/dev/null)
TOOLS=$(echo "$LAST" | jq -r '[.message.content[]? | select(.type=="tool_use")] | length' 2>/dev/null)
[ -n "$TOOLS" ] || TOOLS=0

VIOLATIONS=()

# Preamble: planning prose in front of action. Only matters when the turn also acted.
if [ "$TOOLS" -gt 0 ] 2>/dev/null && [ -n "$TEXT" ]; then
  TEXT_WORDS=$(printf '%s' "$TEXT" | wc -w | tr -d ' ')
  PLANNING=$( { printf '%s' "$TEXT" | grep -oiE "(I'?ll|I am going to|I'?m going to|let me|first I|I need to|I think|let'?s start)" 2>/dev/null || true; } | wc -l | tr -d ' ')
  if [ "$TEXT_WORDS" -gt "$MAX_PREAMBLE_WORDS" ] 2>/dev/null && [ "$PLANNING" -gt 0 ] 2>/dev/null; then
    VIOLATIONS+=("preamble:${TEXT_WORDS} words of prose alongside ${TOOLS} tool calls — lead with action, cut planning narration")
  fi
fi

# Parallelism: several recent turns each doing a single read = should have been batched.
if [ "$CHECK_PARALLEL" = "true" ]; then
  SINGLE_READS=$( { grep '"type":"assistant"' "$TRANSCRIPT" 2>/dev/null || true; } | tail -4 | while IFS= read -r line; do
    n=$(echo "$line" | jq -r '[.message.content[]? | select(.type=="tool_use") | select(.name=="Read" or .name=="Grep")] | length' 2>/dev/null || echo 0)
    t=$(echo "$line" | jq -r '[.message.content[]? | select(.type=="tool_use")] | length' 2>/dev/null || echo 0)
    { [ "${n:-0}" = "1" ] && [ "${t:-0}" = "1" ] && echo x; } || true
  done | wc -l | tr -d ' ')
  [ "${SINGLE_READS:-0}" -ge 3 ] 2>/dev/null && VIOLATIONS+=("parallel:${SINGLE_READS} recent turns each did a single Read/Grep — batch independent reads in one turn")
fi

[ ${#VIOLATIONS[@]} -gt 0 ] || exit 0

MSG="[JULIUS COACH]"
for v in "${VIOLATIONS[@]}"; do
  case "${v%%:*}" in
    preamble) MSG="$MSG"$'\n'"  📝 ${v#*:}" ;;
    parallel) MSG="$MSG"$'\n'"  ⚡ ${v#*:}" ;;
    *)        MSG="$MSG"$'\n'"  • ${v#*:}" ;;
  esac
done

# Stop does not support additionalContext — emit plain stdout (shown in transcript).
echo "$MSG"
exit 0
