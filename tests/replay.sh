#!/usr/bin/env bash
# replay.sh — measure compression efficacy on a REAL captured session, deterministically.
#
# Feeds the actual Bash/Read tool outputs from a transcript JSONL through the REAL
# scripts/compress-output.sh at each tier, and reports model-visible bytes per tier vs
# the captured control. This is tests/benchmark.sh's harness with real session data in
# place of synthetic generators — so it reflects YOUR workload, not invented heavy cases.
#
# Why a transcript and not a live A/B re-run: re-running the same task at control vs beast
# is confounded by model nondeterminism (different tool paths each run). Replaying the SAME
# captured outputs through each tier isolates the compression lever — same input, only the
# tier varies.
#
# IMPORTANT: capture the transcript with Julius on `normal` (lossless) so the recorded tool
# outputs are RAW. Replaying an already-compressed capture measures compression-of-compressed.
#
# Token figures are a bytes/4 proxy, not a tokenizer, and cover ONLY tool-output
# compression — the same caveat as benchmark.sh.
#
# Usage: bash tests/replay.sh <transcript.jsonl>
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRANSCRIPT="${1:-}"
if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
  echo "usage: bash tests/replay.sh <transcript.jsonl>" >&2
  echo "  transcript_path is in the Stop hook stdin; sessions live under ~/.claude/projects/<proj>/" >&2
  exit 1
fi

SD=$(mktemp -d)/state; mkdir -p "$SD"
export JULIUS_FLASH_BIN=/bin/false          # no network; Beast falls back to deterministic
export JULIUS_METRICS_DIR="$SD/metrics"      # do NOT pollute real ~/.julius metrics
TIERS="control normal pro beast"

toktok() { wc -c | tr -d ' '; }   # bytes; token proxy = bytes/4

# Reconstruct PostToolUse stdin objects from the transcript: join each tool_use
# (assistant) to its toolUseResult (user line). toolUseResult IS the tool_response shape.
extract() {
  jq -s '
    (reduce .[] as $l ({};
       if $l.type=="assistant" then
         reduce ($l.message.content[]? | select(.type=="tool_use")) as $u (.; .[$u.id] = {name:$u.name, input:$u.input})
       else . end)) as $uses
    | .[]
    | select(.toolUseResult != null)
    | . as $line
    | ($line.message.content[]? | select(.type=="tool_result") | .tool_use_id) as $id
    | ($uses[$id]) as $u
    | select($u != null and ($u.name=="Bash" or $u.name=="Read"))
    | select($line.toolUseResult | type=="object")
    | {tool_name:$u.name, tool_input:$u.input, tool_response:$line.toolUseResult, session_id:"replay"}
  ' "$TRANSCRIPT" 2>/dev/null
}

visible() { # $1 json  $2 tier  $3 tool
  local json="$1" tier="$2" tool="$3" out
  raw_of() {
    if [ "$tool" = Bash ]; then printf '%s' "$json" | jq -r '.tool_response.stdout // ""'
    else printf '%s' "$json" | jq -r '.tool_response.file.content // (.tool_response|tostring)'; fi
  }
  if [ "$tier" = control ]; then raw_of; return; fi
  rm -rf "$SD/dedup"; printf '%s' "$tier" > "$SD/active-tier"
  out=$(JULIUS_STATE_DIR="$SD" bash "$ROOT/scripts/compress-output.sh" 2>/dev/null <<<"$json")
  if [ -z "$out" ]; then raw_of; return; fi
  if [ "$tool" = Bash ]; then printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedToolOutput.stdout'
  else printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedToolOutput.file.content'; fi
}

# Stream reconstructed calls to a temp file (one JSON per line via -c).
CALLS="$SD/calls.jsonl"
extract | jq -c '.' > "$CALLS" 2>/dev/null || true
N=$(wc -l < "$CALLS" | tr -d ' ')
if [ "$N" = "0" ]; then
  echo "No Bash/Read tool calls reconstructed from this transcript." >&2
  echo "(check it is a real CC session JSONL with toolUseResult fields.)" >&2
  rm -rf "$(dirname "$SD")"; exit 1
fi

declare -A SUM; for t in $TIERS; do SUM[$t]=0; done
COUNT=0
while IFS= read -r json; do
  [ -n "$json" ] || continue
  tool=$(printf '%s' "$json" | jq -r '.tool_name')
  COUNT=$((COUNT+1))
  for t in $TIERS; do
    b=$(visible "$json" "$t" "$tool" | toktok)
    SUM[$t]=$(( ${SUM[$t]} + b ))
  done
done < "$CALLS"

c=${SUM[control]}
echo "Replay over $COUNT Bash/Read calls from: $(basename "$TRANSCRIPT")"
printf -- "----------------------------------------------------------\n"
printf "%-22s | %12s | %10s\n" "tier" "visible bytes" "~tok (b/4)"
printf -- "----------------------------------------------------------\n"
for t in $TIERS; do
  printf "%-22s | %12d | %10d\n" "$t" "${SUM[$t]}" "$(( ${SUM[$t]} / 4 ))"
done
printf -- "----------------------------------------------------------\n"
if [ "$c" -gt 0 ]; then
  printf "%-22s | %12s | %10s\n" "saved vs control" \
    "$(( (c-${SUM[beast]}) ))" "$(( (c-${SUM[beast]})/4 ))"
  printf "beast elides %d%% of captured tool-output bytes.\n" "$(( (c-${SUM[beast]})*100/c ))"
fi
echo
echo "Scope: tool-output compression+dedup only. Excludes oracle/coaching token COSTS"
echo "and counterfactual read-prevention — this is the lever, not net plugin savings."
rm -rf "$(dirname "$SD")"
