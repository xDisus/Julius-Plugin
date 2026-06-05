#!/usr/bin/env bash
# julius-doctor.sh — Julius plugin diagnostic
# Checks: install, files, hooks, config, deps, env, distribution
# Returns [OK] [FAIL] [WARN] for each check.
# Usage: called by /julius-doctor command

RED='[31m'; GREEN='[32m'; YELLOW='[33m'; BOLD='[1m'; NC='[0m'
OKC=0; FAILC=0; WARNC=0

ok()  { printf "  \033${GREEN}[OK]\033${NC}   %s\n" "$1"; OKC=$((OKC+1)); }
fail(){ printf "  \033${RED}[FAIL]\033${NC} %s\n" "$1"; FAILC=$((FAILC+1)); }
warn(){ printf "  \033${YELLOW}[WARN]\033${NC} %s\n" "$1"; WARNC=$((WARNC+1)); }

# Resolve plugin root
ROOT=""
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  ROOT="$CLAUDE_PLUGIN_ROOT"
elif [ -f "$(cd "$(dirname "$0")" && pwd)/../plugin.json" ]; then
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi
if [ -z "$ROOT" ]; then
  for d in "$HOME/.claude/plugins/julius" "$HOME/.claude/plugins/cache/julius"; do
    [ -f "$d/plugin.json" ] && ROOT="$d" && break
  done
fi

echo ""
printf "\033${BOLD}🧠 Julius Doctor\033${NC}\n"
echo "   v1.0.0 — Token Economy Plugin"
echo ""

# ── INSTALL ──
echo ""
printf "\033${BOLD}═══ INSTALLATION ═══\033${NC}\n"

