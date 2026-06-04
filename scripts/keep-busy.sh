#!/usr/bin/env bash
# keep-busy.sh — TeammateIdle hook.
# When a teammate goes idle, check for pending work (active tasks, untested changes).
# If found, redirect via stderr + exit 2 (keeps the teammate working). Capped by
# max_reactivations to avoid loops. No work → exit 0 (let it idle).
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../lib/julius-common.sh
source "$PLUGIN_ROOT/lib/julius-common.sh"

TIER=$(julius_tier) || exit 0
[ "$(julius_config "$TIER" .agent_pipelines.enabled false)" = "true" ] || exit 0
MAX_REACT=$(julius_config "$TIER" .agent_pipelines.max_reactivations 3)

STATE_DIR="$(julius_state_dir)"
REACT_FILE="$STATE_DIR/reactivation-count"
mkdir -p "$STATE_DIR"
REACT_COUNT=0; [ -f "$REACT_FILE" ] && REACT_COUNT=$(cat "$REACT_FILE")
[ "$REACT_COUNT" -lt "$MAX_REACT" ] 2>/dev/null || exit 0

# Untested code changes?
UNTESTED=false; CHANGES=""
if git rev-parse --git-dir >/dev/null 2>&1; then
  CHANGES=$(git diff --name-only 2>/dev/null | grep -E '\.(py|js|ts|go|rs)$' | head -5 || true)
  [ -n "$CHANGES" ] && UNTESTED=true
fi

# Active tasks in the manifest?
ACTIVE_TASKS=$(jq '[.tasks[] | select(.status=="active")] | length' "$STATE_DIR/tasks.json" 2>/dev/null || echo 0)

[ "$ACTIVE_TASKS" -eq 0 ] && [ "$UNTESTED" = false ] && exit 0

echo $((REACT_COUNT + 1)) > "$REACT_FILE"

WORK=""
if [ "$UNTESTED" = true ]; then
  FILES=$(printf '%s' "$CHANGES" | paste -sd ' ' -)
  WORK="Run the test suite for the changed files: $FILES"
fi
if [ "$ACTIVE_TASKS" -gt 0 ]; then
  DESC=$(jq -r '[.tasks[] | select(.status=="active")] | .[0].description // empty' "$STATE_DIR/tasks.json" 2>/dev/null | head -c 80)
  [ -n "$WORK" ] && WORK="$WORK"$'\n'"Then continue active task: $DESC" || WORK="Continue active task: $DESC"
fi

[ -n "$WORK" ] || exit 0
{
  echo "[JULIUS PIPELINE] Pending work before idling:"
  echo "$WORK"
} >&2
exit 2
