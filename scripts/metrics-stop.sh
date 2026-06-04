#!/bin/bash
# metrics-stop.sh — Julius token savings metrics (Stop hook)
# Reads transcript JSONL, computes actual vs baseline cost, logs cumulative savings.
#
# Stop hook stdin JSON:
#   { "session_id": "...", "transcript_path": "/path/session.jsonl", "cwd": "...", "stop_reason": "end_turn" }
#
# Pricing baseline (Claude Sonnet $3/$15 per 1M input/output — unoptimized):
#   Julius savings come from: tool output compression, large-file guard, oracle preprocess,
#   docs compression, context-mode synergy, and tier-specific aggressiveness.

set -euo pipefail

METRICS_DIR="${HOME}/.julius/metrics"
METRICS_FILE="${METRICS_DIR}/cumulative.json"
LOG_FILE="${METRICS_DIR}/metrics.log"

mkdir -p "${METRICS_DIR}"

# ─── Parse stdin ───────────────────────────────────────────────
INPUT=$(cat)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
STOP_REASON=$(echo "$INPUT" | jq -r '.stop_reason // "unknown"')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
PROJECT=$(basename "$CWD" 2>/dev/null || echo "unknown")

# Only count on end_turn (skip tool_use — those trigger intermediate stops)
if [ "$STOP_REASON" != "end_turn" ] && [ "$STOP_REASON" != "null" ]; then
    exit 0
fi

# ─── Get active tier ───────────────────────────────────────────
TIER_FILE="${HOME}/.julius/tier"
TIER="normal"
if [ -f "$TIER_FILE" ]; then
    TIER=$(cat "$TIER_FILE")
fi

# Tier multiplier: how much LESS input tokens the Julius stack uses vs raw Claude Code
# These reflect the FULL stack (Julius + context-mode + caveman):
# Normal: ~10% (Julius hooks only — cache, structured output, pruning)
# Pro:    ~80% (+ context-mode sandboxes tool output — 60K→2K tokens per call)
# Beast:  ~95% (+ caveman compresses model output — 2K→500 tokens)
case "$TIER" in
    beast)  SAVINGS_MULTIPLIER=0.95 ;;
    pro)    SAVINGS_MULTIPLIER=0.80 ;;
    *)      SAVINGS_MULTIPLIER=0.10 ;;
esac

# Cap baseline input at 50x actual (prevents absurd estimates on tiny turns)
MAX_BASELINE_RATIO=50

# ─── Parse transcript for latest token usage ───────────────────
if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
    # transcript_path not available — skip
    exit 0
fi

# Extract the LAST assistant message with usage data
LAST_MSG=$(grep '"type":"assistant"' "$TRANSCRIPT" 2>/dev/null | tail -1)
if [ -z "$LAST_MSG" ]; then
    exit 0
fi

INPUT_TOKENS=$(echo "$LAST_MSG" | jq -r '.message.usage.input_tokens // .usage.input_tokens // 0' 2>/dev/null)
OUTPUT_TOKENS=$(echo "$LAST_MSG" | jq -r '.message.usage.output_tokens // .usage.output_tokens // 0' 2>/dev/null)
CACHE_HITS=$(echo "$LAST_MSG" | jq -r '.message.usage.cache_read_input_tokens // .usage.cache_creation_input_tokens // 0' 2>/dev/null)

# If no tokens found, try alternate structure (Claude API format)
if [ "$INPUT_TOKENS" = "0" ]; then
    INPUT_TOKENS=$(echo "$LAST_MSG" | jq -r '.usage.input_tokens // 0' 2>/dev/null)
    OUTPUT_TOKENS=$(echo "$LAST_MSG" | jq -r '.usage.output_tokens // 0' 2>/dev/null)
fi

if [ "$INPUT_TOKENS" = "0" ] && [ "$OUTPUT_TOKENS" = "0" ]; then
    exit 0
fi

# ─── Cost calculation (Sonnet pricing: $3/1M input, $15/1M output) ──
# Actual: what Claude actually charged
ACTUAL_COST=$(echo "scale=8; ($INPUT_TOKENS * 3 + $OUTPUT_TOKENS * 15) / 1000000" | bc 2>/dev/null || echo "0")

# Baseline: what the SAME work would cost WITHOUT the Julius stack (uncompressed context)
# Julius stack reduces effective input tokens by the tier savings — baseline inflates back
BASELINE_INPUT=$(echo "scale=0; $INPUT_TOKENS / (1 - $SAVINGS_MULTIPLIER)" | bc 2>/dev/null || echo "$INPUT_TOKENS")
# Cap at MAX_BASELINE_RATIO * actual to avoid absurd estimates on tiny turns
BASELINE_CAP=$(echo "scale=0; $INPUT_TOKENS * $MAX_BASELINE_RATIO" | bc 2>/dev/null || echo "$BASELINE_INPUT")
if [ "$BASELINE_INPUT" -gt "$BASELINE_CAP" ] 2>/dev/null; then
    BASELINE_INPUT="$BASELINE_CAP"
