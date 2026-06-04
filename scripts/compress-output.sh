#!/usr/bin/env bash
# compress-output.sh — PostToolUse hook (matcher: Bash; widened to Read|Grep|Glob in U3).
# Deterministic-first compression of large tool output, replacing it via updatedToolOutput.
#
# Contract facts (docs/claude-code/hooks):
#   - PostToolUse stdin is JSON: {tool_name, tool_input, tool_response, ...}
#   - Plain stdout becomes additionalContext (ADDS tokens) — useless for our goal.
#   - Only hookSpecificOutput.updatedToolOutput REPLACES what the model sees.
#   - A wrong-shape updatedToolOutput is silently ignored → original is used.
#
# Mechanism order (the core reframe): deterministic local compression runs first and
# is the default at every tier. Flash is a Beast-only semantic fallback, fired only
# when deterministic output is still over budget. Any failure → emit nothing → original
# output preserved (no data loss).
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../lib/julius-common.sh
source "$PLUGIN_ROOT/lib/julius-common.sh"
# shellcheck source=../lib/julius-compress.sh
source "$PLUGIN_ROOT/lib/julius-compress.sh"
FLASH="${JULIUS_FLASH_BIN:-$PLUGIN_ROOT/scripts/flash-client.sh}"

TIER=$(julius_tier) || exit 0
[ "$(julius_config "$TIER" .compress_output.enabled false)" = "true" ] || exit 0
THRESHOLD=$(julius_config "$TIER" .compress_output.threshold_lines 999999)
HEAD=$(julius_config "$TIER" .compress_output.head_lines 20)
TAIL=$(julius_config "$TIER" .compress_output.tail_lines 20)
FLASH_FALLBACK=$(julius_config "$TIER" .compress_output.flash_fallback_lines 999999)

INPUT=$(julius_stdin)
[ -n "$INPUT" ] || exit 0

TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
[ "$TOOL" = "Bash" ] || exit 0

# Bash tool_response may be an object or a plain string depending on version.
STDOUT=$(echo "$INPUT" | jq -r 'if (.tool_response|type)=="object" then (.tool_response.stdout // "") else (.tool_response // "") end' 2>/dev/null)
STDERR=$(echo "$INPUT" | jq -r 'if (.tool_response|type)=="object" then (.tool_response.stderr // "") else "" end' 2>/dev/null)
[ -n "$STDOUT" ] || exit 0

LINES=$(printf '%s\n' "$STDOUT" | wc -l | tr -d ' ')
[ "$LINES" -gt "$THRESHOLD" ] 2>/dev/null || exit 0

# --- Deterministic pass (always, every tier, offline) ---
RESULT=$(printf '%s\n' "$STDOUT" | jc_compress "$HEAD" "$TAIL")
RLINES=$(printf '%s\n' "$RESULT" | wc -l | tr -d ' ')
NOTE="deterministic"

# --- Flash semantic fallback (Beast only, when still over budget) ---
if [ "$TIER" = "beast" ] && [ "$RLINES" -gt "$FLASH_FALLBACK" ] 2>/dev/null && [ -x "$FLASH" ]; then
  PROMPT="Compress this command stdout. Keep ALL errors, stack traces, file paths and line numbers verbatim. Drop progress bars, repeated headers, verbose info/debug logs. Summarize long pass/fail lists as counts. Return ONLY the compressed text."
  FRES=$(printf '%s\n\n--- stdout ---\n%s' "$PROMPT" "$RESULT" \
    | JULIUS_FLASH_MAX_TOKENS="${JULIUS_FLASH_MAX_TOKENS:-700}" "$FLASH" 2>/dev/null) || FRES=""
  if [ -n "$FRES" ] && [ "${FRES#ERROR}" = "$FRES" ]; then
    FLINES=$(printf '%s\n' "$FRES" | wc -l | tr -d ' ')
    if [ "$FLINES" -lt "$RLINES" ] 2>/dev/null; then RESULT="$FRES"; RLINES="$FLINES"; NOTE="deterministic+flash"; fi
  fi
fi

# Only replace if we actually shrank it; otherwise leave the original untouched.
[ "$RLINES" -lt "$LINES" ] 2>/dev/null || exit 0

jq -n --arg out "$RESULT" --arg err "$STDERR" --arg note "$NOTE" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: ("[JULIUS] Bash stdout compressed (" + $note + "); errors/paths preserved."),
    updatedToolOutput: { stdout: $out, stderr: $err, interrupted: false, isImage: false }
  }
}'
exit 0
