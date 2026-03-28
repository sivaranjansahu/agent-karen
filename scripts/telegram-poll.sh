#!/usr/bin/env bash
# telegram-poll.sh — poll for new Telegram messages and write to inbox
# Usage: ./scripts/telegram-poll.sh [once|loop]
# "once" checks once, "loop" polls every 10s

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
source "$ROOT/lib/hub.sh"
AGENT_DIR=$(resolve_hub_dir) || exit 1
source "$AGENT_DIR/state/telegram.env"

OFFSET_FILE="$AGENT_DIR/state/telegram_offset"
INBOX="$AGENT_DIR/inbox/manager.jsonl"
MODE="${1:-once}"

get_offset() {
  if [[ -f "$OFFSET_FILE" ]]; then
    cat "$OFFSET_FILE"
  else
    echo "0"
  fi
}

poll_once() {
  local OFFSET=$(get_offset)
  local RESP=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=${OFFSET}&timeout=5")
  local COUNT=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('result',[])))" 2>/dev/null || echo "0")

  if [[ "$COUNT" -gt 0 ]]; then
    echo "$RESP" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for update in data.get('result', []):
    msg = update.get('message', {})
    text = msg.get('text', '')
    if text:
        print(json.dumps({
            'from': 'user-telegram',
            'type': 'message',
            'ts': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
            'body': text
        }))
    # Print the next offset
    print('OFFSET:' + str(update['update_id'] + 1), file=sys.stderr)
" >> "$INBOX" 2>/tmp/tg_offset

    # Update offset
    local NEW_OFFSET=$(grep "OFFSET:" /tmp/tg_offset 2>/dev/null | tail -1 | cut -d: -f2)
    if [[ -n "$NEW_OFFSET" ]]; then
      echo "$NEW_OFFSET" > "$OFFSET_FILE"
    fi
    echo "📬 $COUNT new Telegram message(s)"
  fi
}

if [[ "$MODE" == "loop" ]]; then
  echo "Polling Telegram every 10s... (Ctrl+C to stop)"
  while true; do
    poll_once
    sleep 10
  done
else
  poll_once
fi
