#!/usr/bin/env bash
# compress-output.sh — PostToolUse hook (matcher: Bash|Read|Grep|Glob).
# Deterministic-first compression of large tool output, replacing it via updatedToolOutput.
#
# Contract facts (docs/claude-code/hooks):
#   - PostToolUse stdin is JSON: {tool_name, tool_input, tool_response, ...}
#   - Plain stdout becomes additionalContext (ADDS tokens) — useless for our goal.
#   - Only hookSpecificOutput.updatedToolOutput REPLACES what the model sees.
#   - A wrong-shape updatedToolOutput is silently ignored → original is used.
#   - tool_response shape: Bash = object {stdout,stderr,interrupted,isImage};
#     Read/Grep/Glob = string. updatedToolOutput is an object for Bash, a string for
#     the others. Wrong shape no-ops safely (live-verify only; never loses data).
#
# Pipeline: extract → dedup (exact in-session repeat → back-reference) → deterministic
# compress → (Bash+Beast only) flash semantic fallback. Any failure → emit nothing →
# original output preserved (no data loss).
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
LIST_CAP=$(julius_config "$TIER" .compress_output.list_cap 40)
FLASH_FALLBACK=$(julius_config "$TIER" .compress_output.flash_fallback_lines 999999)
DEDUP_ENABLED=$(julius_config "$TIER" .compress_output.dedup.enabled false)
DEDUP_MIN=$(julius_config "$TIER" .compress_output.dedup.min_lines 10)
DEDUP_MAX=$(julius_config "$TIER" .compress_output.dedup.max_entries 50)

INPUT=$(julius_stdin)
[ -n "$INPUT" ] || exit 0
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)

# --- Extract per-tool: RAW text, LABEL, SHAPE (object|string), MODE (lines|list|skip) ---
RAW=""; LABEL=""; SHAPE="string"; MODE="lines"; STDERR=""
case "$TOOL" in
  Bash)
    RAW=$(echo "$INPUT" | jq -r 'if (.tool_response|type)=="object" then (.tool_response.stdout // "") else (.tool_response // "") end' 2>/dev/null)
    STDERR=$(echo "$INPUT" | jq -r 'if (.tool_response|type)=="object" then (.tool_response.stderr // "") else "" end' 2>/dev/null)
    LABEL=$(echo "$INPUT" | jq -r '.tool_input.command // "command"' 2>/dev/null | head -c 60)
    SHAPE="object"; MODE="lines" ;;
  Read)
    RAW=$(echo "$INPUT" | jq -r 'if (.tool_response|type)=="string" then .tool_response else (.tool_response.stdout // (.tool_response|tostring)) end' 2>/dev/null)
    LABEL=$(echo "$INPUT" | jq -r '.tool_input.file_path // "file"' 2>/dev/null)
    SHAPE="string"; MODE="lines" ;;
  Glob)
    RAW=$(echo "$INPUT" | jq -r 'if (.tool_response|type)=="string" then .tool_response else (.tool_response|tostring) end' 2>/dev/null)
    LABEL=$(echo "$INPUT" | jq -r '.tool_input.pattern // "glob"' 2>/dev/null)
    SHAPE="string"; MODE="list" ;;
  Grep)
    RAW=$(echo "$INPUT" | jq -r 'if (.tool_response|type)=="string" then .tool_response else (.tool_response|tostring) end' 2>/dev/null)
    LABEL=$(echo "$INPUT" | jq -r '.tool_input.pattern // "grep"' 2>/dev/null)
    SHAPE="string"
    case "$(echo "$INPUT" | jq -r '.tool_input.output_mode // "files_with_matches"' 2>/dev/null)" in
      count) MODE="skip" ;;
      files_with_matches) MODE="list" ;;
      *) MODE="lines" ;;
    esac ;;
  *) exit 0 ;;
esac
[ -n "$RAW" ] || exit 0
[ "$MODE" = "skip" ] && exit 0
LINES=$(printf '%s\n' "$RAW" | wc -l | tr -d ' ')

# Emit helpers --------------------------------------------------------------
emit() {  # emit <text> <note>
  if [ "$SHAPE" = "object" ]; then
    jq -n --arg out "$1" --arg err "$STDERR" --arg note "$2" '{
      hookSpecificOutput: { hookEventName: "PostToolUse",
        additionalContext: ("[JULIUS] Bash stdout compressed (" + $note + "); errors/paths preserved."),
        updatedToolOutput: { stdout: $out, stderr: $err, interrupted: false, isImage: false } } }'
  else
    jq -n --arg out "$1" --arg note "$2" '{
      hookSpecificOutput: { hookEventName: "PostToolUse",
        additionalContext: ("[JULIUS] output compressed (" + $note + "); paths/matches preserved."),
        updatedToolOutput: $out } }'
  fi
}

# --- Dedup: exact in-session repeat → back-reference (before spending compression) ---
if [ "$DEDUP_ENABLED" = "true" ] && [ "$LINES" -ge "$DEDUP_MIN" ] 2>/dev/null; then
  if PREV=$(julius_dedup "$RAW" "$LABEL" "$DEDUP_MAX"); then
    emit "[same as earlier output of $PREV]" "dedup"
    exit 0
  fi
fi

# --- Compression ---
case "$MODE" in
  list)
    [ "$LINES" -gt "$LIST_CAP" ] 2>/dev/null || exit 0
    RESULT=$(printf '%s\n' "$RAW" | jc_cap_list "$LIST_CAP")
    emit "$RESULT" "deterministic"
    ;;
  lines)
    [ "$LINES" -gt "$THRESHOLD" ] 2>/dev/null || exit 0
    RESULT=$(printf '%s\n' "$RAW" | jc_compress "$HEAD" "$TAIL")
    RLINES=$(printf '%s\n' "$RESULT" | wc -l | tr -d ' ')
    NOTE="deterministic"
    if [ "$SHAPE" = "object" ] && [ "$TIER" = "beast" ] && [ "$RLINES" -gt "$FLASH_FALLBACK" ] 2>/dev/null && [ -x "$FLASH" ]; then
      PROMPT="Compress this command stdout. Keep ALL errors, stack traces, file paths and line numbers verbatim. Drop progress bars, repeated headers, verbose info/debug logs. Summarize long pass/fail lists as counts. Return ONLY the compressed text."
      FRES=$(printf '%s\n\n--- stdout ---\n%s' "$PROMPT" "$RESULT" \
        | JULIUS_FLASH_MAX_TOKENS="${JULIUS_FLASH_MAX_TOKENS:-700}" "$FLASH" 2>/dev/null) || FRES=""
      if [ -n "$FRES" ] && [ "${FRES#ERROR}" = "$FRES" ]; then
        FLINES=$(printf '%s\n' "$FRES" | wc -l | tr -d ' ')
        if [ "$FLINES" -lt "$RLINES" ] 2>/dev/null; then RESULT="$FRES"; RLINES="$FLINES"; NOTE="deterministic+flash"; fi
      fi
    fi
    [ "$RLINES" -lt "$LINES" ] 2>/dev/null || exit 0
    emit "$RESULT" "$NOTE"
    ;;
esac
exit 0