if [ -n "$ROOT" ] && [ -f "$ROOT/plugin.json" ]; then
  NAME=$(grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' "$ROOT/plugin.json" 2>/dev/null | head -1 | sed 's/.*: *"\(.*\)"/\1/')
  [ "$NAME" = "julius" ] && ok "Plugin found: $ROOT" || fail "Wrong plugin name: '$NAME'"
else
  fail "Plugin not found. Searched: CLAUDE_PLUGIN_ROOT, script dir, ~/.claude/plugins/"
  exit 1
fi

[ -f "$ROOT/commands/julius.md" ] && ok "Command: /julius" || fail "Command /julius missing"
[ -f "$ROOT/commands/julius-doctor.md" ] && ok "Command: /julius-doctor" || fail "Command /julius-doctor missing"
[ -f "$ROOT/commands/julius-stats.md" ] && ok "Command: /julius-stats" || fail "Command /julius-stats missing"

# ── FILES ──
echo ""
printf "\033${BOLD}═══ FILES & STRUCTURE ═══\033${NC}\n"

for f in "plugin.json" "hooks/hooks.json" "lib/tier-config.json" "lib/julius-common.sh" "lib/julius-compress.sh"; do
  [ -f "$ROOT/$f" ] && ok "${f##*/} ($f)" || fail "${f##*/} missing ($f)"
done

for a in "tier-router" "julius-reader" "julius-executor" "julius-researcher"; do
  [ -f "$ROOT/agents/$a.md" ] && ok "Agent: $a" || fail "Agent: $a missing"
done

SCRIPTS="flash-client.sh tier-setter.sh turn-coach.sh task-manifest.sh compress-output.sh large-file-guard.sh read-grep-guard.sh coach-patterns.sh batch-synthesizer.sh oracle-preprocess.sh keep-busy.sh metrics-stop.sh julius-doctor.sh julius-stats.sh"
for s in $SCRIPTS; do
  if [ -f "$ROOT/scripts/$s" ]; then
    [ -x "$ROOT/scripts/$s" ] && ok "${s%.sh} — executable" || warn "${s%.sh} — NOT executable"
  else
    fail "${s%.sh} — missing"
  fi
done

# ── HOOKS ──
echo ""
printf "\033${BOLD}═══ HOOKS VALIDATION ═══\033${NC}\n"

HOOKS="$ROOT/hooks/hooks.json"
if [ -f "$HOOKS" ]; then
  REQUIRED="UserPromptSubmit PreToolUse PostToolUse PostToolBatch Stop TeammateIdle TaskCreated TaskCompleted"
  for h in $REQUIRED; do
    if grep -q "\"$h\"" "$HOOKS" 2>/dev/null; then
      ok "Hook: $h"
    else
      fail "Hook: $h not found"
    fi
  done
else
  fail "hooks.json missing"
fi

# ── CONFIG ──
echo ""
printf "\033${BOLD}═══ CONFIGURATION ═══\033${NC}\n"

CONFIG="$ROOT/lib/tier-config.json"
if [ -f "$CONFIG" ]; then
  for tier in "normal" "pro" "beast"; do
    if grep -q "\"$tier\"" "$CONFIG" 2>/dev/null; then
      LABEL=$(grep "\"label\"" "$CONFIG" 2>/dev/null | head -1 | sed 's/.*: *"\(.*\)".*/\1/')
      ok "Tier: $tier"
    else
      fail "Tier '$tier' — missing"
    fi
  done
else
  fail "tier-config.json missing"
fi

# ── DEPS ──
echo ""
printf "\033${BOLD}═══ DEPENDENCIES ═══\033${NC}\n"

for cmd in jq curl git; do
  if command -v "$cmd" >/dev/null 2>&1; then
    ok "$cmd available"
  else
    fail "$cmd not found"
  fi
done

# ── ENV ──
echo ""
printf "\033${BOLD}═══ ENVIRONMENT ═══\033${NC}\n"

if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  ok "ANTHROPIC_API_KEY set"
elif [ -f "$HOME/.claude/.env" ]; then
  grep -q 'ANTHROPIC_API_KEY=' "$HOME/.claude/.env" 2>/dev/null && ok "ANTHROPIC_API_KEY in ~/.claude/.env" || warn "ANTHROPIC_API_KEY not found — Pro+/Beast limited"
else
  warn "ANTHROPIC_API_KEY not set"
fi

STATE_DIR="${CLAUDE_PLUGIN_DATA:-$(pwd)/.claude/julius}"
TIER_FILE="$STATE_DIR/active-tier"
if [ -f "$TIER_FILE" ]; then
  ok "Active tier: $(cat "$TIER_FILE")"
else
  warn "Tier not set — run /julius pro"
fi

# ── COMPAT ──
echo ""
printf "\033${BOLD}═══ COMPATIBILITY ═══\033${NC}\n"

# Check caveman (JuliusBrussee/caveman) — external output compressor
CAVEMAN_DIR=""
for d in "$HOME/.claude/plugins/caveman" "$HOME/.claude/plugins/cache/caveman" "$HOME/.claude/skills/caveman"; do
  [ -d "$d" ] && CAVEMAN_DIR="$d" && break
done
# Also check for /caveman command via Claude Code commands
if [ -n "$CAVEMAN_DIR" ]; then
  ok "caveman (JuliusBrussee) installed → output compression synergy"
elif [ -f "$HOME/.claude/commands/caveman.md" ]; then
  ok "caveman (JuliusBrussee) installed → output compression synergy"
elif command -v caveman >/dev/null 2>&1; then
  ok "caveman CLI found → output compression synergy"
else
  warn "caveman (JuliusBrussee) not found → install for output compression: curl -fsSL https://raw.githubusercontent.com/JuliusBrussee/caveman/main/install.sh | bash"
fi

# Check context-mode (mksglu/context-mode)
CTX_MODE_DIR=""
for d in "$HOME/.claude/plugins/context-mode" "$HOME/.claude/plugins/cache/context-mode"; do
  [ -d "$d" ] && CTX_MODE_DIR="$d" && break
done
if [ -n "$CTX_MODE_DIR" ]; then
  ok "context-mode installed → full synergy (output sandbox + hook compression)"
else
  warn "context-mode not found — install for output sandboxing: /plugin install context-mode@context-mode"
fi

# Check Julius workers (internal compressed agents, inspired by caveman style)
WORKERS_OK=0
for agent in "julius-reader" "julius-executor" "julius-researcher"; do
  if grep -q "name: $agent" "$ROOT/agents/$agent.md" 2>/dev/null; then
    WORKERS_OK=$((WORKERS_OK + 1))
  fi
done
if [ "$WORKERS_OK" -eq 3 ]; then
  ok "Julius workers: all 3 valid (reader, executor, researcher)"
elif [ "$WORKERS_OK" -gt 0 ]; then
  warn "Julius workers: $WORKERS_OK/3 valid"
else
  fail "Julius workers: none valid"
fi

# Check tier-router agent
if grep -q "name: tier-router" "$ROOT/agents/tier-router.md" 2>/dev/null; then
  ok "Agent tier-router: haiku worker valid"
else
  fail "Agent tier-router: missing or invalid"
fi

# ── DIST ──
echo ""
printf "\033${BOLD}═══ DISTRIBUTION ═══\033${NC}\n"

[ -f "$ROOT/.claude-plugin/marketplace.json" ] && ok "Marketplace manifest" || warn "No marketplace manifest"
[ -f "$ROOT/package.json" ] && ok "npm package.json" || warn "No package.json — npx unavailable"

# ── SUMMARY ──
echo ""
printf "\033${BOLD}═══ SUMMARY ═══\033${NC}\n"
TOTAL=$((OKC + FAILC + WARNC))
echo ""
if [ "$FAILC" -eq 0 ] && [ "$WARNC" -eq 0 ]; then
  printf "  ✅ All %d checks passed\n" "$OKC"
elif [ "$FAILC" -eq 0 ]; then
  printf "  ⚠️  %d warnings, %d passed (%d total)\n" "$WARNC" "$OKC" "$TOTAL"
else
  printf "  ❌ %d failed, %d warnings, %d passed (%d total)\n" "$FAILC" "$WARNC" "$OKC" "$TOTAL"
fi
echo ""
echo "  Quick start:"
echo "    /julius normal   — zero quality loss"
echo "    /julius pro      — balanced compression"
echo "    /julius beast    — max savings"
echo ""

[ "$FAILC" -eq 0 ] && exit 0
exit 1
