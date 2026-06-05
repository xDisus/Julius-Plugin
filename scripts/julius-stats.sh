#!/usr/bin/env bash
# julius-stats.sh — read-only report of MEASURED Julius numbers. No estimates laundered
# as savings. Two independent sources, each labeled by what it actually measures:
#
#   1. compression.jsonl  — per-call deltas recorded live by compress-output.sh at the
#      moment it compressed/deduped. This is the ONE lever with ground-truth bytes:
#      orig vs replacement, summed. Reported as "tool-output bytes elided" — NOT net
#      plugin savings (it excludes oracle/coaching token COSTS and counterfactual
#      read-prevention, which this number cannot see).
#   2. cumulative.json    — real API-counted tokens (input/output/cache) from transcript
#      `usage` fields, accumulated by metrics-stop.sh across turns. Ground truth for what
#      Claude actually charged. No baseline guess.
#
# Token figures from compression are a bytes/4 proxy (labeled est); usage tokens are real.
# Usage: bash scripts/julius-stats.sh [--session <id>]
set -uo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=../lib/julius-common.sh
source "$PLUGIN_ROOT/lib/julius-common.sh"

SESSION_FILTER=""
[ "${1:-}" = "--session" ] && SESSION_FILTER="${2:-}"

MDIR="$(julius_metrics_dir)"
CJSONL="$MDIR/compression.jsonl"
CUMUL="$MDIR/cumulative.json"

echo "════════════════════════════════════════════════════════════"
echo " Julius Stats — measured, per lever (no net-savings estimate)"
echo "════════════════════════════════════════════════════════════"

# ─── Section 1: compression lever (ground truth) ───────────────
echo
echo "▸ Tool-output compression + dedup  (measured bytes elided)"
if [ ! -s "$CJSONL" ]; then
  echo "  no compression events recorded yet."
  echo "  (run with tier=pro or beast; compression only fires above the line threshold.)"
else
  # Filter by session if requested, then aggregate in one jq pass.
  jq -rs --arg sf "$SESSION_FILTER" '
    map(select($sf == "" or .session == $sf))
    | { calls: length,
        orig: (map(.orig_chars) | add // 0),
        comp: (map(.comp_chars) | add // 0),
        by_tool: (group_by(.tool) | map({tool: .[0].tool, calls: length,
                   orig: (map(.orig_chars)|add), comp: (map(.comp_chars)|add)})),
        by_note: (group_by(.note) | map({note: .[0].note, calls: length,
                   orig: (map(.orig_chars)|add), comp: (map(.comp_chars)|add)})) }
    | . as $r
    | "  calls: \($r.calls)   elided: \($r.orig - $r.comp) bytes  (~\(($r.orig - $r.comp)/4 | floor) tok est)"
      + "   ratio: \(if $r.orig>0 then (($r.orig - $r.comp)*100/$r.orig | floor) else 0 end)%",
      "  by tool:",
      ($r.by_tool[] | "    \(.tool): \(.calls) calls, elided \(.orig - .comp) bytes (\(if .orig>0 then ((.orig-.comp)*100/.orig|floor) else 0 end)%)"),
      "  by method:",
      ($r.by_note[] | "    \(.note): \(.calls) calls, elided \(.orig - .comp) bytes")
  ' "$CJSONL" 2>/dev/null || echo "  (failed to parse compression log)"
fi

# ─── Section 2: real API-counted token usage ───────────────────
echo
echo "▸ Real token usage  (API-counted, from transcript usage fields)"
if [ ! -s "$CUMUL" ]; then
  echo "  no usage recorded yet (metrics-stop runs on the Stop hook)."
else
  jq -r '
    "  turns: \(.turns // 0)   input: \(.total_input // 0)   output: \(.total_output // 0)   cache-read: \(.total_cache // 0)",
    "  actual cost: $\(((.total_cost // 0)*10000|floor)/10000)",
    (if .last_turn then "  last turn: \(.last_turn.project) tier=\(.last_turn.tier) in=\(.last_turn.input) out=\(.last_turn.output)" else empty end)
  ' "$CUMUL" 2>/dev/null || echo "  (failed to parse usage)"
fi

echo
echo "Note: section 1 is the compression lever only. It does NOT net out the prompt"
echo "tokens added by the oracle/coaching hooks, nor the reads prevented by the guards."
echo "Those are real effects this measurement cannot see — no single 'total saved' is shown."
echo "════════════════════════════════════════════════════════════"
