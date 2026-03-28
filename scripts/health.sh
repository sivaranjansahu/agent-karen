#!/usr/bin/env bash
# health.sh — check all spawned agents are alive and responsive
#
# Usage: ./scripts/health.sh [--project <key>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# Load hub resolution helpers
source "$ROOT/lib/hub.sh"

HUB_DIR=$(resolve_hub_dir) || exit 1
STATE="$HUB_DIR/state"

# Parse optional --project filter
FILTER_PROJECT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) FILTER_PROJECT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# Load multiplexer abstraction
export KAREN_HUB_DIR="$HUB_DIR"
source "$ROOT/lib/mux.sh"

# Get all active workspaces
ACTIVE_WS=$(mux_list 2>/dev/null || true)

echo "=== Agent Health Check (backend: $(mux_backend)) ==="
if [[ -n "$FILTER_PROJECT" ]]; then
  echo "  Filtered: project=$FILTER_PROJECT"
fi
echo ""

UNHEALTHY=0

for ws_file in "$STATE"/*_workspace; do
  [[ -f "$ws_file" ]] || continue
  AGENT_ID=$(basename "$ws_file" _workspace)

  # Apply project filter if specified
  if [[ -n "$FILTER_PROJECT" ]]; then
    AGENT_PROJECT=$(extract_project_key "$AGENT_ID")
    [[ "$AGENT_PROJECT" != "$FILTER_PROJECT" ]] && continue
  fi

  WS_ID=$(cat "$ws_file")
  SF_FILE="$STATE/${AGENT_ID}_surface"
  SF_ID=""
  [[ -f "$SF_FILE" ]] && SF_ID=$(cat "$SF_FILE")

  # Check if workspace exists in active list
  if echo "$ACTIVE_WS" | grep -qE "$WS_ID|$AGENT_ID"; then
    STATUS="UP"
  else
    STATUS="DOWN"
    UNHEALTHY=$((UNHEALTHY + 1))
  fi

  # Check last message time from this agent
  INBOX="$HUB_DIR/inbox/${AGENT_ID}.jsonl"
  LAST_MSG=""
  if [[ -f "$INBOX" ]]; then
    MSG_COUNT=$(wc -l < "$INBOX" | tr -d ' ')
    LAST_MSG=$(tail -1 "$INBOX" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'{d.get(\"from\",\"?\")} ({d.get(\"type\",\"?\")}): {d[\"body\"][:60]}...' if len(d.get('body',''))>60 else f'{d.get(\"from\",\"?\")} ({d.get(\"type\",\"?\")}): {d.get(\"body\",\"\")}')" 2>/dev/null || true)
  else
    MSG_COUNT=0
  fi

  # Check last outbound message from this agent in comms
  COMMS="$HUB_DIR/communications.md"
  LAST_SENT=$(grep -c "\`$AGENT_ID\` →" "$COMMS" 2>/dev/null || echo "0")

  if [[ "$STATUS" == "UP" ]]; then
    echo "  ✓ $AGENT_ID  $WS_ID  $SF_ID  (inbox: $MSG_COUNT msgs, sent: $LAST_SENT msgs)"
  else
    echo "  ✗ $AGENT_ID  $WS_ID  $SF_ID  DOWN  (inbox: $MSG_COUNT msgs, sent: $LAST_SENT msgs)"
  fi

  if [[ -n "$LAST_MSG" ]]; then
    echo "    └─ last inbox: $LAST_MSG"
  fi
  echo ""
done

echo "---"
if [[ $UNHEALTHY -gt 0 ]]; then
  echo "⚠ $UNHEALTHY agent(s) DOWN — respawn needed"
  exit 1
else
  echo "✓ All agents healthy"
  exit 0
fi
