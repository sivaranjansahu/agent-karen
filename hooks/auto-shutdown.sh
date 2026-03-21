#!/usr/bin/env bash
# auto-shutdown.sh — Stop hook: check for idle agents after each response
#
# Runs after every Claude Code response. Checks if any OTHER agents
# have been idle longer than AUTO_SHUTDOWN_MINS (default: off).
#
# Enable by setting AUTO_SHUTDOWN_MINS in your environment:
#   export AUTO_SHUTDOWN_MINS=15
#
# Wire into .claude/settings.json:
# {
#   "hooks": {
#     "Stop": [{ "type": "command", "command": "./hooks/auto-shutdown.sh" }]
#   }
# }

IDLE_MINS="${AUTO_SHUTDOWN_MINS:-}"
[[ -z "$IDLE_MINS" ]] && exit 0  # Feature disabled

ROOT="${AGENT_SCAFFOLD_ROOT:-}"
[[ -z "$ROOT" ]] && exit 0

SELF="${AGENT_ROLE:-}"
STATE="$(pwd)/.agent/state"
COMMS="$(pwd)/.agent/communications.md"
NOW=$(date "+%s")
IDLE_SECS=$((IDLE_MINS * 60))

for ws_file in "$STATE"/*_workspace; do
  [[ -f "$ws_file" ]] || continue
  ROLE=$(basename "$ws_file" _workspace)

  # Don't shut down yourself
  [[ "$ROLE" == "$SELF" ]] && continue

  # Check last outbound message from this role
  LAST_LINE=$(grep -n "\`$ROLE\` →" "$COMMS" 2>/dev/null | tail -1 | cut -d: -f1)
  if [[ -z "$LAST_LINE" ]]; then
    continue  # No messages yet — agent may still be starting
  fi

  TS=$(sed -n "${LAST_LINE}s/.*\[\(.*\)\].*/\1/p" "$COMMS" 2>/dev/null)
  [[ -z "$TS" ]] && continue

  LAST_EPOCH=$(date -j -f "%Y-%m-%d %H:%M:%S UTC" "$TS" "+%s" 2>/dev/null || echo "0")
  [[ "$LAST_EPOCH" == "0" ]] && continue

  IDLE=$((NOW - LAST_EPOCH))
  if [[ $IDLE -gt $IDLE_SECS ]]; then
    # Source mux for shutdown
    source "$ROOT/lib/mux.sh" 2>/dev/null
    IDLE_HUMAN=$((IDLE / 60))

    # Send memory save prompt before closing
    mux_send "$ROLE" "Save key learnings to .agent/memory/${ROLE}.md — auto-shutdown in 3 seconds." 2>/dev/null || true
    sleep 3
    mux_close "$ROLE" 2>/dev/null || true

    TS_HUMAN=$(date "+%Y-%m-%d %H:%M:%S UTC")
    {
      echo "## [$TS_HUMAN] \`system\` → \`$ROLE\` (shutdown)"
      echo ""
      echo "**Auto-shutdown:** idle for ${IDLE_HUMAN}m (threshold: ${IDLE_MINS}m)"
      echo ""
      echo "---"
      echo ""
    } >> "$COMMS"
  fi
done
