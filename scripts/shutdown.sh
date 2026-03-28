#!/usr/bin/env bash
# shutdown.sh — gracefully shut down an agent workspace (or all idle agents)
#
# Usage:
#   ./scripts/shutdown.sh <agent_id_or_role>  # shut down a specific agent
#   ./scripts/shutdown.sh --idle <mins>       # shut down agents idle for N mins (default: 10)
#   ./scripts/shutdown.sh --all               # shut down all agents
#   ./scripts/shutdown.sh --project <key>     # shut down all agents for a project

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

source "$ROOT/lib/hub.sh"

HUB_DIR=$(resolve_hub_dir) || exit 1
STATE="$HUB_DIR/state"
COMMS="$HUB_DIR/communications.md"
TS_HUMAN=$(date "+%Y-%m-%d %H:%M:%S UTC")

export KAREN_HUB_DIR="$HUB_DIR"
source "$ROOT/lib/mux.sh"

shutdown_agent() {
  local AGENT_ID="$1"
  local WS_FILE="$STATE/${AGENT_ID}_workspace"

  if [[ ! -f "$WS_FILE" ]]; then
    echo "  ⚠ $AGENT_ID: no workspace file — already shut down?"
    return 1
  fi

  # Ask agent to save memory before closing
  local SAVE_PROMPT="Save your key learnings, decisions, and context to $HUB_DIR/memory/${AGENT_ID}.md before this session ends."
  mux_send "$AGENT_ID" "$SAVE_PROMPT" 2>/dev/null || true
  sleep 3

  if mux_close "$AGENT_ID"; then
    echo "  ✓ $AGENT_ID: closed"
  else
    echo "  ⚠ $AGENT_ID: already gone"
  fi

  {
    echo "## [$TS_HUMAN] \`system\` → \`$AGENT_ID\` (shutdown)"
    echo ""
    echo "**Agent workspace closed.** State preserved — respawn to resume."
    echo ""
    echo "---"
    echo ""
  } >> "$COMMS"

  return 0
}

get_last_activity() {
  local AGENT_ID="$1"
  local LAST_LINE=$(grep -n "\`$AGENT_ID\` →" "$COMMS" 2>/dev/null | tail -1 | cut -d: -f1)
  if [[ -z "$LAST_LINE" ]]; then
    echo "0"
    return
  fi
  local TS=$(sed -n "${LAST_LINE}s/.*\[\(.*\)\].*/\1/p" "$COMMS" 2>/dev/null)
  if [[ -z "$TS" ]]; then
    echo "0"
    return
  fi
  date -j -f "%Y-%m-%d %H:%M:%S UTC" "$TS" "+%s" 2>/dev/null || echo "0"
}

# --- Main ---

if [[ "${1:-}" == "--all" ]]; then
  echo "=== Shutting down all agents ==="
  for ws_file in "$STATE"/*_workspace; do
    [[ -f "$ws_file" ]] || continue
    AGENT_ID=$(basename "$ws_file" _workspace)
    shutdown_agent "$AGENT_ID"
  done
  # Kill heartbeat daemon
  HEARTBEAT_PID_FILE="$HUB_DIR/state/heartbeat.pid"
  if [[ -f "$HEARTBEAT_PID_FILE" ]]; then
    kill "$(cat "$HEARTBEAT_PID_FILE")" 2>/dev/null && echo "  ✓ Heartbeat stopped" || true
    rm -f "$HEARTBEAT_PID_FILE"
  fi
  echo "Done."

elif [[ "${1:-}" == "--project" ]]; then
  PROJECT_KEY="${2:?Usage: shutdown.sh --project <key>}"
  echo "=== Shutting down all $PROJECT_KEY agents ==="
  for ws_file in "$STATE"/${PROJECT_KEY}-*_workspace; do
    [[ -f "$ws_file" ]] || continue
    AGENT_ID=$(basename "$ws_file" _workspace)
    shutdown_agent "$AGENT_ID"
  done

elif [[ "${1:-}" == "--idle" ]]; then
  IDLE_MINS="${2:-10}"
  IDLE_SECS=$((IDLE_MINS * 60))
  NOW=$(date "+%s")
  echo "=== Shutting down agents idle for ${IDLE_MINS}+ minutes ==="
  SHUT=0
  for ws_file in "$STATE"/*_workspace; do
    [[ -f "$ws_file" ]] || continue
    AGENT_ID=$(basename "$ws_file" _workspace)
    LAST=$(get_last_activity "$AGENT_ID")
    if [[ "$LAST" == "0" ]] || [[ $((NOW - LAST)) -gt $IDLE_SECS ]]; then
      shutdown_agent "$AGENT_ID" && SHUT=$((SHUT + 1))
    else
      AGO=$(( (NOW - LAST) / 60 ))
      echo "  ⏳ $AGENT_ID: active ${AGO}m ago — keeping alive"
    fi
  done
  [[ $SHUT -eq 0 ]] && echo "No idle agents found." || echo "Shut down $SHUT agent(s)."

elif [[ -n "${1:-}" ]]; then
  TARGET="$1"
  AGENT_ID=$(resolve_agent_id "$TARGET")
  echo "=== Shutting down $AGENT_ID ==="
  shutdown_agent "$AGENT_ID"

else
  echo "Usage:"
  echo "  shutdown.sh <agent_id>         # shut down specific agent"
  echo "  shutdown.sh --idle [mins]      # shut down agents idle for N mins"
  echo "  shutdown.sh --all              # shut down all agents"
  echo "  shutdown.sh --project <key>    # shut down all agents for a project"
fi