fi
# Output tokens are compressed by caveman (external, Beast tier) — estimate accordingly
if [ "$TIER" = "beast" ]; then
    # Caveman compresses output ~70% → baseline output = 3.3x actual
    BASELINE_OUTPUT=$(echo "scale=0; $OUTPUT_TOKENS * 3.3" | bc 2>/dev/null || echo "$OUTPUT_TOKENS")
else
    BASELINE_OUTPUT="$OUTPUT_TOKENS"
fi
BASELINE_COST=$(echo "scale=8; ($BASELINE_INPUT * 3 + $BASELINE_OUTPUT * 15) / 1000000" | bc 2>/dev/null || echo "$ACTUAL_COST")

SAVED=$(echo "scale=8; $BASELINE_COST - $ACTUAL_COST" | bc 2>/dev/null || echo "0")

# ─── Update cumulative metrics ─────────────────────────────────
if [ -f "$METRICS_FILE" ]; then
    CUMULATIVE=$(cat "$METRICS_FILE")
else
    CUMULATIVE='{"total_input":0,"total_output":0,"total_cache":0,"total_baseline_input":0,"total_cost":0,"total_baseline_cost":0,"total_saved":0,"turns":0,"sessions":{}}'
fi

# Update with jq
CUMULATIVE=$(echo "$CUMULATIVE" | jq \
    --argjson it "$INPUT_TOKENS" \
    --argjson ot "$OUTPUT_TOKENS" \
    --argjson ch "$CACHE_HITS" \
    --argjson bi "$BASELINE_INPUT" \
    --argjson ac "$ACTUAL_COST" \
    --argjson bc "$BASELINE_COST" \
    --argjson sv "$SAVED" \
    --arg sid "$SESSION_ID" \
    --arg ts "$(date -Iseconds)" \
    --arg proj "$PROJECT" \
    --arg tier "$TIER" \
    '.total_input += $it |
     .total_output += $ot |
     .total_cache += $ch |
     .total_baseline_input += $bi |
     .total_cost += $ac |
     .total_baseline_cost += $bc |
     .total_saved += $sv |
     .turns += 1 |
     .last_turn = {"session":$sid,"project":$proj,"tier":$tier,"input":$it,"output":$ot,"saved":$sv,"time":$ts}')

echo "$CUMULATIVE" > "$METRICS_FILE"

# ─── Log ────────────────────────────────────────────────────────
echo "$(date -Iseconds) | tier=$TIER | session=${SESSION_ID:0:8} | project=$PROJECT | in=$INPUT_TOKENS | out=$OUTPUT_TOKENS | cache=$CACHE_HITS | base_in=$BASELINE_INPUT | saved=\$$SAVED | cum_saved=\$$(echo "$CUMULATIVE" | jq -r '.total_saved')" >> "$LOG_FILE"

# ─── Milestone notification every ~$0.50 saved ──────────────────
TOTAL_SAVED=$(echo "$CUMULATIVE" | jq -r '.total_saved')
LAST_MILESTONE_FILE="${METRICS_DIR}/last_milestone"
LAST_MILESTONE="0"
if [ -f "$LAST_MILESTONE_FILE" ]; then
    LAST_MILESTONE=$(cat "$LAST_MILESTONE_FILE")
fi

# Milestones at every $0.50 increment
CURRENT_MILESTONE=$(echo "scale=0; ($TOTAL_SAVED * 2) / 1" | bc 2>/dev/null || echo "0")
if [ "$CURRENT_MILESTONE" -gt "$LAST_MILESTONE" ] 2>/dev/null; then
    echo "$CURRENT_MILESTONE" > "$LAST_MILESTONE_FILE"
    TOTAL_COST=$(echo "$CUMULATIVE" | jq -r '.total_cost')
    BASELINE_TOTAL=$(echo "$CUMULATIVE" | jq -r '.total_baseline_cost')
    TURNS=$(echo "$CUMULATIVE" | jq -r '.turns')
    
    # Format for display
    printf '{
  "hookSpecificOutput": {
    "hookEventName": "Stop",
    "additionalContext": "💰 Julius metrics: \\$%.4f saved over %d turns (tier: %s). Actual cost: \\$%.4f | Baseline (unoptimized): \\$%.4f | Savings: %.0f%% | Cumulative total saved: \\$%.4f"
  }
}' \
        "$SAVED" "$TURNS" "$TIER" "$ACTUAL_COST" "$BASELINE_COST" \
        "$(echo "scale=0; ($SAVED / $BASELINE_COST) * 100" | bc 2>/dev/null || echo "0")" \
        "$TOTAL_SAVED" \
        > /dev/null  # milestone message is logged, not injected (avoids spam)
    
    echo "[Julius] 🏆 MILESTONE: \$$TOTAL_SAVED saved! ($TURNS turns, tier=$TIER)" >> "$LOG_FILE"
fi

exit 0
