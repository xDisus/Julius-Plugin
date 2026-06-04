#!/usr/bin/env bash
# oracle-preprocess.sh — UserPromptSubmit hook
# Before each turn, runs flash LLM on the user prompt + project index.
# Returns a dense "dossier" injected as prefix: [ORACLE] targets, approach, watch.
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${CLAUDE_PLUGIN_DATA:-$(pwd)/.claude/julius}"
FLASH="$PLUGIN_ROOT/scripts/flash-client.sh"

# Read tier
TIER_FILE="$STATE_DIR/active-tier"
[ -f "$TIER_FILE" ] || exit 0
TIER=$(cat "$TIER_FILE")
CONFIG="$PLUGIN_ROOT/lib/tier-config.json"
ENABLED=$(jq -r ".\"$TIER\".oracle.enabled // false" "$CONFIG" 2>/dev/null)
[ "$ENABLED" = "true" ] || exit 0

TIMEOUT=$(jq -r ".\"$TIER\".oracle.flash_timeout_seconds // 5" "$CONFIG" 2>/dev/null)

# Read user prompt from stdin
PROMPT=""
if [ ! -t 0 ]; then
  PROMPT=$(cat)
fi

[ -n "$PROMPT" ] || exit 0

# Build quick project index — just file tree and recent git log
CWD="$(pwd)"
PROJECT_INDEX=""
PROJECT_INDEX="DIRS: $(find "$CWD" -maxdepth 2 -type d -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null | head -20 | paste -sd ' ')"
PROJECT_INDEX="$PROJECT_INDEX

FILES: $(find "$CWD" -maxdepth 3 -type f -name '*.py' -o -name '*.js' -o -name '*.ts' -o -name '*.go' -o -name '*.rs' 2>/dev/null | head -15 | sed "s|$CWD/||" | paste -sd ' ')"

[ -x "$FLASH" ] || exit 0

# Build oracle prompt
ORACLE_INPUT="You are a task router for a coding agent. Given a prompt and project index, identify:

1. TARGETS: which files are relevant (max 3, with line hints if possible)
2. APPROACH: the likely fix or implementation in 1 sentence
3. WATCH: potential pitfalls or dependencies (1 line)

Return in 150 tokens max, format:
TARGETS: file1.py:line, file2.py:line
APPROACH: one sentence
WATCH: one sentence

--- User prompt ---
$PROMPT

--- Project index ---
$PROJECT_INDEX"

# Call flash with tight timeout
RESULT=$(echo "$ORACLE_INPUT" | "$FLASH" 2>/dev/null) || RESULT=""

if [ -n "$RESULT" ] && [ "${RESULT#ERROR}" = "$RESULT" ]; then
  # Inject as prefix to the user prompt
  echo ""
  echo "[ORACLE]"
  echo "$RESULT"
  echo ""
fi

exit 0
