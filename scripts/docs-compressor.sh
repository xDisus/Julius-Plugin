#!/usr/bin/env bash
# docs-compressor.sh — SessionStart hook: compresses project docs into caveman
# Reads CLAUDE.md, AGENTS.md, .claude/rules/*.md, generates shorthand version.
# Cached with hash — only recompiles when source changes.
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${CLAUDE_PLUGIN_DATA:-$(pwd)/.claude/julius}"
FLASH="$PLUGIN_ROOT/scripts/flash-client.sh"
CACHE_DIR="$STATE_DIR/doc-cache"

# Read tier
TIER_FILE="$STATE_DIR/active-tier"
[ -f "$TIER_FILE" ] || exit 0
TIER=$(cat "$TIER_FILE")
CONFIG="$PLUGIN_ROOT/lib/tier-config.json"
ENABLED=$(jq -r ".\"$TIER\".docs_compression.enabled // false" "$CONFIG" 2>/dev/null)
[ "$ENABLED" = "true" ] || exit 0

# Find project docs
DOCS=""
DOC_PATHS=()
CWD="$(pwd)"

# Collect docs
for f in "CLAUDE.md" "AGENTS.md" ".claude/rules/"*".md" "CONTRIBUTING.md" "ARCHITECTURE.md"; do
  [ -f "$CWD/$f" ] && DOC_PATHS+=("$f")
done

[ ${#DOC_PATHS[@]} -gt 0 ] || exit 0

# Hash source files to check freshness
HASH=$(cat "${DOC_PATHS[@]/#/$CWD/}" 2>/dev/null | md5sum 2>/dev/null | cut -d' ' -f1)
CACHE_FILE="$CACHE_DIR/compressed-docs.md"
HASH_FILE="$CACHE_DIR/source-hash"

# Use cache if hash matches
if [ -f "$CACHE_FILE" ] && [ -f "$HASH_FILE" ] && [ "$(cat "$HASH_FILE")" = "$HASH" ]; then
  exit 0
fi

# Read all docs
for doc in "${DOC_PATHS[@]}"; do
  DOCS="$DOCS

=== $doc ===
$(cat "$CWD/$doc" 2>/dev/null || echo '')"
done

# Compress via flash
if [ -x "$FLASH" ]; then
  PROMPT="Compress project docs into caveman shorthand.
Preserve ALL rules, conventions, commands, and file paths.
Drop explanations, descriptions, and prose.
Return dense one-liners:\n• command: what it does
• rule: the constraint
• path: the location

--- Docs to compress ---
$DOCS"

  RESULT=$(echo -e "$PROMPT" | "$FLASH" 2>/dev/null) || RESULT=""
  
  if [ -n "$RESULT" ] && [ "${RESULT#ERROR}" = "$RESULT" ]; then
    mkdir -p "$CACHE_DIR"
    echo "$HASH" > "$HASH_FILE"
    # Save compressed version for potential injection
    echo "[COMPRESSED DOCS]" > "$CACHE_FILE"
    echo "$RESULT" >> "$CACHE_FILE"
  fi
fi

exit 0
