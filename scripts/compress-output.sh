#!/usr/bin/env bash
# compress-output.sh — PostToolUse hook (matcher: Bash|Read).
# Deterministic-first compression of large tool output, replacing it via updatedToolOutput.
#
# Contract facts (docs/claude-code/hooks + live verification 2026-06-04):
#   - PostToolUse stdin is JSON: {tool_name, tool_input, tool_response, ...}
#   - Plain stdout becomes additionalContext (ADDS tokens) — useless for our goal.
#   - Only hookSpecificOutput.updatedToolOutput REPLACES what the model sees.
#   - A wrong-shape updatedToolOutput is silently ignored → original is used.
#   - tool_response shapes (live-verified): Bash = object {stdout,stderr,interrupted,
#     isImage}; Read = object {type, file:{content,filePath,numLines,...}}. updatedToolOutput
#     mirrors that shape. (Grep/Glob deferred — shapes unverified; not in the matcher.)
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
FLASH_FALLBACK=$(julius_config "$TIER" .compress_output.flash_fallback_lines 999999)
DEDUP_ENABLED=$(julius_config "$TIER" .compress_output.dedup.enabled false)
DEDUP_MIN=$(julius_config "$TIER" .compress_output.dedup.min_lines 10)
DEDUP_MAX=$(julius_config "$TIER" .compress_output.dedup.max_entries 50)

INPUT=$(julius_stdin)
[ -n "$INPUT" ] || exit 0
julius_is_json "$INPUT" || exit 0
TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

# Byte count of stdin string (token proxy = bytes/4, same basis as tests/benchmark.sh).
jc_bytes() { printf '%s' "$1" | wc -c | tr -d ' '; }

# --- Extract per-tool: RAW text, LABEL, SHAPE (object|read_object|string), STDERR ---
RAW=""; LABEL=""; SHAPE="string"; STDERR=""
case "$TOOL" in
  Bash)
    RAW=$(echo "$INPUT" | jq -r 'if (.tool_response|type)=="object" then (.tool_response.stdout // "") else (.tool_response // "") end' 2>/dev/null)
    STDERR=$(echo "$INPUT" | jq -r 'if (.tool_response|type)=="object" then (.tool_response.stderr // "") else "" end' 2>/dev/null)
    LABEL=$(echo "$INPUT" | jq -r '.tool_input.command // "command"' 2>/dev/null | head -c 60)
    SHAPE="object" ;;
  Read)
    LABEL=$(echo "$INPUT" | jq -r '.tool_input.file_path // "file"' 2>/dev/null)
    # Current CC: tool_response = {type:"text", file:{content,...}}. Older: a string.
    if [ "$(echo "$INPUT" | jq -r '.tool_response.file.content // empty' 2>/dev/null | head -c1)" != "" ]; then
      RAW=$(echo "$INPUT" | jq -r '.tool_response.file.content' 2>/dev/null)
      TR=$(echo "$INPUT" | jq -c '.tool_response' 2>/dev/null)
      SHAPE="read_object"
    else
      RAW=$(echo "$INPUT" | jq -r 'if (.tool_response|type)=="string" then .tool_response else (.tool_response|tostring) end' 2>/dev/null)
      SHAPE="string"
    fi ;;
  # Grep/Glob deferred: their live tool_response shapes are unverified. Read turned out
  # to be a structured object (not the documented string), so the string assumption for
  # Grep/Glob is untrustworthy. Re-enable once their shapes are captured from a real
  # session (see docs/plans deferred work). Until then they pass through untouched.
  *) exit 0 ;;
esac
[ -n "$RAW" ] || exit 0
LINES=$(printf '%s\n' "$RAW" | wc -l | tr -d ' ')

# Emit helpers --------------------------------------------------------------
emit() {  # emit <text> <note>
  case "$SHAPE" in
    object)
      jq -n --arg out "$1" --arg err "$STDERR" --arg note "$2" '{
        hookSpecificOutput: { hookEventName: "PostToolUse",
          additionalContext: ("[JULIUS] Bash stdout compressed (" + $note + "); errors/paths preserved."),
          updatedToolOutput: { stdout: $out, stderr: $err, interrupted: false, isImage: false } } }'
      ;;
    read_object)
      # Rebuild the Read object, swapping file.content and refreshing numLines.
      local nlines
      nlines=$(printf '%s\n' "$1" | wc -l | tr -d ' ')
      jq -n --argjson tr "$TR" --arg out "$1" --argjson nl "$nlines" --arg note "$2" '{
        hookSpecificOutput: { hookEventName: "PostToolUse",
          additionalContext: ("[JULIUS] Read content compressed (" + $note + "); paths preserved."),
          updatedToolOutput: ($tr | .file.content = $out | .file.numLines = $nl) } }'
      ;;
    *)
      jq -n --arg out "$1" --arg note "$2" '{
        hookSpecificOutput: { hookEventName: "PostToolUse",
          additionalContext: ("[JULIUS] output compressed (" + $note + "); paths/matches preserved."),
          updatedToolOutput: $out } }'
      ;;
  esac
}

# --- Dedup: exact in-session repeat → back-reference (before spending compression) ---
if [ "$DEDUP_ENABLED" = "true" ] && [ "$LINES" -ge "$DEDUP_MIN" ] 2>/dev/null; then
  if PREV=$(julius_dedup "$RAW" "$LABEL" "$DEDUP_MAX"); then
    BACKREF="[same as earlier output of $PREV]"
    julius_record_compression "$TOOL" "$LABEL" "$(jc_bytes "$RAW")" "$(jc_bytes "$BACKREF")" "dedup" "$SESSION_ID" || true
    emit "$BACKREF" "dedup"
    exit 0
  fi
fi

# --- Deterministic compression (every active tier) ---
[ "$LINES" -gt "$THRESHOLD" ] 2>/dev/null || exit 0
RESULT=$(printf '%s\n' "$RAW" | jc_compress "$HEAD" "$TAIL")
RLINES=$(printf '%s\n' "$RESULT" | wc -l | tr -d ' ')
NOTE="deterministic"

# --- Flash semantic fallback (Beast + Bash only, when still over budget) ---
if [ "$SHAPE" = "object" ] && [ "$TIER" = "beast" ] && [ "$RLINES" -gt "$FLASH_FALLBACK" ] 2>/dev/null && [ -x "$FLASH" ]; then
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
julius_record_compression "$TOOL" "$LABEL" "$(jc_bytes "$RAW")" "$(jc_bytes "$RESULT")" "$NOTE" "$SESSION_ID" || true
emit "$RESULT" "$NOTE"
exit 0
