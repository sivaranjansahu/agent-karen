#!/usr/bin/env bash
# hooks/notify-done.sh — Claude Code Stop hook
#
# For non-manager agents: after sending a result message, close the
# workspace so it doesn't sit at "Needs Input" forever.

AGENT_ID="${KAREN_AGENT_ID:-${AGENT_ROLE:-}}"
[[ -z "$AGENT_ID" ]] && exit 0

SHORT_ROLE="${AGENT_ROLE:-$AGENT_ID}"
HUB_DIR="${KAREN_HUB_DIR:-$(pwd)/.agent}"

# Manager never auto-exits
[[ "$SHORT_ROLE" == "manager" ]] && {
  cmux log --level info "$AGENT_ID: response complete" 2>/dev/null || true
  exit 0
}

COMMS="$HUB_DIR/communications.md"
if [[ -f "$COMMS" ]] && grep -q "\`$AGENT_ID\` →.*\(result\)" "$COMMS" 2>/dev/null; then
  DONE_MARKER="$HUB_DIR/state/${AGENT_ID}_done"
  [[ -f "$DONE_MARKER" ]] && exit 0
  touch "$DONE_MARKER"

  cmux log --level success "$AGENT_ID: task complete, closing workspace" 2>/dev/null || true

  TS_HUMAN=$(date "+%Y-%m-%d %H:%M:%S UTC")
  {
    echo "## [$TS_HUMAN] \`system\` → \`$AGENT_ID\` (shutdown)"
    echo ""
    echo "**Auto-exit:** agent sent result, workspace closing."
    echo ""
    echo "---"
    echo ""
  } >> "$COMMS"

  WS_FILE="$HUB_DIR/state/${AGENT_ID}_workspace"
  if [[ -f "$WS_FILE" ]]; then
    WS_ID=$(cat "$WS_FILE")
    (
      sleep 2
      cmux close-workspace "$WS_ID" 2>/dev/null || true
      rm -f "$WS_FILE" "$HUB_DIR/state/${AGENT_ID}_surface" "$DONE_MARKER" 2>/dev/null
    ) &
  fi

  exit 0
fi

cmux log --level info "$AGENT_ID: response complete" 2>/dev/null || true
