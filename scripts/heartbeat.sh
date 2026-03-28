#!/usr/bin/env bash
# heartbeat.sh — monitor all agents: wake idle ones, restart dead ones
#
# Usage:
#   heartbeat.sh [once|loop]    # default: once
#   heartbeat.sh loop 15        # loop every 15 seconds
#
# What it does every tick:
# 1. Detects dead agents (workspace gone) → escalates to manager
# 2. Detects stuck permission prompts → auto-approves with Enter
# 3. Detects idle agents at prompt with unread inbox → sends wake-up
# 4. Detects session-ended agents → escalates to manager

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
source "$ROOT/lib/hub.sh"

HUB_DIR=$(resolve_hub_dir) || exit 1
STATE="$HUB_DIR/state"
MODE="${1:-once}"
INTERVAL="${2:-15}"

check_agents() {
  local DEAD=0
  local IDLE=0
  local WOKEN=0

  for ws_file in "$STATE"/*_workspace; do
    [[ -f "$ws_file" ]] || continue
    AGENT_ID=$(basename "$ws_file" _workspace)
    WS_ID=$(cat "$ws_file")

    # 1. Check if workspace exists
    if ! cmux read-screen --workspace "$WS_ID" --lines 1 >/dev/null 2>&1; then
      echo "[heartbeat] ✗ $AGENT_ID — workspace gone"
      DEAD=$((DEAD + 1))
      # Find this agent's project manager to notify
      PROJECT_KEY=$(echo "$AGENT_ID" | cut -d- -f1)
      MANAGER_ID="${PROJECT_KEY}-manager"
      echo "{\"from\":\"heartbeat\",\"type\":\"escalation\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"body\":\"Agent $AGENT_ID is dead (workspace $WS_ID gone). Needs respawn.\"}" >> "$HUB_DIR/inbox/${MANAGER_ID}.jsonl"
      continue
    fi

    # Read screen for status detection
    SCREEN=$(cmux read-screen --workspace "$WS_ID" --lines 15 2>/dev/null || true)

    # 2. Stuck on permission prompt → auto-approve
    if echo "$SCREEN" | grep -q "Do you want to proceed\|bypass permissions"; then
      echo "[heartbeat] ⚠ $AGENT_ID — stuck on permission prompt → sending Enter"
      cmux send-key --workspace "$WS_ID" "Enter" 2>/dev/null || true
      continue
    fi

    # 3. Idle at prompt with unread inbox → WAKE UP
    # Detect "sitting at Claude prompt" patterns
    if echo "$SCREEN" | grep -qE "^❯\s*$|^>\s*$|waiting for input|Needs Input"; then
      # Check if there are unread messages
      INBOX="$HUB_DIR/inbox/${AGENT_ID}.jsonl"
      CURSOR_FILE="$STATE/${AGENT_ID}_inbox_cursor"

      if [[ -f "$INBOX" ]]; then
        TOTAL=$(wc -l < "$INBOX" | tr -d ' ')
        CURSOR=0
        [[ -f "$CURSOR_FILE" ]] && CURSOR=$(cat "$CURSOR_FILE")

        if [[ $TOTAL -gt $CURSOR ]]; then
          UNREAD=$((TOTAL - CURSOR))
          echo "[heartbeat] 📬 $AGENT_ID — idle at prompt with $UNREAD unread message(s) → waking"
          PROMPT="📬 You have $UNREAD unread message(s). Check $INBOX and respond."
          cmux send --workspace "$WS_ID" "${PROMPT}"$'\n' 2>/dev/null || true
          WOKEN=$((WOKEN + 1))
          continue
        fi
      fi

      IDLE=$((IDLE + 1))
    fi

    # 4. Session ended (API error or completed) → escalate
    if echo "$SCREEN" | grep -qE "API Error|Internal server error|Sautéed for|Cooked for|Brewed for"; then
      if echo "$SCREEN" | grep -qE "^❯\s*$"; then
        echo "[heartbeat] ⚠ $AGENT_ID — session ended, idle at prompt"
        IDLE=$((IDLE + 1))
        PROJECT_KEY=$(echo "$AGENT_ID" | cut -d- -f1)
        MANAGER_ID="${PROJECT_KEY}-manager"
        echo "{\"from\":\"heartbeat\",\"type\":\"escalation\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"body\":\"Agent $AGENT_ID session ended — idle at prompt. May need respawn or new task.\"}" >> "$HUB_DIR/inbox/${MANAGER_ID}.jsonl"
      fi
    fi
  done

  echo "[heartbeat] $(date -u +%H:%M:%S) — Dead: $DEAD, Idle: $IDLE, Woken: $WOKEN"
}

if [[ "$MODE" == "loop" ]]; then
  echo "[heartbeat] Monitoring every ${INTERVAL}s... (Ctrl+C to stop)"
  while true; do
    check_agents
    sleep "$INTERVAL"
  done
else
  check_agents
fi
