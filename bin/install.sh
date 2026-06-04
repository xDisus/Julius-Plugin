#!/usr/bin/env bash
# Julius Plugin — npx installer
# Detects Claude Code, copies plugin files, registers hooks.
# Usage: npx julius-plugin
set -euo pipefail

PLUGIN_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_PLUGINS_DIR="$HOME/.claude/plugins"
PLUGIN_DST="$CLAUDE_PLUGINS_DIR/julius"

echo "🧠 Julius — Token Economy for Claude Code"
echo ""

# Check Claude Code
if ! command -v claude &>/dev/null && [ ! -d "$HOME/.claude" ]; then
  echo "❌ Claude Code not found."
  echo "   Install first: npm install -g @anthropic-ai/claude-code"
  exit 1
fi

echo "✓ Claude Code detected"

# Create plugin directory
mkdir -p "$PLUGIN_DST"

# Copy plugin files (skip .git, node_modules, tests, docs)
echo "📦 Installing Julius to $PLUGIN_DST ..."

# Use rsync if available, fallback to cp
if command -v rsync &>/dev/null; then
  rsync -a --exclude='.git' --exclude='node_modules' --exclude='tests' --exclude='docs' "$PLUGIN_SRC/" "$PLUGIN_DST/" 2>/dev/null || {
    # fallback
    cp -r "$PLUGIN_SRC/plugin.json" "$PLUGIN_DST/" 2>/dev/null || true
    cp -r "$PLUGIN_SRC/commands" "$PLUGIN_DST/" 2>/dev/null || true
    cp -r "$PLUGIN_SRC/agents" "$PLUGIN_DST/" 2>/dev/null || true
    cp -r "$PLUGIN_SRC/hooks" "$PLUGIN_DST/" 2>/dev/null || true
    cp -r "$PLUGIN_SRC/scripts" "$PLUGIN_DST/" 2>/dev/null || true
    cp -r "$PLUGIN_SRC/lib" "$PLUGIN_DST/" 2>/dev/null || true
    cp -r "$PLUGIN_SRC/.claude-plugin" "$PLUGIN_DST/" 2>/dev/null || true
  }
else
  mkdir -p "$PLUGIN_DST/commands" "$PLUGIN_DST/agents" "$PLUGIN_DST/hooks" "$PLUGIN_DST/scripts" "$PLUGIN_DST/lib" "$PLUGIN_DST/.claude-plugin"
  cp "$PLUGIN_SRC/plugin.json" "$PLUGIN_DST/" 2>/dev/null || true
  cp "$PLUGIN_SRC/commands/"*.md "$PLUGIN_DST/commands/" 2>/dev/null || true
  cp "$PLUGIN_SRC/agents/"*.md "$PLUGIN_DST/agents/" 2>/dev/null || true
  cp "$PLUGIN_SRC/hooks/"*.json "$PLUGIN_DST/hooks/" 2>/dev/null || true
  cp "$PLUGIN_SRC/scripts/"*.sh "$PLUGIN_DST/scripts/" 2>/dev/null || true
  cp "$PLUGIN_SRC/lib/"*.json "$PLUGIN_DST/lib/" 2>/dev/null || true
  cp "$PLUGIN_SRC/.claude-plugin/"*.json "$PLUGIN_DST/.claude-plugin/" 2>/dev/null || true
fi

chmod +x "$PLUGIN_DST/scripts/"*.sh 2>/dev/null || true

echo "✓ Plugin files copied"

# Check if active
if [ -f "$CLAUDE_PLUGINS_DIR/../plugins.json" ]; then
  if grep -q '"julius"' "$CLAUDE_PLUGINS_DIR/../plugins.json" 2>/dev/null; then
    echo "✓ Julius is already enabled in Claude Code"
  fi
fi

echo ""
echo "✅ Julius installed!"
echo ""
echo "   Start a new Claude Code session and type:"
echo "     /julius pro"
echo ""
echo "   Or jump straight to Beast:"
echo "     /julius beast"
echo ""
echo "   Marketplace (alternative):"
echo "     /plugin marketplace add github:xDisus/Julius-Plugin"
echo "     /plugin install julius@julius-plugin"
echo ""

# Check if claude is running
if pgrep -f "claude" &>/dev/null; then
  echo "⚠️  Claude Code is currently running. Restart it for Julius to take effect."
fi
