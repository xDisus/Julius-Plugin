#!/usr/bin/env bash
# task-manifest.sh — Compressed task manifest for Julius
# Called by: TaskCreated and TaskCompleted hooks
# Reads task data from stdin, maintains .claude/julius/tasks.json
set -euo pipefail

ACTION="${1:-}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE_DIR="${CLAUDE_PLUGIN_DATA:-$(pwd)/.claude/julius}"
MANIFEST="$STATE_DIR/tasks.json"
ACTIVE_TIER="$STATE_DIR/active-tier"

# Check Julius is active
if [ ! -f "$ACTIVE_TIER" ]; then
  exit 0
fi

# Check task manifest is enabled for this tier
TIER=$(cat "$ACTIVE_TIER")
CONFIG="$PLUGIN_ROOT/lib/tier-config.json"
TASK_ENABLED=$(jq -r ".\"$TIER\".task_manifest.enabled // false" "$CONFIG" 2>/dev/null)
if [ "$TASK_ENABLED" != "true" ]; then
  exit 0
fi

# Read task data from stdin
TASK_DATA=""
if [ ! -t 0 ]; then
  TASK_DATA=$(cat)
fi

# Initialize manifest if not exists
if [ ! -f "$MANIFEST" ]; then
  mkdir -p "$STATE_DIR"
  echo '{"tasks":[]}' > "$MANIFEST"
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

case "$ACTION" in
  created)
    # Try to extract task description from env or stdin
    TASK_DESC="${CLAUDE_HOOK_TASK_NAME:-}"
    TASK_ID="${CLAUDE_HOOK_TASK_ID:-}"

    if [ -z "$TASK_DESC" ] && [ -n "$TASK_DATA" ]; then
      TASK_DESC=$(echo "$TASK_DATA" | jq -r '.description // .name // .task // empty' 2>/dev/null || echo "$TASK_DATA" | head -c 120)
    fi

    if [ -z "$TASK_ID" ] && [ -n "$TASK_DATA" ]; then
      TASK_ID=$(echo "$TASK_DATA" | jq -r '.id // .task_id // empty' 2>/dev/null || echo "$(date +%s)")
    fi

    # Guard: skip if no description
    if [ -z "$TASK_DESC" ]; then
      exit 0
    fi

    # Guard: skip duplicate IDs
    EXISTS=$(jq --arg id "$TASK_ID" '[.tasks[] | select(.id == $id)] | length' "$MANIFEST")
    if [ "$EXISTS" -gt 0 ]; then
      exit 0
    fi

    # Add task
    jq --arg id "$TASK_ID" \
       --arg desc "$TASK_DESC" \
       --arg now "$NOW" \
       '.tasks += [{"id": $id, "description": $desc, "status": "active", "created_at": $now}]' \
       "$MANIFEST" > "${MANIFEST}.tmp" && mv "${MANIFEST}.tmp" "$MANIFEST"
    ;;

  completed)
    TASK_ID="${CLAUDE_HOOK_TASK_ID:-}"

    if [ -z "$TASK_ID" ] && [ -n "$TASK_DATA" ]; then
      TASK_ID=$(echo "$TASK_DATA" | jq -r '.id // .task_id // empty' 2>/dev/null || echo "")
    fi

    if [ -n "$TASK_ID" ]; then
      jq --arg id "$TASK_ID" --arg now "$NOW" \
        '(.tasks[] | select(.id == $id) | .status) = "completed" | (.tasks[] | select(.id == $id) | .completed_at) = $now' \
        "$MANIFEST" > "${MANIFEST}.tmp" && mv "${MANIFEST}.tmp" "$MANIFEST"
    fi
    ;;

  *)
    echo "Usage: task-manifest.sh <created|completed>"
    exit 1
    ;;
esac

# Print compressed manifest to stdout (injected as feedback)
TOTAL=$(jq '.tasks | length' "$MANIFEST")
ACTIVE=$(jq '[.tasks[] | select(.status == "active")] | length' "$MANIFEST")
DONE=$(jq '[.tasks[] | select(.status == "completed")] | length' "$MANIFEST")

if [ "$TOTAL" -gt 0 ]; then
  # Get first active task description (truncated)
  FIRST_ACTIVE=$(jq -r '[.tasks[] | select(.status == "active")] | .[0].description // empty' "$MANIFEST" | head -c 60)
  
  MANIFEST_LINE="[TASKS] ${DONE}/${TOTAL} done."
  if [ "$ACTIVE" -gt 0 ] && [ -n "$FIRST_ACTIVE" ]; then
    MANIFEST_LINE+=" Active: ${FIRST_ACTIVE}..."
  fi
  
  echo "$MANIFEST_LINE"
fi
