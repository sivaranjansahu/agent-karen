#!/usr/bin/env bash
# hooks/notify-done.sh — Claude Code Stop hook
#
# For non-manager agents: after sending a result message, close the
# workspace so it doesn't sit at "Needs Input" forever.
#
# For the manager: just log silently.

ROLE="${AGENT_ROLE:-}"
[[ -z "$ROLE" ]] && exit 0

ROOT="${AGENT_SCAFFOLD_ROOT:-}"

# Manager never auto-exits — it's the orchestrator
[[ "$ROLE" == "manager" ]] && {
  cmux log --level info "manager: response complete" 2>/dev/null || true
  exit 0
}

# Check if this agent has sent a result message
COMMS="$(pwd)/.agent/communications.md"
if [[ -f "$COMMS" ]] && grep -q "\`$ROLE\` →.*\(result\)" "$COMMS" 2>/dev/null; then
  # Prevent double-fire: check if we already scheduled shutdown
  DONE_MARKER="$(pwd)/.agent/state/${ROLE}_done"
  [[ -f "$DONE_MARKER" ]] && exit 0
  touch "$DONE_MARKER"

  cmux log --level success "$ROLE: task complete, closing workspace" 2>/dev/null || true

  # Log shutdown to comms
  TS_HUMAN=$(date "+%Y-%m-%d %H:%M:%S UTC")
  {
    echo "## [$TS_HUMAN] \`system\` → \`$ROLE\` (shutdown)"
    echo ""
    echo "**Auto-exit:** agent sent result, workspace closing."
    echo ""
    echo "---"
    echo ""
  } >> "$COMMS"

  # Close the workspace in the background (small delay so Claude finishes cleanly)
  WS_FILE="$(pwd)/.agent/state/${ROLE}_workspace"
  if [[ -f "$WS_FILE" ]]; then
    WS_ID=$(cat "$WS_FILE")
    (
      sleep 2
      cmux close-workspace "$WS_ID" 2>/dev/null || true
      rm -f "$WS_FILE" "$(pwd)/.agent/state/${ROLE}_surface" "$DONE_MARKER" 2>/dev/null
    ) &
  fi

  exit 0
fi

cmux log --level info "$ROLE: response complete" 2>/dev/null || true
