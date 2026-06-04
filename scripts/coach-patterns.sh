#!/usr/bin/env bash
# coach-patterns.sh — PreToolUse hook on Bash: advisory cheap-pattern coaching.
# Nudges away from token-wasteful shell habits toward the targeted built-in tools.
# Advisory only: always exit 0 (never blocks). At most one nudge per call.
#
# PreToolUse stdin is JSON: {tool_name, tool_input:{command}, agent_id?}.
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../lib/julius-common.sh
source "$PLUGIN_ROOT/lib/julius-common.sh"

TIER=$(julius_tier) || exit 0
[ "$(julius_config "$TIER" .coaching.cheap_patterns false)" = "true" ] || exit 0

INPUT=$(julius_stdin)
[ -n "$INPUT" ] || exit 0
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$CMD" ] || exit 0

# Skip heredocs (cat <<EOF) — that's input authoring, not file dumping.
echo "$CMD" | grep -qE 'cat[[:space:]]*<<' && exit 0

# `cat <file>` (a real path arg, not a flag, not bare stdin) is the wasteful pattern.
echo "$CMD" | grep -qE '(^|[;&|])[[:space:]]*cat[[:space:]]+[^-[:space:]]' || exit 0

if echo "$CMD" | grep -qE 'cat[[:space:]]+[^|]*\|[[:space:]]*grep'; then
  MSG="[JULIUS] 'cat … | grep' loads the whole file into context. Use the Grep tool directly — it returns only matches."
else
  MSG="[JULIUS] 'cat <file>' loads the whole file into context. Use the Read tool (with offset/limit for large files) or Grep to target what you need."
fi

jq -n --arg ctx "$MSG" '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $ctx}}'
exit 0
