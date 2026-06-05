#!/usr/bin/env bash
# flash-client.sh — Shared Flash LLM utility for Julius.
# Calls Anthropic Haiku with credentials from the environment.
# Usage: echo "prompt + content" | flash-client.sh [--model MODEL] [--max-tokens N]
set -euo pipefail

API_URL="https://api.anthropic.com/v1/messages"
MODEL="${JULIUS_FLASH_MODEL:-claude-3-5-haiku-latest}"
MAX_TOKENS="${JULIUS_FLASH_MAX_TOKENS:-512}"
TIMEOUT="${JULIUS_FLASH_TIMEOUT:-10}"

# Parse flags (order-independent).
while [ "$#" -ge 2 ]; do
  case "$1" in
    --model)      MODEL="$2"; shift 2 ;;
    --max-tokens) MAX_TOKENS="$2"; shift 2 ;;
    *) break ;;
  esac
done

# Locate API key: env first, then ~/.claude/.env, then ~/.claude/.env.local.
API_KEY="${ANTHROPIC_API_KEY:-}"
for ENV_FILE in "$HOME/.claude/.env" "$HOME/.claude/.env.local"; do
  [ -n "$API_KEY" ] && break
  [ -f "$ENV_FILE" ] || continue
  API_KEY=$(grep -E '^ANTHROPIC_API_KEY=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2-)
done

# Strip surrounding whitespace and quotes that commonly wrap .env values.
API_KEY="${API_KEY#"${API_KEY%%[![:space:]]*}"}"   # ltrim
API_KEY="${API_KEY%"${API_KEY##*[![:space:]]}"}"   # rtrim
API_KEY="${API_KEY%\"}"; API_KEY="${API_KEY#\"}"
API_KEY="${API_KEY%\'}"; API_KEY="${API_KEY#\'}"

if [ -z "$API_KEY" ]; then
  echo "ERROR: ANTHROPIC_API_KEY not found. Set it in env or ~/.claude/.env" >&2
  exit 1
fi

# Read stdin (the prompt + content to send).
INPUT=""
[ -t 0 ] || INPUT=$(cat)
[ -n "$INPUT" ] || exit 0

REQUEST=$(jq -n \
  --arg model "$MODEL" \
  --argjson max_tokens "$MAX_TOKENS" \
  --arg content "$INPUT" \
  '{model: $model, max_tokens: $max_tokens, messages: [{role: "user", content: $content}]}')

RESPONSE=$(curl -s -m "$TIMEOUT" \
  -H "Content-Type: application/json" \
  -H "x-api-key: $API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -d "$REQUEST" \
  "$API_URL" 2>/dev/null || echo '{"type":"error","error":{"message":"request failed"}}')

TYPE=$(echo "$RESPONSE" | jq -r '.type // "error"' 2>/dev/null)
if [ "$TYPE" = "error" ] || [ "$TYPE" = "null" ]; then
  ERROR_MSG=$(echo "$RESPONSE" | jq -r '.error.message // "API call failed"' 2>/dev/null)
  echo "ERROR: $ERROR_MSG" >&2
  exit 1
fi

TEXT=$(echo "$RESPONSE" | jq -r '.content[0].text // empty' 2>/dev/null)
[ -n "$TEXT" ] || exit 1
echo "$TEXT"
