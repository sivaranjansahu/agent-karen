#!/usr/bin/env bash
# mm-watch.sh — Poll Mattermost for new messages and wake agents via cmux
#
# Usage:
#   ./scripts/mm-watch.sh              # watch #general (default)
#   ./scripts/mm-watch.sh general tasks # watch multiple channels
#
# Runs in foreground. Ctrl+C to stop.
# Typically launched by bootstrap.sh or run in a dedicated terminal.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
ENV_FILE="$ROOT/.agent/state/mattermost.env"
POLL_INTERVAL="${MM_POLL_INTERVAL:-5}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "✗ Mattermost not configured. Run: ./mattermost/setup.sh"
  exit 1
fi

# shellcheck source=/dev/null
source "$ENV_FILE"

if [[ -z "${MM_BOT_TOKEN:-}" || "$MM_BOT_TOKEN" == "PASTE_TOKEN_HERE" ]]; then
  echo "✗ MM_BOT_TOKEN not set"
  exit 1
fi

# Channels to watch (args or default to general)
CHANNELS=("${@:-general}")

# Get bot user ID so we skip its own messages
BOT_USER_ID=$(curl -sf -H "Authorization: Bearer $MM_BOT_TOKEN" \
  "$MM_URL/api/v4/users/me" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

# Resolve channel IDs
declare -A CHANNEL_IDS
for ch in "${CHANNELS[@]}"; do
  env_var="MM_CHANNEL_ID_$(echo "$ch" | tr '[:lower:]' '[:upper:]')"
  ch_id="${!env_var:-}"
  if [[ -z "$ch_id" ]]; then
    ch_id=$(curl -sf -H "Authorization: Bearer $MM_BOT_TOKEN" \
      "$MM_URL/api/v4/teams/${MM_TEAM_ID}/channels/name/$ch" | \
      python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "")
  fi
  if [[ -n "$ch_id" ]]; then
    CHANNEL_IDS[$ch]="$ch_id"
  else
    echo "⚠ Could not resolve channel: $ch"
  fi
done

# Track last seen timestamp per channel (epoch ms)
declare -A LAST_SEEN
NOW_MS=$(python3 -c "import time; print(int(time.time()*1000))")
for ch in "${CHANNELS[@]}"; do
  LAST_SEEN[$ch]="$NOW_MS"
done

echo "▸ Watching: ${CHANNELS[*]} (poll every ${POLL_INTERVAL}s)"

# Get all known agent roles from workspace/surface files
get_agent_roles() {
  for f in "$ROOT"/.agent/state/*_workspace "$ROOT"/.agent/state/*_surface; do
    [[ -f "$f" ]] || continue
    basename "$f" | sed 's/_workspace$//' | sed 's/_surface$//'
  done | sort -u
}

wake_agents() {
  local msg="$1"
  local roles
  roles=$(get_agent_roles)
  for role in $roles; do
    local ws_file="$ROOT/.agent/state/${role}_workspace"
    local sf_file="$ROOT/.agent/state/${role}_surface"
    if [[ -f "$ws_file" ]]; then
      local ws
      ws=$(cat "$ws_file")
      cmux send --workspace "$ws" "$msg"$'\n' 2>/dev/null || true
    elif [[ -f "$sf_file" ]]; then
      local sf
      sf=$(cat "$sf_file")
      cmux send --surface "$sf" "$msg"$'\n' 2>/dev/null || true
    fi
  done
}

while true; do
  for ch in "${CHANNELS[@]}"; do
    ch_id="${CHANNEL_IDS[$ch]:-}"
    [[ -z "$ch_id" ]] && continue
    last="${LAST_SEEN[$ch]}"

    # Fetch posts since last check
    RESPONSE=$(curl -sf -H "Authorization: Bearer $MM_BOT_TOKEN" \
      "$MM_URL/api/v4/channels/$ch_id/posts?since=$last" 2>/dev/null || echo "{}")

    # Parse new messages (skip bot's own posts and system messages)
    NEW_MSGS=$(echo "$RESPONSE" | python3 -c "
import json, sys
data = json.load(sys.stdin)
posts = data.get('posts', {})
order = data.get('order', [])
bot_id = '$BOT_USER_ID'
max_ts = 0
msgs = []
for pid in reversed(order):
    p = posts[pid]
    if p.get('user_id') == bot_id:
        continue
    if p.get('type', '') != '':
        continue
    ts = p['create_at']
    if ts > max_ts:
        max_ts = ts
    msg = p['message']
    username = p.get('props', {}).get('override_username', '') or p.get('user_id', '')[:8]
    msgs.append(f'{username}: {msg}')
if max_ts > 0:
    print(f'__TS__={max_ts + 1}')
for m in msgs:
    print(m)
" 2>/dev/null || echo "")

    if [[ -n "$NEW_MSGS" ]]; then
      # Extract updated timestamp
      TS_LINE=$(echo "$NEW_MSGS" | grep "^__TS__=" || echo "")
      if [[ -n "$TS_LINE" ]]; then
        LAST_SEEN[$ch]="${TS_LINE#__TS__=}"
      fi

      # Get actual messages (exclude TS line)
      ACTUAL_MSGS=$(echo "$NEW_MSGS" | grep -v "^__TS__=" || echo "")
      if [[ -n "$ACTUAL_MSGS" ]]; then
        echo "[#$ch] $ACTUAL_MSGS"
        wake_agents "💬 New message in #$ch — run: ./scripts/chat.sh read $ch 5"
      fi
    fi
  done

  sleep "$POLL_INTERVAL"
done
