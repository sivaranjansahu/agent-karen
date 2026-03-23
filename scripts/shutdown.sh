#!/usr/bin/env bash
# shutdown.sh — gracefully shut down an agent workspace (or all idle agents)
#
# Usage:
#   ./scripts/shutdown.sh <role>         # shut down a specific agent
#   ./scripts/shutdown.sh --idle <mins>  # shut down all agents idle for N minutes (default: 10)
#   ./scripts/shutdown.sh --all          # shut down all agents (not the orchestrator)
#
# The agent's state (inbox, beads, context files) is preserved on disk.
# Respawn anytime with: ./scripts/spawn.sh <role> "Resume your work. Check inbox and bd quickstart."

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
AGENT_DIR="$(pwd)/.agent"
STATE="$AGENT_DIR/state"
COMMS="$AGENT_DIR/communications.md"
TS_HUMAN=$(date "+%Y-%m-%d %H:%M:%S UTC")

# Load multiplexer abstraction
source "$ROOT/lib/mux.sh"

shutdown_agent() {
  local ROLE="$1"
  local WS_FILE="$STATE/${ROLE}_workspace"

  if [[ ! -f "$WS_FILE" ]]; then
    echo "  ⚠ $ROLE: no workspace file — already shut down?"
    return 1
  fi

  # Ask agent to save memory before closing
  local SAVE_PROMPT="Save your key learnings, decisions, and context to \$AGENT_SCAFFOLD_ROOT/.agent/memory/${ROLE}.md before this session ends. Write what your next spawn needs to know to pick up where you left off."
  mux_send "$ROLE" "$SAVE_PROMPT" 2>/dev/null || true
  sleep 3  # Give agent a moment to process

  # Close the workspace
  if mux_close "$ROLE"; then
    echo "  ✓ $ROLE: closed"
  else
    echo "  ⚠ $ROLE: already gone"
  fi

  # Log to communications
  {
    echo "## [$TS_HUMAN] \`system\` → \`$ROLE\` (shutdown)"
    echo ""
    echo "**Agent workspace closed.** State preserved — respawn to resume."
    echo ""
    echo "---"
    echo ""
  } >> "$COMMS"

  return 0
}

get_last_activity() {
  local ROLE="$1"
  # Check last message FROM this role in communications.md
  local LAST_LINE=$(grep -n "\`$ROLE\` →" "$COMMS" 2>/dev/null | tail -1 | cut -d: -f1)
  if [[ -z "$LAST_LINE" ]]; then
    echo "0"
    return
  fi
  # Extract timestamp from the header line
  local TS=$(sed -n "${LAST_LINE}s/.*\[\(.*\)\].*/\1/p" "$COMMS" 2>/dev/null)
  if [[ -z "$TS" ]]; then
    echo "0"
    return
  fi
  # Convert to epoch
  date -j -f "%Y-%m-%d %H:%M:%S UTC" "$TS" "+%s" 2>/dev/null || echo "0"
}

# --- Main ---

if [[ "${1:-}" == "--all" ]]; then
  echo "=== Shutting down all agents ==="
  for ws_file in "$STATE"/*_workspace; do
    [[ -f "$ws_file" ]] || continue
    ROLE=$(basename "$ws_file" _workspace)
    shutdown_agent "$ROLE"
  done
  echo "Done. Respawn any agent with: ./scripts/spawn.sh <role> \"Resume. Check inbox and bd quickstart.\""

elif [[ "${1:-}" == "--idle" ]]; then
  IDLE_MINS="${2:-10}"
  IDLE_SECS=$((IDLE_MINS * 60))
  NOW=$(date "+%s")
  echo "=== Shutting down agents idle for ${IDLE_MINS}+ minutes ==="
  SHUT=0
  for ws_file in "$STATE"/*_workspace; do
    [[ -f "$ws_file" ]] || continue
    ROLE=$(basename "$ws_file" _workspace)
    LAST=$(get_last_activity "$ROLE")
    if [[ "$LAST" == "0" ]] || [[ $((NOW - LAST)) -gt $IDLE_SECS ]]; then
      shutdown_agent "$ROLE" && SHUT=$((SHUT + 1))
    else
      AGO=$(( (NOW - LAST) / 60 ))
      echo "  ⏳ $ROLE: active ${AGO}m ago — keeping alive"
    fi
  done
  if [[ $SHUT -eq 0 ]]; then
    echo "No idle agents found."
  else
    echo "Shut down $SHUT agent(s)."
  fi

elif [[ -n "${1:-}" ]]; then
  ROLE="$1"
  echo "=== Shutting down $ROLE ==="
  shutdown_agent "$ROLE"
  echo "Respawn with: ./scripts/spawn.sh $ROLE \"Resume. Check inbox and bd quickstart.\""

else
  echo "Usage:"
  echo "  ./scripts/shutdown.sh <role>         # shut down specific agent"
  echo "  ./scripts/shutdown.sh --idle [mins]  # shut down agents idle for N mins (default: 10)"
  echo "  ./scripts/shutdown.sh --all          # shut down all agents"
fi
