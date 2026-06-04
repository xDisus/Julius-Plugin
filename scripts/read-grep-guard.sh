#!/usr/bin/env bash
# read-grep-guard.sh — PreToolUse hook on Read: prevention via advisory nudge.
# When a Read has no offset/limit on a medium-size file, suggest paginating so the
# whole file never enters context. Advisory only: always exit 0 (never blocks).
# Coexists with large-file-guard.sh, which BLOCKS the genuinely large reads — this
# hook handles the band below that block threshold.
#
# PreToolUse stdin is JSON: {tool_name, tool_input:{file_path,offset,limit}, agent_id?}.
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../lib/julius-common.sh
source "$PLUGIN_ROOT/lib/julius-common.sh"

TIER=$(julius_tier) || exit 0
[ "$(julius_config "$TIER" .prevention.enabled false)" = "true" ] || exit 0
NUDGE=$(julius_config "$TIER" .prevention.read_nudge_lines 100)

INPUT=$(julius_stdin)
[ -n "$INPUT" ] || exit 0
julius_is_json "$INPUT" || exit 0

# Don't nudge inside subagents (the reader agent reads freely).
[ -z "$(echo "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null)" ] || exit 0

# Already paginated? Nothing to suggest.
HAS_RANGE=$(echo "$INPUT" | jq -r 'if (.tool_input.offset // .tool_input.limit) then "yes" else "no" end' 2>/dev/null)
[ "$HAS_RANGE" = "no" ] || exit 0

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)
[ -n "$FILE_PATH" ] || exit 0
if [ ! -f "$FILE_PATH" ] && [ -f "$(pwd)/$FILE_PATH" ]; then FILE_PATH="$(pwd)/$FILE_PATH"; fi
[ -f "$FILE_PATH" ] || exit 0

LINES=$(wc -l < "$FILE_PATH" 2>/dev/null | tr -d ' ')
[ -n "$LINES" ] && [ "$LINES" -gt "$NUDGE" ] 2>/dev/null || exit 0

# Upper bound: above the block threshold, large-file-guard takes over — don't double-handle.
if [ "$(julius_config "$TIER" .subagent_reader.enabled false)" = "true" ]; then
  BLOCK=$(julius_config "$TIER" .subagent_reader.threshold_lines 999999)
  [ "$LINES" -le "$BLOCK" ] 2>/dev/null || exit 0
fi

jq -n --arg ctx "[JULIUS] '$FILE_PATH' is $LINES lines. Consider reading a targeted range (offset/limit) or using Grep to locate what you need, instead of loading the whole file." \
  '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $ctx}}'
exit 0
