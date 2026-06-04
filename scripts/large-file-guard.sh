#!/usr/bin/env bash
# large-file-guard.sh — PreToolUse hook on Read.
# Blocks Read of large files and redirects to the julius-reader agent.
# PreToolUse stdin is JSON: {tool_name, tool_input:{file_path}, agent_id?, ...}.
# Exit 2 = block the tool call; stderr is shown to the model.
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../lib/julius-common.sh
source "$PLUGIN_ROOT/lib/julius-common.sh"

TIER=$(julius_tier) || exit 0
[ "$(julius_config "$TIER" .subagent_reader.enabled false)" = "true" ] || exit 0
THRESHOLD=$(julius_config "$TIER" .subagent_reader.threshold_lines 999999)

INPUT=$(julius_stdin)
[ -n "$INPUT" ] || exit 0
julius_is_json "$INPUT" || exit 0

# Never block reads issued from inside a subagent: the julius-reader agent itself
# uses Read, and blocking it would deadlock the redirect we are recommending.
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty' 2>/dev/null)
[ -z "$AGENT_ID" ] || exit 0

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)
[ -n "$FILE_PATH" ] || exit 0

# Resolve relative paths against cwd.
if [ ! -f "$FILE_PATH" ] && [ -f "$(pwd)/$FILE_PATH" ]; then
  FILE_PATH="$(pwd)/$FILE_PATH"
fi
[ -f "$FILE_PATH" ] || exit 0

LINES=$(wc -l < "$FILE_PATH" 2>/dev/null | tr -d ' ')
[ -n "$LINES" ] && [ "$LINES" -gt "$THRESHOLD" ] 2>/dev/null || exit 0

# Block and tell the model what to do instead (stderr is surfaced on exit 2).
cat >&2 << BLOCK
[JULIUS] '$FILE_PATH' has $LINES lines (threshold: $THRESHOLD).
Delegate to the julius-reader agent instead of reading it directly:
"Read and summarize $FILE_PATH. Return JSON: {summary, structure, notable, edit_targets}"
If you need exact bytes to Edit, read a targeted range with offset/limit.
BLOCK

exit 2
