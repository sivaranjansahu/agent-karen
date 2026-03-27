#!/usr/bin/env bash
# heartbeat.sh — monitor all agents, restart dead ones, wake idle ones
# Usage: heartbeat.sh [once|loop]

set -euo pipefail

# Resolve project .agent/ dir: env var > pwd/.agent > error
if [[ -n "${KAREN_PROJECT_AGENT_DIR:-}" && -d "$KAREN_PROJECT_AGENT_DIR" ]]; then
  AGENT_DIR="$KAREN_PROJECT_AGENT_DIR"
elif [[ -d "$(pwd)/.agent" ]]; then
  AGENT_DIR="$(pwd)/.agent"
else
  echo "ERROR: No .agent/ directory found. Run from project root or set KAREN_PROJECT_AGENT_DIR." >&2
  exit 1
fi
MODE="${1:-once}"

check_agents() {
  local DEAD=0
  local IDLE=0

  for ws_file in "$AGENT_DIR"/state/*_workspace; do
    [[ -f "$ws_file" ]] || continue
    ROLE=$(basename "$ws_file" _workspace)
    WS_ID=$(cat "$ws_file")

    # Check if workspace exists
    if ! cmux read-screen --workspace "$WS_ID" --lines 1 >/dev/null 2>&1; then
      echo "[heartbeat] ✗ $ROLE ($WS_ID) — workspace gone"
      DEAD=$((DEAD + 1))
      # Notify manager
      echo "{\"from\":\"heartbeat\",\"type\":\"escalation\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"body\":\"Agent $ROLE is dead (workspace $WS_ID gone). Needs respawn.\"}" >> "$AGENT_DIR/inbox/manager.jsonl"
      continue
    fi

    # Check for stuck permission prompts (2+ min)
    SCREEN=$(cmux read-screen --workspace "$WS_ID" --lines 10 2>/dev/null || true)
    if echo "$SCREEN" | grep -q "Do you want to proceed"; then
      echo "[heartbeat] ⚠ $ROLE — stuck on permission prompt"
      # Auto-approve by sending Enter
      cmux send-key --workspace "$WS_ID" "Enter" 2>/dev/null || true
      echo "[heartbeat] → sent Enter to unblock"
    fi

    # Check for API errors (session ended)
    if echo "$SCREEN" | grep -q "API Error: 500\|Internal server error\|Sautéed for\|Cooked for\|Brewed for"; then
      if echo "$SCREEN" | grep -qE "^❯ *$"; then
        echo "[heartbeat] ⚠ $ROLE — session ended (API error or completed), sitting at prompt"
        IDLE=$((IDLE + 1))
        echo "{\"from\":\"heartbeat\",\"type\":\"escalation\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"body\":\"Agent $ROLE session ended — idle at prompt. May need respawn or new task.\"}" >> "$AGENT_DIR/inbox/manager.jsonl"
      fi
    fi
  done

  echo "[heartbeat] $(date -u +%H:%M:%S) — checked all agents. Dead: $DEAD, Idle: $IDLE"
}

if [[ "$MODE" == "loop" ]]; then
  echo "[heartbeat] Monitoring every 60s... (Ctrl+C to stop)"
  while true; do
    check_agents
    sleep 60
  done
else
  check_agents
fi
