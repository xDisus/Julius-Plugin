#!/usr/bin/env bash
# task-manifest.sh — TaskCreated / TaskCompleted hooks.
# Maintains a compact task manifest in the unified state dir and prints a one-line digest.
# stdin is JSON. TaskCompleted: {task_id, task_subject, task_description?}.
# TaskCreated: {task_subject, task_description?, task_id?}. Advisory only: always exit 0
# (exit 2 would roll back task creation / block completion).
set -euo pipefail

ACTION="${1:-}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../lib/julius-common.sh
source "$PLUGIN_ROOT/lib/julius-common.sh"

TIER=$(julius_tier) || exit 0
[ "$(julius_config "$TIER" .task_manifest.enabled false)" = "true" ] || exit 0

STATE_DIR="$(julius_state_dir)"
MANIFEST="$STATE_DIR/tasks.json"
mkdir -p "$STATE_DIR"
[ -f "$MANIFEST" ] || echo '{"tasks":[]}' > "$MANIFEST"

INPUT=$(julius_stdin)
julius_is_json "$INPUT" || INPUT="{}"   # tolerate empty/malformed; jq paths then yield empty
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

case "$ACTION" in
  created)
    DESC=$(echo "$INPUT" | jq -r '.task_subject // .task_description // .tool_input.description // empty' 2>/dev/null)
    ID=$(echo "$INPUT" | jq -r '.task_id // empty' 2>/dev/null)
    [ -n "$DESC" ] || exit 0
    # No id at creation time on some versions → derive a stable one from the subject.
    [ -n "$ID" ] || ID=$(printf '%s' "$DESC" | julius_md5)
    EXISTS=$(jq --arg id "$ID" '[.tasks[] | select(.id == $id)] | length' "$MANIFEST" 2>/dev/null || echo 0)
    [ "$EXISTS" -eq 0 ] 2>/dev/null || exit 0
    jq --arg id "$ID" --arg desc "$DESC" --arg now "$NOW" \
       '.tasks += [{id:$id, description:$desc, status:"active", created_at:$now}]' \
       "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
    ;;
  completed)
    ID=$(echo "$INPUT" | jq -r '.task_id // empty' 2>/dev/null)
    SUBJ=$(echo "$INPUT" | jq -r '.task_subject // empty' 2>/dev/null)
    # Match by id, else by subject (covers derived ids from creation).
    [ -n "$ID" ] || ID=$(printf '%s' "$SUBJ" | julius_md5)
    jq --arg id "$ID" --arg now "$NOW" \
       '(.tasks[] | select(.id == $id) | .status) = "completed"
        | (.tasks[] | select(.id == $id) | .completed_at) = $now' \
       "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
    ;;
  *)
    echo "Usage: task-manifest.sh <created|completed>" >&2
    exit 1
    ;;
esac

TOTAL=$(jq '.tasks | length' "$MANIFEST")
DONE=$(jq '[.tasks[] | select(.status=="completed")] | length' "$MANIFEST")
ACTIVE=$(jq '[.tasks[] | select(.status=="active")] | length' "$MANIFEST")
[ "$TOTAL" -gt 0 ] || exit 0

LINE="[TASKS] ${DONE}/${TOTAL} done."
if [ "$ACTIVE" -gt 0 ]; then
  FIRST=$(jq -r '[.tasks[] | select(.status=="active")] | .[0].description // empty' "$MANIFEST" | head -c 60)
  [ -n "$FIRST" ] && LINE="$LINE Active: ${FIRST}..."
fi
echo "$LINE"
exit 0
