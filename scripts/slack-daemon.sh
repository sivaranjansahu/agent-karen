#!/usr/bin/env bash
# slack-daemon.sh — Slack poller + wake daemon for Karen
# Runs independently of Claude sessions. Polls every 3s, writes to inbox, wakes cmux.
# Usage: slack-daemon.sh {start|stop|status}

set -euo pipefail

AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$AGENT_DIR/state/slack.env"

CURSOR_FILE="$AGENT_DIR/state/slack_cursor"
INBOX="$AGENT_DIR/inbox/manager.jsonl"
PID_FILE="$AGENT_DIR/state/slack_daemon.pid"
LOG_FILE="$AGENT_DIR/state/slack_daemon.log"
IMAGE_DIR="/tmp/slack-images"
POLL_INTERVAL=3

is_running() {
  [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null
}

cmd_start() {
  if is_running; then
    echo "[slack-daemon] Already running (PID $(cat "$PID_FILE"))"
    exit 0
  fi

  # Daemonize: run the poll loop in background
  _run_loop &
  local DAEMON_PID=$!
  echo "$DAEMON_PID" > "$PID_FILE"
  echo "[slack-daemon] Started (PID $DAEMON_PID, polling every ${POLL_INTERVAL}s)"
  echo "[slack-daemon] Log: $LOG_FILE"
}

cmd_stop() {
  if ! is_running; then
    echo "[slack-daemon] Not running"
    rm -f "$PID_FILE"
    exit 0
  fi
  local PID=$(cat "$PID_FILE")
  kill "$PID" 2>/dev/null || true
  rm -f "$PID_FILE"
  echo "[slack-daemon] Stopped (PID $PID)"
}

cmd_status() {
  if is_running; then
    echo "[slack-daemon] Running (PID $(cat "$PID_FILE"))"
  else
    echo "[slack-daemon] Not running"
    rm -f "$PID_FILE"
  fi
}

get_oldest() {
  [[ -f "$CURSOR_FILE" ]] && cat "$CURSOR_FILE" || echo "0"
}

_run_loop() {
  # Write PID for clean shutdown
  trap "rm -f '$PID_FILE'; exit 0" SIGTERM SIGINT

  mkdir -p "$IMAGE_DIR"
  echo "[slack-daemon] Started (PID $$, polling every ${POLL_INTERVAL}s)" >> "$LOG_FILE"

  while true; do
    OLDEST=$(get_oldest)
    RESP=$(curl -s --max-time 10 -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
      "https://slack.com/api/conversations.history?channel=${SLACK_CHANNEL_ID}&oldest=${OLDEST}&limit=100" 2>/dev/null || echo '{"ok":false}')

    OK=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok', False))" 2>/dev/null || echo "False")

    if [[ "$OK" == "True" ]]; then
      # Parse messages and advance cursor (even for bot-only batches)
      # Also extract file download URLs for image support
      RESULT=$(echo "$RESP" | python3 -c "
import sys, json, datetime
data = json.load(sys.stdin)
max_ts = '0'
human_lines = []
file_downloads = []
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

      COUNT=$(echo "$RESULT" | grep "^COUNT:" | cut -d: -f2)
      NEW_CURSOR=$(echo "$RESULT" | grep "^CURSOR:" | cut -d: -f2)
      # Always advance cursor if there were any messages (prevents re-fetching bot msgs)
      [[ -n "$NEW_CURSOR" && "$NEW_CURSOR" != "0" ]] && echo "$NEW_CURSOR" > "$CURSOR_FILE"

      # Download any image files from Slack
      echo "$RESULT" | grep "^DOWNLOAD:" | while IFS= read -r dl_line; do
        URL_FNAME="${dl_line#DOWNLOAD:}"
        DL_URL="${URL_FNAME%%|*}"
        DL_FNAME="${URL_FNAME#*|}"
        curl -s -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
          -o "$IMAGE_DIR/$DL_FNAME" "$DL_URL" 2>/dev/null || true
      done

      if [[ "$COUNT" -gt 0 ]]; then
        # Write human messages to inbox (skip header/download lines)
        echo "$RESULT" | grep -v "^COUNT:" | grep -v "^CURSOR:" | grep -v "^FILES:" | grep -v "^DOWNLOAD:" >> "$INBOX"

        echo "[slack-daemon] $(date -u +%Y-%m-%dT%H:%M:%SZ) 📬 $COUNT new message(s) — acking + waking manager" >> "$LOG_FILE"

        # Auto-ack immediately so user knows message was received
        "$AGENT_DIR/scripts/slack-send.sh" "Received. Processing..." 2>/dev/null || true

        # Wake the manager terminal via cmux
        MANAGER_WS_FILE="$AGENT_DIR/state/manager_workspace"
        if [[ -f "$MANAGER_WS_FILE" ]]; then
          WS_ID=$(cat "$MANAGER_WS_FILE")
          PROMPT="📬 New Slack message. Check inbox and respond via slack-send.sh."
          cmux send --workspace "$WS_ID" "${PROMPT}"$'\n' 2>/dev/null || true
        fi
      fi
    fi

    sleep "$POLL_INTERVAL"
  done
}

# Main — dispatch subcommand
CMD="${1:-start}"
case "$CMD" in
  start)  cmd_start ;;
  stop)   cmd_stop ;;
  status) cmd_status ;;
  *)
    echo "Usage: slack-daemon.sh {start|stop|status}" >&2
    exit 1
    ;;
esac
