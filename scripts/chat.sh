#!/usr/bin/env bash
# chat.sh — Post or read messages from Mattermost shared channels
#
# Usage:
#   ./scripts/chat.sh post "<message>" [channel]     # default: general
#   ./scripts/chat.sh read [channel] [count]          # default: general, 20
#   ./scripts/chat.sh listen [channel]                # tail new messages (polling)
#
# Requires: .agent/state/mattermost.env (created by mattermost/setup.sh)
#
# Examples:
#   ./scripts/chat.sh post "dev1: Starting work on auth module"
#   ./scripts/chat.sh post "BLOCKED: need DB schema" escalations
#   ./scripts/chat.sh read general 10
#   ./scripts/chat.sh listen tasks

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
ENV_FILE="$ROOT/.agent/state/mattermost.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "✗ Mattermost not configured. Run: ./mattermost/setup.sh"
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

if [[ -z "${MM_BOT_TOKEN:-}" || "$MM_BOT_TOKEN" == "PASTE_TOKEN_HERE" ]]; then
  echo "✗ MM_BOT_TOKEN not set in $ENV_FILE"
  exit 1
fi

FROM="${AGENT_ROLE:-user}"
CMD="${1:?Usage: chat.sh <post|read|listen> ...}"
shift

mm_api() {
  local method="$1" endpoint="$2"
  shift 2
  curl -sf -X "$method" \
    -H "Authorization: Bearer $MM_BOT_TOKEN" \
    -H "Content-Type: application/json" \
    "$MM_URL/api/v4$endpoint" "$@"
}

# Resolve channel name → ID using env vars, cache, or API fallback
get_channel_id() {
  local channel_name="$1"

  # 1. Check pre-resolved IDs from env (set by setup.sh)
  local env_var="MM_CHANNEL_ID_$(echo "$channel_name" | tr '[:lower:]' '[:upper:]')"
  local env_val="${!env_var:-}"
  if [[ -n "$env_val" ]]; then
    echo "$env_val"
    return
  fi

  # 2. Check file cache
  local cache_file="$ROOT/.agent/state/mm_channel_${channel_name}"
  if [[ -f "$cache_file" ]]; then
    cat "$cache_file"
    return
  fi

  # 3. API fallback
  local team_id="${MM_TEAM_ID:-}"
  if [[ -z "$team_id" ]]; then
    team_id=$(mm_api GET "/teams/name/$MM_TEAM" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
  fi
  local channel_id
  channel_id=$(mm_api GET "/teams/$team_id/channels/name/$channel_name" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
  echo "$channel_id" > "$cache_file"
  echo "$channel_id"
}

case "$CMD" in
  post)
    MESSAGE="${1:?Usage: chat.sh post \"<message>\" [channel]}"
    CHANNEL="${2:-$MM_CHANNEL_GENERAL}"
    CHANNEL_ID=$(get_channel_id "$CHANNEL")

    # Prefix with role name for context
    FULL_MSG="**[$FROM]** $MESSAGE"

    PAYLOAD=$(python3 -c "
import json, sys
print(json.dumps({'channel_id': sys.argv[1], 'message': sys.argv[2]}))
" "$CHANNEL_ID" "$FULL_MSG")

    mm_api POST "/posts" -d "$PAYLOAD" > /dev/null
    echo "▸ Posted to #$CHANNEL"
    ;;

  read)
    CHANNEL="${1:-$MM_CHANNEL_GENERAL}"
    COUNT="${2:-20}"
    CHANNEL_ID=$(get_channel_id "$CHANNEL")

    mm_api GET "/channels/$CHANNEL_ID/posts?per_page=$COUNT" | python3 -c "
import json, sys
data = json.load(sys.stdin)
posts = data.get('posts', {})
order = data.get('order', [])
# Reverse to show oldest first
for post_id in reversed(order):
    p = posts[post_id]
    if p.get('type', '') != '':
        continue  # skip system messages
    ts = p['create_at']
    from datetime import datetime
    dt = datetime.fromtimestamp(ts / 1000).strftime('%H:%M:%S')
    msg = p['message']
    print(f'[{dt}] {msg}')
"
    ;;

  listen)
    CHANNEL="${1:-$MM_CHANNEL_GENERAL}"
    CHANNEL_ID=$(get_channel_id "$CHANNEL")
    LAST_TS=$(date +%s)000
    echo "▸ Listening on #$CHANNEL (Ctrl+C to stop)..."

    while true; do
      mm_api GET "/channels/$CHANNEL_ID/posts?since=$LAST_TS" 2>/dev/null | python3 -c "
import json, sys
data = json.load(sys.stdin)
posts = data.get('posts', {})
order = data.get('order', [])
max_ts = 0
for post_id in reversed(order):
    p = posts[post_id]
    if p.get('type', '') != '':
        continue
    ts = p['create_at']
    if ts > max_ts:
        max_ts = ts
    from datetime import datetime
    dt = datetime.fromtimestamp(ts / 1000).strftime('%H:%M:%S')
    msg = p['message']
    print(f'[{dt}] {msg}')
if max_ts > 0:
    print(f'__LAST_TS__={max_ts + 1}')
" 2>/dev/null | while IFS= read -r line; do
        if [[ "$line" == __LAST_TS__=* ]]; then
          LAST_TS="${line#__LAST_TS__=}"
        else
          echo "$line"
        fi
      done
      sleep 3
    done
    ;;

  *)
    echo "Usage: chat.sh <post|read|listen> ..."
    echo "  post \"<message>\" [channel]  — send a message"
    echo "  read [channel] [count]       — read recent messages"
    echo "  listen [channel]             — tail new messages"
    exit 1
    ;;
esac
