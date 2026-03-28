#!/usr/bin/env bash
# wake.sh — send text to another agent's terminal (with Enter)
#
# Usage: ./scripts/wake.sh <target> "your message here"

set -euo pipefail

TARGET="${1:?Usage: wake.sh <target> \"<message>\"}"
TEXT="${2:?Usage: wake.sh <target> \"<message>\"}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

source "$ROOT/lib/hub.sh"

HUB_DIR=$(resolve_hub_dir) || exit 1
AGENT_ID=$(resolve_agent_id "$TARGET")

export KAREN_HUB_DIR="$HUB_DIR"
source "$ROOT/lib/mux.sh"

WS_FILE="$HUB_DIR/state/${AGENT_ID}_workspace"
if [[ ! -f "$WS_FILE" ]]; then
  echo "⚠ No workspace for $AGENT_ID" >&2
  exit 1
fi

WS_ID=$(cat "$WS_FILE")
cmux send --workspace "$WS_ID" "${TEXT}"$'\n' 2>/dev/null
echo "✓ Sent to $AGENT_ID"
