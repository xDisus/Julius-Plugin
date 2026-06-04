#!/usr/bin/env bash
# flash-client.sh — Shared Flash LLM utility for Julius
# Calls Anthropic Haiku API using credentials from the environment.
# Usage: echo "prompt + content" | flash-client.sh [--model claude-3-5-haiku-latest]
set -euo pipefail

API_URL="https://api.anthropic.com/v1/messages"
MODEL="${JULIUS_FLASH_MODEL:-claude-3-5-haiku-latest}"
MAX_TOKENS=512
TIMEOUT=10

# Override model if --model flag
if [ "$#" -ge 2 ] && [ "$1" = "--model" ]; then
  MODEL="$2"
fi

# Locate API key
API_KEY="${ANTHROPIC_API_KEY:-}"
if [ -z "$API_KEY" ]; then
  # Try .claude/.env
  ENV_FILE="$HOME/.claude/.env"
  if [ -f "$ENV_FILE" ]; then
    API_KEY=$(grep -E '^ANTHROPIC_API_KEY=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
  fi
fi
if [ -z "$API_KEY" ]; then
  # Try ~/.claude/config.yaml or .env
  ENV_FILE2="$HOME/.claude/.env.local"
  if [ -f "$ENV_FILE2" ]; then
    API_KEY=$(grep -E '^ANTHROPIC_API_KEY=' "$ENV_FILE2" 2>/dev/null | head -1 | cut -d= -f2-)
  fi
fi

if [ -z "$API_KEY" ]; then
  echo "ERROR: ANTHROPIC_API_KEY not found. Set it in env or ~/.claude/.env" >&2
  exit 1
fi

# Read stdin
INPUT=""
if [ ! -t 0 ]; then
  INPUT=$(cat)
fi

if [ -z "$INPUT" ]; then
  exit 0
fi

# Build request payload
REQUEST=$(jq -n \
  --arg model "$MODEL" \
  --arg max_tokens "$MAX_TOKENS" \
  --arg content "$INPUT" \
  '{
    "model": $model,
    "max_tokens": ($max_tokens | tonumber),
    "messages": [{"role": "user", "content": $content}]
  }')

# Call API
RESPONSE=$(curl -s -m "$TIMEOUT" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -d "$REQUEST" \
  "$API_URL" 2>/dev/null || echo '{"type":"error","content":"timeout"}')

# Check for API error
CONTENT_TYPE=$(echo "$RESPONSE" | jq -r '.type // "error"' 2>/dev/null)
if [ "$CONTENT_TYPE" = "error" ] || [ "$CONTENT_TYPE" = "null" ]; then
  ERROR_MSG=$(echo "$RESPONSE" | jq -r '.error.message // .content // "API call failed"' 2>/dev/null)
  echo "ERROR: $ERROR_MSG" >&2
  exit 1
fi

# Extract text response
TEXT=$(echo "$RESPONSE" | jq -r '.content[0].text // empty' 2>/dev/null)
if [ -z "$TEXT" ]; then
  exit 1
fi

echo "$TEXT"
