#!/usr/bin/env bash
# msg.sh — send a message to another agent's inbox, wake its terminal,
#           and record the communication in .agent/communications.md
#
# Usage:
#   ./scripts/msg.sh <role> "<message>" [type]
#
# type (optional): message | question | escalation | result | unblock
#
# Examples:
#   ./scripts/msg.sh manager "Brief complete. See .agent/context/brief.md"
#   ./scripts/msg.sh lead "QA FAIL — 2 blockers. See qa_report.md" result
#   ./scripts/msg.sh dev1 "Unblock: use bcrypt for password hashing" unblock

set -euo pipefail

ROLE="${1:?Usage: msg.sh <role> \"<message>\" [type]}"
MSG="${2:?Usage: msg.sh <role> \"<message>\" [type]}"
TYPE="${3:-message}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
# AGENT_DIR must point to the PROJECT's .agent/ dir, not the scaffold's.
# Priority: env var (set by spawn.sh) > pwd/.agent > scaffold root (standalone).
if [[ -n "${KAREN_PROJECT_AGENT_DIR:-}" && -d "$KAREN_PROJECT_AGENT_DIR" ]]; then
  AGENT_DIR="$KAREN_PROJECT_AGENT_DIR"
elif [[ -d "$(pwd)/.agent" ]]; then
  AGENT_DIR="$(pwd)/.agent"
else
  AGENT_DIR="$ROOT"
fi

INBOX="$AGENT_DIR/inbox/${ROLE}.jsonl"
SURFACE_FILE="$AGENT_DIR/state/${ROLE}_surface"
COMMS="$AGENT_DIR/communications.md"
FROM="${AGENT_ROLE:-manager}"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TS_HUMAN=$(date "+%Y-%m-%d %H:%M:%S UTC")

# 1. Write to inbox
MSG_JSON=$(python3 -c "import json, sys; print(json.dumps(sys.argv[1]))" "$MSG")
echo "{\"from\":\"$FROM\",\"type\":\"$TYPE\",\"ts\":\"$TIMESTAMP\",\"body\":$MSG_JSON}" >> "$INBOX"

# 2. Append to communications.md
{
  echo "## [$TS_HUMAN] \`$FROM\` → \`$ROLE\` ($TYPE)"
  echo ""
  echo "$MSG"
  echo ""
  echo "---"
  echo ""
} >> "$COMMS"

echo "▸ Logged: $FROM → $ROLE ($TYPE)"

# 3. Relay to Mattermost (if configured)
MM_ENV="$AGENT_DIR/state/mattermost.env"
if [[ -f "$MM_ENV" ]]; then
  (
    # shellcheck source=/dev/null
    source "$MM_ENV"
    if [[ -n "${MM_BOT_TOKEN:-}" && "$MM_BOT_TOKEN" != "PASTE_TOKEN_HERE" ]]; then
      # Pick channel based on message type
      case "$TYPE" in
        escalation) MM_CH="${MM_CHANNEL_ESCALATIONS:-escalations}" ;;
        result)     MM_CH="${MM_CHANNEL_TASKS:-tasks}" ;;
        *)          MM_CH="${MM_CHANNEL_GENERAL:-general}" ;;
      esac
      AGENT_ROLE="$FROM" "$ROOT/scripts/chat.sh" post "$FROM → $ROLE ($TYPE): $MSG" "$MM_CH" 2>/dev/null || true
    fi
  )
fi

# 4. Push-trigger: wake the target terminal
export KAREN_PROJECT_AGENT_DIR="$AGENT_DIR"
source "$ROOT/lib/mux.sh"
WS_FILE="$AGENT_DIR/state/${ROLE}_workspace"
if [[ -f "$WS_FILE" ]]; then
  PROMPT="📬 New $TYPE from $FROM. Check ${AGENT_DIR}/inbox/${ROLE}.jsonl and respond."
  mux_send "$ROLE" "$PROMPT" 2>/dev/null && \
    echo "✓ Woke $ROLE" || \
    echo "⚠ Send failed — message queued in inbox"
else
  # Fallback: try to find workspace via mux_list before giving up
  if mux_list 2>/dev/null | grep -q "$ROLE"; then
    echo "⚠ State file missing but $ROLE appears alive — message queued in inbox"
  else
    echo "⚠ No workspace for $ROLE — message queued in inbox"
  fi
fi
