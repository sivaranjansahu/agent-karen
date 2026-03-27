#!/usr/bin/env bash
# slack-send.sh — send a message to a Slack channel via chat.postMessage
# Usage: ./scripts/slack-send.sh "Your message here"

set -euo pipefail

AGENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$AGENT_DIR/state/slack.env"

MSG="${1:?Usage: slack-send.sh \"message\"}"

RESPONSE=$(curl -s -X POST "https://slack.com/api/chat.postMessage" \
  -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "{\"channel\": \"${SLACK_CHANNEL_ID}\", \"text\": $(python3 -c "import json,sys; print(json.dumps(sys.argv[1]))" "$MSG")}")

# Check Slack API response for errors
OK=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok', False))" 2>/dev/null || echo "False")
if [[ "$OK" != "True" ]]; then
  ERROR=$(echo "$RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('error', 'unknown'))" 2>/dev/null || echo "unknown")
  echo "✗ Slack send failed: $ERROR" >&2
  exit 1
fi

echo "✓ Slack sent"
