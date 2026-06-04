#!/usr/bin/env bash
# oracle-preprocess.sh — UserPromptSubmit hook.
# Runs a flash pass over the user prompt + a small project index and injects a
# dense dossier (TARGETS/APPROACH/WATCH) via additionalContext.
#
# stdin is JSON: {prompt, cwd, ...}. Output is JSON hookSpecificOutput.additionalContext.
# Gated hard: only fires on non-trivial prompts, and caches by prompt+index hash so
# repeated/identical prompts don't pay the network round-trip again.
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../lib/julius-common.sh
source "$PLUGIN_ROOT/lib/julius-common.sh"
FLASH="${JULIUS_FLASH_BIN:-$PLUGIN_ROOT/scripts/flash-client.sh}"

TIER=$(julius_tier) || exit 0
[ "$(julius_config "$TIER" .oracle.enabled false)" = "true" ] || exit 0
TIMEOUT=$(julius_config "$TIER" .oracle.flash_timeout_seconds 5)
MIN_WORDS=$(julius_config "$TIER" .oracle.min_prompt_words 6)

INPUT=$(julius_stdin)
[ -n "$INPUT" ] || exit 0
julius_is_json "$INPUT" || exit 0
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty' 2>/dev/null)
[ -n "$PROMPT" ] || exit 0

# Gate: skip trivial/short prompts and slash commands — the dossier isn't worth a call.
case "$PROMPT" in /*) exit 0 ;; esac
WORDS=$(printf '%s' "$PROMPT" | wc -w | tr -d ' ')
[ "$WORDS" -ge "$MIN_WORDS" ] 2>/dev/null || exit 0
[ -x "$FLASH" ] || exit 0

CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null); [ -n "$CWD" ] || CWD="$(pwd)"

DIRS=$(find "$CWD" -maxdepth 2 -type d -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null | head -20 | paste -sd ' ' -)
FILES=$(find "$CWD" -maxdepth 3 \( -name '*.py' -o -name '*.js' -o -name '*.ts' -o -name '*.go' -o -name '*.rs' \) 2>/dev/null | head -15 | sed "s|$CWD/||" | paste -sd ' ' -)
INDEX="DIRS: $DIRS
FILES: $FILES"

# Cache by content hash.
CACHE_DIR="$(julius_state_dir)/oracle-cache"; mkdir -p "$CACHE_DIR"
HASH=$(printf '%s\n%s' "$PROMPT" "$INDEX" | julius_md5)
CACHE_FILE="$CACHE_DIR/$HASH"
if [ -f "$CACHE_FILE" ]; then
  RESULT=$(cat "$CACHE_FILE")
else
  ORACLE_INPUT="You are a task router for a coding agent. From the prompt and project index, return <=120 tokens, exactly:
TARGETS: file:line, file:line (max 3)
APPROACH: one sentence
WATCH: one sentence

--- prompt ---
$PROMPT

--- index ---
$INDEX"
  RESULT=$(printf '%s' "$ORACLE_INPUT" | JULIUS_FLASH_TIMEOUT="$TIMEOUT" JULIUS_FLASH_MAX_TOKENS=200 "$FLASH" 2>/dev/null) || RESULT=""
  [ -n "$RESULT" ] && [ "${RESULT#ERROR}" = "$RESULT" ] && printf '%s' "$RESULT" > "$CACHE_FILE"
fi

[ -n "$RESULT" ] && [ "${RESULT#ERROR}" = "$RESULT" ] || exit 0

jq -n --arg ctx "[ORACLE]
$RESULT" '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
exit 0
