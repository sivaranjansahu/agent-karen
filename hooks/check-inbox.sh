#!/usr/bin/env bash
# check-inbox.sh — UserPromptSubmit hook: surface new inbox messages to the agent
#
# Runs before every Claude response. Checks for unread messages in the
# agent's inbox and outputs them so Claude sees them in context.

# Determine agent identity
AGENT_ID="${KAREN_AGENT_ID:-}"
if [[ -z "$AGENT_ID" ]]; then
  ROLE="${AGENT_ROLE:-}"
  [[ -z "$ROLE" ]] && exit 0
  if [[ -n "${KAREN_PROJECT_KEY:-}" ]]; then
    AGENT_ID="${KAREN_PROJECT_KEY}-${ROLE}"
  else
    AGENT_ID="$ROLE"
  fi
fi

# Determine hub directory
HUB_DIR="${KAREN_HUB_DIR:-}"
if [[ -z "$HUB_DIR" ]]; then
  if [[ -n "${KAREN_PROJECT_AGENT_DIR:-}" && -d "$KAREN_PROJECT_AGENT_DIR" ]]; then
    HUB_DIR="$KAREN_PROJECT_AGENT_DIR"
  elif [[ -d "$(pwd)/.agent" ]]; then
    HUB_DIR="$(pwd)/.agent"
  else
    exit 0
  fi
fi

# Resolve scaffold root for integration scripts
if [[ -n "${AGENT_SCAFFOLD_ROOT:-}" ]]; then
  SCAFFOLD="$AGENT_SCAFFOLD_ROOT"
elif [[ -L "$HUB_DIR/scripts" ]]; then
  SCAFFOLD="$(cd "$(readlink "$HUB_DIR/scripts")/.." && pwd)"
else
  SCAFFOLD=""
fi

# Poll Telegram — skip if daemon is running
TG_PID_FILE="$HUB_DIR/state/telegram_daemon.pid"
TG_POLL="${SCAFFOLD:+$SCAFFOLD/scripts/telegram-poll.sh}"
if [[ -n "$TG_POLL" && -x "$TG_POLL" ]]; then
  if [[ -f "$TG_PID_FILE" ]] && kill -0 "$(cat "$TG_PID_FILE")" 2>/dev/null; then
    :
  else
    "$TG_POLL" once 2>/dev/null || true
  fi
fi

# Poll Slack — skip if daemon is running
SLACK_PID_FILE="$HUB_DIR/state/slack_daemon.pid"
SLACK_POLL="${SCAFFOLD:+$SCAFFOLD/scripts/slack-poll.sh}"
if [[ -n "$SLACK_POLL" && -x "$SLACK_POLL" ]]; then
  if [[ -f "$SLACK_PID_FILE" ]] && kill -0 "$(cat "$SLACK_PID_FILE")" 2>/dev/null; then
    :
  else
    "$SLACK_POLL" once 2>/dev/null || true
  fi
fi

INBOX="$HUB_DIR/inbox/${AGENT_ID}.jsonl"
[[ -f "$INBOX" ]] || exit 0

CURSOR_FILE="$HUB_DIR/state/${AGENT_ID}_inbox_cursor"
TOTAL_LINES=$(wc -l < "$INBOX" | tr -d ' ')

CURSOR=0
if [[ -f "$CURSOR_FILE" ]]; then
  CURSOR=$(cat "$CURSOR_FILE")
fi

if [[ "$TOTAL_LINES" -le "$CURSOR" ]]; then
  exit 0
fi

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

echo "$TOTAL_LINES" > "$CURSOR_FILE"
