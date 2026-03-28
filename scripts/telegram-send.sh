#!/usr/bin/env bash
# telegram-send.sh — send a message to the user via Telegram
# Usage: ./scripts/telegram-send.sh "Your message here"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
source "$ROOT/lib/hub.sh"
AGENT_DIR=$(resolve_hub_dir) || exit 1
source "$AGENT_DIR/state/telegram.env"

MSG="${1:?Usage: telegram-send.sh \"message\"}"

curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "{\"chat_id\": ${TELEGRAM_CHAT_ID}, \"text\": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$MSG"), \"parse_mode\": \"Markdown\"}" \
  > /dev/null

echo "✓ Telegram sent"
