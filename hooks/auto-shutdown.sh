#!/usr/bin/env bash
# auto-shutdown.sh — Stop hook: check for idle agents after each response
#
# Enable: export AUTO_SHUTDOWN_MINS=15

IDLE_MINS="${AUTO_SHUTDOWN_MINS:-}"
[[ -z "$IDLE_MINS" ]] && exit 0

ROOT="${AGENT_SCAFFOLD_ROOT:-}"
[[ -z "$ROOT" ]] && exit 0

SELF="${KAREN_AGENT_ID:-${AGENT_ROLE:-}}"
HUB_DIR="${KAREN_HUB_DIR:-$(pwd)/.agent}"
STATE="$HUB_DIR/state"
COMMS="$HUB_DIR/communications.md"
NOW=$(date "+%s")
IDLE_SECS=$((IDLE_MINS * 60))

for ws_file in "$STATE"/*_workspace; do
  [[ -f "$ws_file" ]] || continue
  AGENT_ID=$(basename "$ws_file" _workspace)
  [[ "$AGENT_ID" == "$SELF" ]] && continue

  LAST_LINE=$(grep -n "\`$AGENT_ID\` →" "$COMMS" 2>/dev/null | tail -1 | cut -d: -f1)
  [[ -z "$LAST_LINE" ]] && continue

  TS=$(sed -n "${LAST_LINE}s/.*\[\(.*\)\].*/\1/p" "$COMMS" 2>/dev/null)
  [[ -z "$TS" ]] && continue

  LAST_EPOCH=$(date -j -f "%Y-%m-%d %H:%M:%S UTC" "$TS" "+%s" 2>/dev/null || echo "0")
  [[ "$LAST_EPOCH" == "0" ]] && continue

  IDLE=$((NOW - LAST_EPOCH))
  if [[ $IDLE -gt $IDLE_SECS ]]; then
    export KAREN_HUB_DIR="$HUB_DIR"
    source "$ROOT/lib/mux.sh" 2>/dev/null
    IDLE_HUMAN=$((IDLE / 60))

    mux_send "$AGENT_ID" "Save key learnings to $HUB_DIR/memory/${AGENT_ID}.md — auto-shutdown in 3 seconds." 2>/dev/null || true
    sleep 3
    mux_close "$AGENT_ID" 2>/dev/null || true

    TS_HUMAN=$(date "+%Y-%m-%d %H:%M:%S UTC")
    {
      echo "## [$TS_HUMAN] \`system\` → \`$AGENT_ID\` (shutdown)"
      echo ""
      echo "**Auto-shutdown:** idle for ${IDLE_HUMAN}m (threshold: ${IDLE_MINS}m)"
      echo ""
      echo "---"
      echo ""
    } >> "$COMMS"
  fi
done
