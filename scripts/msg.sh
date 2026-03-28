#!/usr/bin/env bash
# msg.sh — send a message to another agent's inbox, wake its terminal,
#           and record the communication in communications.md
#
# Usage:
#   ./scripts/msg.sh <target> "<message>" [type]
#
# target: agent ID (e.g., "prepare-dev1") or short name (e.g., "dev1" — auto-prefixed with project key)
# type (optional): message | question | escalation | result | unblock
#
# Examples:
#   ./scripts/msg.sh manager "Brief complete. See context/brief.md"
#   ./scripts/msg.sh lead "QA FAIL — 2 blockers" result
#   ./scripts/msg.sh tagger-dev1 "Cross-project: need your API spec" question

set -euo pipefail

TARGET="${1:?Usage: msg.sh <target> \"<message>\" [type]}"
MSG="${2:?Usage: msg.sh <target> \"<message>\" [type]}"
TYPE="${3:-message}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# Load hub resolution helpers
source "$ROOT/lib/hub.sh"

HUB_DIR=$(resolve_hub_dir) || exit 1
TARGET_ID=$(resolve_agent_id "$TARGET")
FROM=$(get_sender_id)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TS_HUMAN=$(date "+%Y-%m-%d %H:%M:%S UTC")

INBOX="$HUB_DIR/inbox/${TARGET_ID}.jsonl"
COMMS="$HUB_DIR/communications.md"

# Ensure inbox directory exists
mkdir -p "$HUB_DIR/inbox"

# 1. Write to inbox
MSG_JSON=$(python3 -c "import json, sys; print(json.dumps(sys.argv[1]))" "$MSG")
echo "{\"from\":\"$FROM\",\"type\":\"$TYPE\",\"ts\":\"$TIMESTAMP\",\"body\":$MSG_JSON}" >> "$INBOX"

# 2. Append to communications.md
{
  echo "## [$TS_HUMAN] \`$FROM\` → \`$TARGET_ID\` ($TYPE)"
  echo ""
  echo "$MSG"
  echo ""
  echo "---"
  echo ""
} >> "$COMMS"

echo "▸ Logged: $FROM → $TARGET_ID ($TYPE)"

# 3. Relay to Mattermost (if configured)
MM_ENV="$HUB_DIR/state/mattermost.env"
if [[ -f "$MM_ENV" ]]; then
  (
    # shellcheck source=/dev/null
    source "$MM_ENV"
    if [[ -n "${MM_BOT_TOKEN:-}" && "$MM_BOT_TOKEN" != "PASTE_TOKEN_HERE" ]]; then
      case "$TYPE" in
        escalation) MM_CH="${MM_CHANNEL_ESCALATIONS:-escalations}" ;;
        result)     MM_CH="${MM_CHANNEL_TASKS:-tasks}" ;;
        *)          MM_CH="${MM_CHANNEL_GENERAL:-general}" ;;
      esac
      AGENT_ROLE="$FROM" "$ROOT/scripts/chat.sh" post "$FROM → $TARGET_ID ($TYPE): $MSG" "$MM_CH" 2>/dev/null || true
    fi
  )
fi

# 4. Push-trigger: wake the target terminal
export KAREN_HUB_DIR="$HUB_DIR"
source "$ROOT/lib/mux.sh"
WS_FILE="$HUB_DIR/state/${TARGET_ID}_workspace"
if [[ -f "$WS_FILE" ]]; then
  PROMPT="📬 New $TYPE from $FROM. Check ${HUB_DIR}/inbox/${TARGET_ID}.jsonl and respond."
  mux_send "$TARGET_ID" "$PROMPT" 2>/dev/null && \
    echo "✓ Woke $TARGET_ID" || \
    echo "⚠ Send failed — message queued in inbox"
else
  # Fallback: try to find workspace via mux_list before giving up
  if mux_list 2>/dev/null | grep -q "$TARGET_ID"; then
    echo "⚠ State file missing but $TARGET_ID appears alive — message queued in inbox"
  else
    echo "⚠ No workspace for $TARGET_ID — message queued in inbox"
  fi
fi
