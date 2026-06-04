#!/usr/bin/env bash
# batch-synthesizer.sh — PostToolBatch hook.
# Fires once per parallel tool batch. stdin is JSON: {tool_calls:[{tool_name,tool_input,tool_response},...]}.
# Cross-references the outputs via flash and injects a synthesis via additionalContext.
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../lib/julius-common.sh
source "$PLUGIN_ROOT/lib/julius-common.sh"
FLASH="${JULIUS_FLASH_BIN:-$PLUGIN_ROOT/scripts/flash-client.sh}"

TIER=$(julius_tier) || exit 0
[ "$(julius_config "$TIER" .batch_synthesis.enabled false)" = "true" ] || exit 0
MIN_BATCH=$(julius_config "$TIER" .batch_synthesis.min_batch_size 2)

INPUT=$(julius_stdin)
[ -n "$INPUT" ] || exit 0

BATCH_SIZE=$(echo "$INPUT" | jq -r '(.tool_calls | length) // 0' 2>/dev/null)
[ "$BATCH_SIZE" -ge "$MIN_BATCH" ] 2>/dev/null || exit 0
[ -x "$FLASH" ] || exit 0

# Flatten the batch into a compact, labelled text blob for the synthesizer.
BLOB=$(echo "$INPUT" | jq -r '
  .tool_calls[]
  | "### \(.tool_name) \((.tool_input.file_path // .tool_input.command // "") )\n"
    + (if (.tool_response|type)=="string" then .tool_response
       else (.tool_response.stdout // (.tool_response|tostring)) end)' 2>/dev/null)
[ -n "$BLOB" ] || exit 0

PROMPT="You received ${BATCH_SIZE} parallel tool outputs. Return a dense synthesis, one fact per line:
[BATCH SYNTHESIS]
• cross-refs (X imports/references Y)
• shared entities (class/type/fn in multiple outputs)
• architecture in one line
• notable issues / duplication / gaps
Drop all framing.

--- outputs ---
$BLOB"

RESULT=$(printf '%s' "$PROMPT" | JULIUS_FLASH_MAX_TOKENS=400 "$FLASH" 2>/dev/null) || RESULT=""
[ -n "$RESULT" ] && [ "${RESULT#ERROR}" = "$RESULT" ] || exit 0

jq -n --arg ctx "$RESULT" '{hookSpecificOutput: {hookEventName: "PostToolBatch", additionalContext: $ctx}}'
exit 0
