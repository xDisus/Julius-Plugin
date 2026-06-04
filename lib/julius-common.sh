#!/usr/bin/env bash
# julius-common.sh — shared helpers sourced by every Julius hook script.
# Centralizes: state-dir resolution, tier reading, config lookups, portable md5.
# Sourcing this keeps all hooks consistent so a contract change is fixed in one place.

# Plugin root: prefer the env var Claude Code sets, else derive from this file's location.
JULIUS_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
JULIUS_CONFIG="$JULIUS_PLUGIN_ROOT/lib/tier-config.json"

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
