#!/usr/bin/env bash
# telegram-daemon.sh — standalone Telegram poller + wake daemon
# Runs independently of Claude sessions. Polls every 5s, writes to inbox, wakes cmux.
# Usage: .agent/scripts/telegram-daemon.sh
# Stop: kill $(cat .agent/state/telegram_daemon.pid)

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

OFFSET_FILE="$AGENT_DIR/state/telegram_offset"
INBOX="$AGENT_DIR/inbox/manager.jsonl"
PID_FILE="$AGENT_DIR/state/telegram_daemon.pid"
POLL_INTERVAL=5

# Write PID for clean shutdown
echo $$ > "$PID_FILE"
trap "rm -f '$PID_FILE'; exit 0" SIGTERM SIGINT

echo "[telegram-daemon] Started (PID $$, polling every ${POLL_INTERVAL}s)"

get_offset() {
  [[ -f "$OFFSET_FILE" ]] && cat "$OFFSET_FILE" || echo "0"
}

while true; do
  OFFSET=$(get_offset)
  RESP=$(curl -s --max-time 10 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=${OFFSET}&timeout=${POLL_INTERVAL}" 2>/dev/null || echo '{"ok":false}')

  COUNT=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len([r for r in d.get('result',[]) if 'message' in r and 'text' in r['message']]))" 2>/dev/null || echo "0")

  if [[ "$COUNT" -gt 0 ]]; then
    # Write messages to inbox
    echo "$RESP" | python3 -c "
import sys, json, datetime
data = json.load(sys.stdin)
max_id = 0
for update in data.get('result', []):
    msg = update.get('message', {})
    text = msg.get('text', '')
    if text:
        ts = datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')
        print(json.dumps({'from': 'user-telegram', 'type': 'message', 'ts': ts, 'body': text}))
    max_id = max(max_id, update['update_id'])
print(f'OFFSET:{max_id + 1}', file=sys.stderr)
" >> "$INBOX" 2>/tmp/tg_daemon_offset

    # Update offset
    NEW_OFFSET=$(grep "OFFSET:" /tmp/tg_daemon_offset 2>/dev/null | tail -1 | cut -d: -f2)
    [[ -n "$NEW_OFFSET" ]] && echo "$NEW_OFFSET" > "$OFFSET_FILE"

    echo "[telegram-daemon] 📬 $COUNT new message(s) — waking manager"

    # Wake the manager terminal via cmux
    MANAGER_WS_FILE="$AGENT_DIR/state/manager_workspace"
    if [[ -f "$MANAGER_WS_FILE" ]]; then
      WS_ID=$(cat "$MANAGER_WS_FILE")
      PROMPT="📬 New Telegram message. Check inbox and respond via telegram-send.sh."
      cmux send --workspace "$WS_ID" "${PROMPT}"$'\n' 2>/dev/null || true
    fi
  fi

  # Use long-polling timeout instead of sleep (already waited via Telegram API timeout)
done
