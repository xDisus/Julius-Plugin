#!/usr/bin/env bash
# keep-busy.sh — TeammateIdle hook
# Detects when a teammate (subagent) is idle and checks if there's work.
# Scans: pending tasks in manifest, untested changes via git diff.
# Reactivates with directed work if found.
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${CLAUDE_PLUGIN_DATA:-$(pwd)/.claude/julius}"

# Read tier
TIER_FILE="$STATE_DIR/active-tier"
[ -f "$TIER_FILE" ] || exit 0
TIER=$(cat "$TIER_FILE")
CONFIG="$PLUGIN_ROOT/lib/tier-config.json"
ENABLED=$(jq -r ".\"$TIER\".agent_pipelines.enabled // false" "$CONFIG" 2>/dev/null)
[ "$ENABLED" = "true" ] || exit 0
MAX_REACT=$(jq -r ".\"$TIER\".agent_pipelines.max_reactivations // 3" "$CONFIG" 2>/dev/null)

REACT_FILE="$STATE_DIR/reactivation-count"
REACT_COUNT=0
[ -f "$REACT_FILE" ] && REACT_COUNT=$(cat "$REACT_FILE")

# Cap reactivations
if [ "$REACT_COUNT" -ge "$MAX_REACT" ] 2>/dev/null; then
  exit 0
fi

# Check for untracked changes via git
HAS_CHANGES=false
if git rev-parse --git-dir >/dev/null 2>&1; then
  CHANGES=$(git diff --name-only 2>/dev/null | head -5)
  [ -n "$CHANGES" ] && HAS_CHANGES=true
fi

# Check for untested files (changed .py/.js/.ts without corresponding test run)
UNTESTED=false
if [ "$HAS_CHANGES" = true ]; then
  CHANGED_PY=$(echo "$CHANGES" | grep -c '\.py$' 2>/dev/null || echo 0)
  [ "$CHANGED_PY" -gt 0 ] && UNTESTED=true
fi

# Check task manifest for active tasks
ACTIVE_TASKS=$(jq '[.tasks[] | select(.status == "active")] | length' "$STATE_DIR/tasks.json" 2>/dev/null || echo 0)

# Nothing to do
if [ "$ACTIVE_TASKS" -eq 0 ] && [ "$UNTESTED" = false ]; then
  exit 0
fi

# Increment reactivation count
echo $((REACT_COUNT + 1)) > "$REACT_FILE"

# Build work instructions
WORK_MSG=""
if [ "$UNTESTED" = true ]; then
  FIRST_CHANGED=$(echo "$CHANGES" | head -1)
  TEST_FILE=$(echo "$FIRST_CHANGED" | sed 's/\.py$/_test.py/' | sed 's|^|test_|' 2>/dev/null || echo "tests")
  WORK_MSG="Run tests for changed files. Start with: pytest $TEST_FILE -x"
fi

if [ "$ACTIVE_TASKS" -gt 0 ] && [ -n "$WORK_MSG" ]; then
  WORK_MSG="$WORK_MSG

Also check active tasks in manifest."
elif [ "$ACTIVE_TASKS" -gt 0 ]; then
  ACTIVE_DESC=$(jq -r '[.tasks[] | select(.status == "active")] | .[0].description // empty' "$STATE_DIR/tasks.json" 2>/dev/null | head -c 80)
  WORK_MSG="Continue: $ACTIVE_DESC"
fi

if [ -n "$WORK_MSG" ]; then
  echo "[JULIUS PIPELINE] Teammate idle with pending work:"
  echo "  $WORK_MSG"
fi

exit 0
