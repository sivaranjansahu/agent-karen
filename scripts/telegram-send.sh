#!/usr/bin/env bash
# telegram-send.sh — send a message to the user via Telegram
# Usage: ./scripts/telegram-send.sh "Your message here"

set -euo pipefail

# Resolve project .agent/ dir: env var > pwd/.agent > error
if [[ -n "${KAREN_PROJECT_AGENT_DIR:-}" && -d "$KAREN_PROJECT_AGENT_DIR" ]]; then
  AGENT_DIR="$KAREN_PROJECT_AGENT_DIR"
elif [[ -d "$(pwd)/.agent" ]]; then
  AGENT_DIR="$(pwd)/.agent"
else
  echo "ERROR: No .agent/ directory found. Run from project root or set KAREN_PROJECT_AGENT_DIR." >&2
  exit 1
fi
source "$AGENT_DIR/state/telegram.env"

MSG="${1:?Usage: telegram-send.sh \"message\"}"

curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "{\"chat_id\": ${TELEGRAM_CHAT_ID}, \"text\": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$MSG"), \"parse_mode\": \"Markdown\"}" \
  > /dev/null

echo "✓ Telegram sent"
