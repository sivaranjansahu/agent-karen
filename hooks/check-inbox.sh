#!/usr/bin/env bash
# check-inbox.sh — UserPromptSubmit hook: surface new inbox messages to the agent
#
# Runs before every Claude response. Checks for unread messages in the
# agent's inbox and outputs them so Claude sees them in context.
#
# This is the reliable wake mechanism — no terminal typing needed.

ROLE="${AGENT_ROLE:-}"
[[ -z "$ROLE" ]] && exit 0

# Poll Telegram for new messages — but SKIP if daemon is already running (avoids cursor race)
TELEGRAM_PID_FILE=".agent/state/telegram_daemon.pid"
TELEGRAM_POLL=".agent/scripts/telegram-poll.sh"
if [[ -x "$TELEGRAM_POLL" ]]; then
  if [[ -f "$TELEGRAM_PID_FILE" ]] && kill -0 "$(cat "$TELEGRAM_PID_FILE")" 2>/dev/null; then
    : # daemon is running, skip manual poll
  else
    "$TELEGRAM_POLL" once 2>/dev/null || true
  fi
fi

# Poll Slack for new messages — but SKIP if daemon is already running (avoids cursor race)
SLACK_PID_FILE=".agent/state/slack_daemon.pid"
SLACK_POLL=".agent/scripts/slack-poll.sh"
if [[ -x "$SLACK_POLL" ]]; then
  if [[ -f "$SLACK_PID_FILE" ]] && kill -0 "$(cat "$SLACK_PID_FILE")" 2>/dev/null; then
    : # daemon is running, skip manual poll
  else
    "$SLACK_POLL" once 2>/dev/null || true
  fi
fi

INBOX=".agent/inbox/${ROLE}.jsonl"
[[ -f "$INBOX" ]] || exit 0

CURSOR_FILE=".agent/state/${ROLE}_inbox_cursor"
TOTAL_LINES=$(wc -l < "$INBOX" | tr -d ' ')

# Read cursor (last processed line number)
CURSOR=0
if [[ -f "$CURSOR_FILE" ]]; then
  CURSOR=$(cat "$CURSOR_FILE")
fi

# Any new messages?
if [[ "$TOTAL_LINES" -le "$CURSOR" ]]; then
  exit 0  # No new messages
fi

# Output new messages for Claude to see
NEW_COUNT=$((TOTAL_LINES - CURSOR))
echo ""
echo "📬 $NEW_COUNT new message(s) in your inbox:"
echo ""
tail -n "$NEW_COUNT" "$INBOX" | while IFS= read -r line; do
  FROM=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('from','?'))" 2>/dev/null)
  TYPE=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('type','?'))" 2>/dev/null)
  BODY=$(echo "$line" | python3 -c "import sys,json; print(json.load(sys.stdin).get('body',''))" 2>/dev/null)
  echo "  [$TYPE from $FROM]: $BODY"
done
echo ""

# Update cursor
echo "$TOTAL_LINES" > "$CURSOR_FILE"
