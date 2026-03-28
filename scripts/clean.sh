#!/usr/bin/env bash
# clean.sh — close idle/done cmux tabs and clean up stale state
#
# Usage:
#   karen clean              # interactive: shows idle tabs, asks before closing
#   karen clean --force      # close all idle tabs without asking
#   karen clean --all        # close ALL agent tabs (nuclear option)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
source "$ROOT/lib/hub.sh"

HUB_DIR=$(resolve_hub_dir) || exit 1
STATE="$HUB_DIR/state"
MODE="${1:---interactive}"

export KAREN_HUB_DIR="$HUB_DIR"
source "$ROOT/lib/mux.sh"

echo "=== Karen Clean ==="
echo ""

# Get all active workspaces from cmux
ACTIVE_WS=$(mux_list 2>/dev/null || true)
if [[ -z "$ACTIVE_WS" ]]; then
  echo "No active workspaces found."
  exit 0
fi

CLOSED=0
KEPT=0

# Check each workspace state file
for ws_file in "$STATE"/*_workspace; do
  [[ -f "$ws_file" ]] || continue
  AGENT_ID=$(basename "$ws_file" _workspace)
  WS_ID=$(cat "$ws_file")

  # Skip manager — never auto-close
  SHORT_ROLE=$(extract_role "$AGENT_ID")
  if [[ "$SHORT_ROLE" == "manager" && "$MODE" != "--all" ]]; then
    KEPT=$((KEPT + 1))
    continue
  fi

  # Check if workspace still exists
  if ! echo "$ACTIVE_WS" | grep -q "$WS_ID"; then
    # Workspace already gone — just clean state files
    rm -f "$ws_file" "$STATE/${AGENT_ID}_surface" "$STATE/${AGENT_ID}_done"
    echo "  🧹 $AGENT_ID — stale state cleaned (workspace already gone)"
    continue
  fi

  # Check screen for idle indicators
  SCREEN=$(cmux read-screen --workspace "$WS_ID" --lines 10 2>/dev/null || true)
  IS_IDLE=false

  if echo "$SCREEN" | grep -qE "^❯\s*$|^>\s*$|Needs Input"; then
    IS_IDLE=true
  fi
  # Session ended indicators
  if echo "$SCREEN" | grep -qE "Sautéed for|Cooked for|Brewed for|has been completed"; then
    IS_IDLE=true
  fi

  if [[ "$MODE" == "--all" ]]; then
    # Kill everything
    mux_close "$AGENT_ID" 2>/dev/null || cmux close-workspace "$WS_ID" 2>/dev/null || true
    rm -f "$ws_file" "$STATE/${AGENT_ID}_surface" "$STATE/${AGENT_ID}_done"
    echo "  ✗ $AGENT_ID ($WS_ID) — closed"
    CLOSED=$((CLOSED + 1))

  elif $IS_IDLE; then
    if [[ "$MODE" == "--force" ]]; then
      mux_close "$AGENT_ID" 2>/dev/null || cmux close-workspace "$WS_ID" 2>/dev/null || true
      rm -f "$ws_file" "$STATE/${AGENT_ID}_surface" "$STATE/${AGENT_ID}_done"
      echo "  ✗ $AGENT_ID ($WS_ID) — idle, closed"
      CLOSED=$((CLOSED + 1))
    else
      echo "  ⏸ $AGENT_ID ($WS_ID) — idle"
      CLOSED=$((CLOSED + 1))  # count for summary
    fi

  else
    echo "  ✓ $AGENT_ID ($WS_ID) — active, keeping"
    KEPT=$((KEPT + 1))
  fi
done

# Also find orphan tabs — cmux workspaces with no state file
if command -v cmux &>/dev/null; then
  while IFS= read -r line; do
    WS_ID=$(echo "$line" | grep -oE 'workspace:[0-9]+' || true)
    [[ -z "$WS_ID" ]] && continue

    # Check if any state file references this workspace
    FOUND=false
    for ws_file in "$STATE"/*_workspace; do
      [[ -f "$ws_file" ]] || continue
      if grep -q "$WS_ID" "$ws_file" 2>/dev/null; then
        FOUND=true
        break
      fi
    done

    if ! $FOUND; then
      # Check if it's the manager's own workspace (skip)
      MANAGER_WS=""
      [[ -f "$STATE/manager_workspace" ]] && MANAGER_WS=$(cat "$STATE/manager_workspace")
      for mws in "$STATE"/*-manager_workspace; do
        [[ -f "$mws" ]] && MANAGER_WS="$MANAGER_WS $(cat "$mws")"
      done
      if echo "$MANAGER_WS" | grep -q "$WS_ID"; then
        continue
      fi

      WS_NAME=$(echo "$line" | sed "s/$WS_ID//" | xargs)
      if [[ "$MODE" == "--force" || "$MODE" == "--all" ]]; then
        cmux close-workspace "$WS_ID" 2>/dev/null || true
        echo "  ✗ orphan $WS_ID ($WS_NAME) — no state file, closed"
        CLOSED=$((CLOSED + 1))
      else
        echo "  👻 orphan $WS_ID ($WS_NAME) — no state file (use --force to close)"
      fi
    fi
  done <<< "$ACTIVE_WS"
fi

echo ""
echo "---"
if [[ "$MODE" == "--interactive" ]]; then
  echo "Found $CLOSED idle/orphan tab(s), $KEPT active."
  echo "Run 'karen clean --force' to close idle tabs."
  echo "Run 'karen clean --all' to close everything."
else
  echo "Closed $CLOSED tab(s), kept $KEPT."
fi
