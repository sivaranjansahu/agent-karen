#!/usr/bin/env bash
# health.sh — check all spawned agents are alive and responsive
#
# Usage: ./scripts/health.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
AGENT_DIR="$ROOT"
STATE="$AGENT_DIR/state"

# Load multiplexer abstraction
source "$ROOT/lib/mux.sh"

# Get all active workspaces
ACTIVE_WS=$(mux_list 2>/dev/null || true)

echo "=== Agent Health Check (backend: $(mux_backend)) ==="
echo ""

UNHEALTHY=0

for ws_file in "$STATE"/*_workspace; do
  [[ -f "$ws_file" ]] || continue
  ROLE=$(basename "$ws_file" _workspace)
  WS_ID=$(cat "$ws_file")
  SF_FILE="$STATE/${ROLE}_surface"
  SF_ID=""
  [[ -f "$SF_FILE" ]] && SF_ID=$(cat "$SF_FILE")

  # Check if workspace exists in active list
  # Match by workspace ID (cmux: workspace:N) or role name (tmux: window name)
  if echo "$ACTIVE_WS" | grep -qE "$WS_ID|$ROLE"; then
    STATUS="UP"
  else
    STATUS="DOWN"
    UNHEALTHY=$((UNHEALTHY + 1))
  fi

  # Check last message time from this role
  INBOX="$AGENT_DIR/inbox/${ROLE}.jsonl"
  LAST_MSG=""
  if [[ -f "$INBOX" ]]; then
    MSG_COUNT=$(wc -l < "$INBOX" | tr -d ' ')
    LAST_MSG=$(tail -1 "$INBOX" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'{d.get(\"from\",\"?\")} ({d.get(\"type\",\"?\")}): {d[\"body\"][:60]}...' if len(d.get('body',''))>60 else f'{d.get(\"from\",\"?\")} ({d.get(\"type\",\"?\")}): {d.get(\"body\",\"\")}')" 2>/dev/null || true)
  else
    MSG_COUNT=0
  fi

  # Check last outbound message from this role in comms
  LAST_SENT=$(grep -c "\`$ROLE\` →" "$AGENT_DIR/communications.md" 2>/dev/null || echo "0")

  if [[ "$STATUS" == "UP" ]]; then
    echo "  ✓ $ROLE  $WS_ID  $SF_ID  (inbox: $MSG_COUNT msgs, sent: $LAST_SENT msgs)"
  else
    echo "  ✗ $ROLE  $WS_ID  $SF_ID  DOWN  (inbox: $MSG_COUNT msgs, sent: $LAST_SENT msgs)"
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
