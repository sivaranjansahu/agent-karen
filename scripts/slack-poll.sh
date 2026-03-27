#!/usr/bin/env bash
# slack-poll.sh — poll for new Slack messages and write to inbox
# Usage: ./scripts/slack-poll.sh [once|loop]
# "once" checks once, "loop" polls every 3s

set -euo pipefail

AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$AGENT_DIR/state/slack.env"

CURSOR_FILE="$AGENT_DIR/state/slack_cursor"
INBOX="$AGENT_DIR/inbox/manager.jsonl"
IMAGE_DIR="/tmp/slack-images"
mkdir -p "$IMAGE_DIR"
MODE="${1:-once}"

get_oldest() {
  if [[ -f "$CURSOR_FILE" ]]; then
    cat "$CURSOR_FILE"
  else
    echo "0"
  fi
}

poll_once() {
  local OLDEST=$(get_oldest)
  local RESP=$(curl -s -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
    "https://slack.com/api/conversations.history?channel=${SLACK_CHANNEL_ID}&oldest=${OLDEST}&limit=100" 2>/dev/null || echo '{"ok":false}')

  local OK=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok', False))" 2>/dev/null || echo "False")
  if [[ "$OK" != "True" ]]; then
    return 0
  fi

  # Parse messages and advance cursor (even for bot-only batches)
  # Also extract file download URLs for image support
  local RESULT=$(echo "$RESP" | python3 -c "
import sys, json, datetime, os
data = json.load(sys.stdin)
max_ts = '0'
human_lines = []
file_downloads = []  # (url_private, filename) pairs to download
for msg in sorted(data.get('messages', []), key=lambda m: m.get('ts', '0')):
    max_ts = max(max_ts, msg.get('ts', '0'))
    if msg.get('user') == '${SLACK_BOT_USER_ID}' or 'bot_id' in msg:
        continue
    text = msg.get('text', '')
    images = []
    for f in msg.get('files', []):
        mimetype = f.get('mimetype', '')
        if mimetype.startswith('image/'):
            url = f.get('url_private', '')
            fname = f.get('name', f.get('id', 'image'))
            ts_str = msg.get('ts', '0').replace('.', '_')
            local_name = f'{ts_str}_{fname}'
            if url:
                file_downloads.append((url, local_name))
                images.append('${IMAGE_DIR}/' + local_name)
    if text or images:
        ts = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        body = text
        if images:
            body = (body + '\n' if body else '') + 'Images: ' + ', '.join(images)
        human_lines.append(json.dumps({'from': 'user-slack', 'type': 'message', 'ts': ts, 'body': body}))
print(f'COUNT:{len(human_lines)}')
print(f'CURSOR:{max_ts}')
print(f'FILES:{len(file_downloads)}')
for url, fname in file_downloads:
    print(f'DOWNLOAD:{url}|{fname}')
for line in human_lines:
    print(line)
" 2>/dev/null || echo "COUNT:0")

  local COUNT=$(echo "$RESULT" | grep "^COUNT:" | cut -d: -f2)
  local NEW_CURSOR=$(echo "$RESULT" | grep "^CURSOR:" | cut -d: -f2)
  # Always advance cursor if there were any messages (prevents re-fetching bot msgs)
  [[ -n "$NEW_CURSOR" && "$NEW_CURSOR" != "0" ]] && echo "$NEW_CURSOR" > "$CURSOR_FILE"

  # Download any image files from Slack
  echo "$RESULT" | grep "^DOWNLOAD:" | while IFS= read -r dl_line; do
    local URL_FNAME="${dl_line#DOWNLOAD:}"
    local DL_URL="${URL_FNAME%%|*}"
    local DL_FNAME="${URL_FNAME#*|}"
    curl -s -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
      -o "$IMAGE_DIR/$DL_FNAME" "$DL_URL" 2>/dev/null || true
  done

  if [[ "$COUNT" -gt 0 ]]; then
    echo "$RESULT" | grep -v "^COUNT:" | grep -v "^CURSOR:" | grep -v "^FILES:" | grep -v "^DOWNLOAD:" >> "$INBOX"
    echo "📬 $COUNT new Slack message(s)"
  fi
}

if [[ "$MODE" == "loop" ]]; then
  echo "Polling Slack every 3s... (Ctrl+C to stop)"
  while true; do
    poll_once
    sleep 3
  done
else
  poll_once
fi
