#!/usr/bin/env bash
# compress-output.sh — PostToolUse hook (matcher: Bash).
# Replaces large Bash stdout with a flash-compressed summary via updatedToolOutput.
#
# Contract facts this relies on (docs/claude-code/hooks):
#   - PostToolUse stdin is JSON: {tool_name, tool_input, tool_response, ...}
#   - Plain stdout becomes additionalContext (ADDS tokens) — useless for our goal.
#   - Only hookSpecificOutput.updatedToolOutput REPLACES what the model sees.
#   - A wrong-shape updatedToolOutput is silently ignored → original is used.
# So we only handle Bash (known output shape {stdout,stderr,interrupted,isImage}).
# Any failure path emits nothing and exits 0 → original output is preserved (no data loss).
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../lib/julius-common.sh
source "$PLUGIN_ROOT/lib/julius-common.sh"
FLASH="${JULIUS_FLASH_BIN:-$PLUGIN_ROOT/scripts/flash-client.sh}"

TIER=$(julius_tier) || exit 0
[ "$(julius_config "$TIER" .compress_output.enabled false)" = "true" ] || exit 0
THRESHOLD=$(julius_config "$TIER" .compress_output.threshold_lines 999999)

INPUT=$(julius_stdin)
[ -n "$INPUT" ] || exit 0

# Only Bash has a stable, replaceable output shape. Everything else: leave untouched.
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[ "$TOOL" = "Bash" ] || exit 0

# Bash tool_response may be an object or a plain string depending on version.
STDOUT=$(echo "$INPUT" | jq -r 'if (.tool_response|type)=="object" then (.tool_response.stdout // "") else (.tool_response // "") end' 2>/dev/null)
STDERR=$(echo "$INPUT" | jq -r 'if (.tool_response|type)=="object" then (.tool_response.stderr // "") else "" end' 2>/dev/null)
[ -n "$STDOUT" ] || exit 0

LINES=$(printf '%s\n' "$STDOUT" | wc -l | tr -d ' ')
[ "$LINES" -gt "$THRESHOLD" ] 2>/dev/null || exit 0
[ -x "$FLASH" ] || exit 0

PROMPT="Compress this command stdout. Keep ALL errors, stack traces, file paths and line numbers verbatim. Drop progress bars, ANSI codes, repeated headers, verbose info/debug logs. Summarize long pass/fail lists as counts. Return ONLY the compressed text."

COMPRESSED=$(printf '%s\n\n--- stdout (%s lines) ---\n%s' "$PROMPT" "$LINES" "$STDOUT" \
  | JULIUS_FLASH_MAX_TOKENS="${JULIUS_FLASH_MAX_TOKENS:-700}" "$FLASH" 2>/dev/null) || COMPRESSED=""

# No usable result → emit nothing, original output stays. Never emit a filtered subset.
[ -n "$COMPRESSED" ] && [ "${COMPRESSED#ERROR}" = "$COMPRESSED" ] || exit 0

# Only replace if we actually shrank it.
NEWLINES=$(printf '%s\n' "$COMPRESSED" | wc -l | tr -d ' ')
[ "$NEWLINES" -lt "$LINES" ] 2>/dev/null || exit 0

jq -n --arg out "$COMPRESSED" --arg err "$STDERR" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: "[JULIUS] Bash stdout compressed by flash; errors/paths preserved.",
    updatedToolOutput: { stdout: $out, stderr: $err, interrupted: false, isImage: false }
  }
}'
exit 0
