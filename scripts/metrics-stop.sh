#!/bin/bash
# metrics-stop.sh — Julius token metrics (Stop hook).
# Records ONLY ground truth: the real per-turn token usage + cost from the transcript
# `usage` fields. No heuristic "savings" estimate — the prior tier-multiplier baseline
# was a guess, not a measurement, so it is gone. For the one lever Julius can measure
# honestly (tool-output bytes elided), see compression.jsonl + `julius-stats.sh`.
#
# Stop hook stdin JSON:
#   { "session_id": "...", "transcript_path": "/path/session.jsonl", "cwd": "...", ... }

set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../lib/julius-common.sh
source "$PLUGIN_ROOT/lib/julius-common.sh"

METRICS_DIR="$(julius_metrics_dir)"
METRICS_FILE="${METRICS_DIR}/cumulative.json"
LOG_FILE="${METRICS_DIR}/metrics.log"

mkdir -p "${METRICS_DIR}"

# ─── Parse stdin ───────────────────────────────────────────────
# The Stop event carries no `stop_reason`; it fires once when Claude finishes the turn.
INPUT=$(cat)
julius_is_json "$INPUT" || exit 0
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
PROJECT=$(basename "$CWD" 2>/dev/null || echo "unknown")

TIER=$(julius_tier 2>/dev/null || echo "normal")
[ -n "$TIER" ] || TIER="normal"

# ─── Parse transcript for latest token usage ───────────────────
if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
    exit 0
fi

LAST_MSG=$(grep '"type":"assistant"' "$TRANSCRIPT" 2>/dev/null | tail -1)
[ -n "$LAST_MSG" ] || exit 0

INPUT_TOKENS=$(echo "$LAST_MSG" | jq -r '.message.usage.input_tokens // .usage.input_tokens // 0' 2>/dev/null)
OUTPUT_TOKENS=$(echo "$LAST_MSG" | jq -r '.message.usage.output_tokens // .usage.output_tokens // 0' 2>/dev/null)
CACHE_HITS=$(echo "$LAST_MSG" | jq -r '.message.usage.cache_read_input_tokens // .usage.cache_creation_input_tokens // 0' 2>/dev/null)

if [ "$INPUT_TOKENS" = "0" ]; then
    INPUT_TOKENS=$(echo "$LAST_MSG" | jq -r '.usage.input_tokens // 0' 2>/dev/null)
    OUTPUT_TOKENS=$(echo "$LAST_MSG" | jq -r '.usage.output_tokens // 0' 2>/dev/null)
fi

if [ "$INPUT_TOKENS" = "0" ] && [ "$OUTPUT_TOKENS" = "0" ]; then
    exit 0
fi

# ─── Real cost (Sonnet pricing: $3/1M input, $15/1M output) — what Claude charged ──
ACTUAL_COST=$(echo "scale=8; ($INPUT_TOKENS * 3 + $OUTPUT_TOKENS * 15) / 1000000" | bc 2>/dev/null || echo "0")

# ─── Update cumulative metrics (real fields only) ──────────────
if [ -f "$METRICS_FILE" ]; then
    CUMULATIVE=$(cat "$METRICS_FILE")
else
    CUMULATIVE='{"total_input":0,"total_output":0,"total_cache":0,"total_cost":0,"turns":0,"sessions":{}}'
fi

CUMULATIVE=$(echo "$CUMULATIVE" | jq \
    --argjson it "$INPUT_TOKENS" \
    --argjson ot "$OUTPUT_TOKENS" \
    --argjson ch "$CACHE_HITS" \
    --argjson ac "$ACTUAL_COST" \
    --arg sid "$SESSION_ID" \
    --arg ts "$(date -Iseconds)" \
    --arg proj "$PROJECT" \
    --arg tier "$TIER" \
    '.total_input += $it |
     .total_output += $ot |
     .total_cache += $ch |
     .total_cost += $ac |
     .turns += 1 |
     .last_turn = {"session":$sid,"project":$proj,"tier":$tier,"input":$it,"output":$ot,"time":$ts}')

echo "$CUMULATIVE" > "$METRICS_FILE"

echo "$(date -Iseconds) | tier=$TIER | session=${SESSION_ID:0:8} | project=$PROJECT | in=$INPUT_TOKENS | out=$OUTPUT_TOKENS | cache=$CACHE_HITS | cost=\$$ACTUAL_COST" >> "$LOG_FILE"

exit 0
