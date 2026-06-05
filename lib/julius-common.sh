#!/usr/bin/env bash
# julius-common.sh — shared helpers sourced by every Julius hook script.
# Centralizes: state-dir resolution, tier reading, config lookups, portable md5.
# Sourcing this keeps all hooks consistent so a contract change is fixed in one place.

# Plugin root: prefer the env var Claude Code sets, else derive from this file's location.
JULIUS_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# Honor a pre-set JULIUS_CONFIG (lets tests point at a temp tier-config); else default.
JULIUS_CONFIG="${JULIUS_CONFIG:-$JULIUS_PLUGIN_ROOT/lib/tier-config.json}"

# Resolve the project state dir consistently across ALL hooks and the tier setter.
# Priority: explicit override -> Claude Code project dir -> cwd. Coupling everything
# to one resolver fixes the bug where tier-setter wrote one place and hooks read another.
julius_state_dir() {
  if [ -n "${JULIUS_STATE_DIR:-}" ]; then
    printf '%s' "$JULIUS_STATE_DIR"
  elif [ -n "${CLAUDE_PLUGIN_DATA:-}" ]; then
    printf '%s' "$CLAUDE_PLUGIN_DATA"
  elif [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    printf '%s/.claude/julius' "$CLAUDE_PROJECT_DIR"
  else
    printf '%s/.claude/julius' "$(pwd)"
  fi
}

# Print the active tier, or return non-zero if Julius is inactive (no tier file).
julius_tier() {
  local f
  f="$(julius_state_dir)/active-tier"
  [ -f "$f" ] || return 1
  cat "$f"
}

# julius_config <tier> <jq-path-after-tier> <default>
# Example: julius_config beast .compress_output.threshold_lines 100
julius_config() {
  local tier="$1" path="$2" def="$3"
  [ -f "$JULIUS_CONFIG" ] || { printf '%s' "$def"; return; }
  local val
  val=$(jq -r ".\"$tier\"$path // empty" "$JULIUS_CONFIG" 2>/dev/null)
  [ -n "$val" ] && printf '%s' "$val" || printf '%s' "$def"
}

# Metrics dir — single home for all MEASURED numbers (compression deltas + usage).
# Under $HOME (not the per-project state dir) so stats aggregate across projects,
# matching metrics-stop.sh. Override with JULIUS_METRICS_DIR for tests.
julius_metrics_dir() {
  printf '%s' "${JULIUS_METRICS_DIR:-$HOME/.julius/metrics}"
}

# julius_record_compression <tool> <label> <orig_chars> <comp_chars> <note> [session]
# Best-effort append of ONE measured compression delta as JSONL. MUST NOT fail the
# caller: hooks run under `set -euo pipefail`, and losing a metric must never break
# the compression emit or drop tool output. Every failure path returns 0.
julius_record_compression() {
  local tool="$1" label="$2" orig="$3" comp="$4" note="$5" session="${6:-}"
  local dir f
  dir="$(julius_metrics_dir)" || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  f="$dir/compression.jsonl"
  jq -cn --arg tool "$tool" --arg label "$label" \
    --argjson orig "${orig:-0}" --argjson comp "${comp:-0}" \
    --arg note "$note" --arg session "$session" --arg ts "$(date -Iseconds)" \
    '{ts:$ts,session:$session,tool:$tool,label:$label,orig_chars:$orig,comp_chars:$comp,note:$note}' \
    >> "$f" 2>/dev/null || return 0
  return 0
}

# Portable md5 of stdin (Linux md5sum, macOS md5, fallback cksum).
julius_md5() {
  if command -v md5sum >/dev/null 2>&1; then
    md5sum | cut -d' ' -f1
  elif command -v md5 >/dev/null 2>&1; then
    md5 -q
  else
    cksum | cut -d' ' -f1
  fi
}

# Read all of stdin (empty string if a tty / nothing piped). Hooks receive JSON here.
julius_stdin() {
  [ -t 0 ] && return 0
  cat
}

# True when the argument is valid JSON. Hooks use this to no-op on malformed input
# instead of letting a downstream jq parse error abort under `set -euo pipefail`.
julius_is_json() {
  printf '%s' "$1" | jq -e . >/dev/null 2>&1
}

# julius_dedup <text> <label> [max] — in-session exact-repeat detection.
# Prints the stored label and returns 0 when <text> was seen earlier this session;
# otherwise records it (bounded to <max> entries, oldest evicted) and returns 1.
julius_dedup() {
  local text="$1" label="$2" max="${3:-50}"
  local dir hash f count
  dir="$(julius_state_dir)/dedup"
  hash=$(printf '%s' "$text" | julius_md5)
  f="$dir/$hash"
  if [ -f "$f" ]; then cat "$f"; return 0; fi
  mkdir -p "$dir"
  printf '%s' "$label" > "$f"
  count=$(ls -1 "$dir" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$count" -gt "$max" ] 2>/dev/null; then
    ls -1t "$dir" 2>/dev/null | tail -n +"$((max+1))" | while IFS= read -r old; do rm -f "$dir/$old"; done
  fi
  return 1
}
