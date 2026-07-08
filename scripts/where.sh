#!/usr/bin/env bash
# where.sh — print the resolved path model for this workspace/hub
#
# Usage:
#   ./scripts/where.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

source "$ROOT/lib/hub.sh"

# Which config file won, and via which tier of the ladder (explicit env >
# nearest workspace .karen/config.yaml > global ~/.karen/config.yaml).
CONFIG_FOUND_WORKSPACE=false
if CONFIG_FILE=$(resolve_karen_config); then
  CONFIG_FOUND_WORKSPACE=true
fi
if [[ -n "${KAREN_CONFIG:-}" ]]; then
  CONFIG_TIER="explicit (\$KAREN_CONFIG)"
elif $CONFIG_FOUND_WORKSPACE; then
  CONFIG_TIER="nearest workspace config (upward search)"
else
  CONFIG_TIER="global fallback"
fi

# Which tier resolved the hub dir — mirrors resolve_hub_dir()'s own priority
# order so this diagnostic explains *why*, not just *what*.
HUB_DIR=$(resolve_hub_dir 2>/dev/null || true)
WORKSPACE_ROOT="N/A (central-hub/standalone)"
if [[ -n "${KAREN_HUB_DIR:-}" ]]; then
  HUB_TIER="explicit (\$KAREN_HUB_DIR)"
elif [[ -n "${KAREN_PROJECT_AGENT_DIR:-}" && -d "$KAREN_PROJECT_AGENT_DIR" ]]; then
  HUB_TIER="explicit (\$KAREN_PROJECT_AGENT_DIR)"
elif $CONFIG_FOUND_WORKSPACE && [[ -f "$CONFIG_FILE" ]]; then
  HUB_TIER="nearest workspace config"
  # The workspace root is the directory containing .karen/, not .karen/ itself.
  WORKSPACE_ROOT="$(dirname "$(dirname "$CONFIG_FILE")")"
elif [[ -d "$(pwd)/.agent" ]]; then
  HUB_TIER="standalone (.agent in cwd)"
elif [[ -n "$HUB_DIR" ]]; then
  HUB_TIER="standalone (.agent found upward)"
else
  HUB_TIER="unresolved"
fi

echo "╔══════════════════════════════════════════╗"
echo "║   karen where — resolved path model      ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "cwd:              $(pwd)"
echo "scaffold root:    $ROOT"
echo "workspace root:   $WORKSPACE_ROOT"
echo "config file:      $CONFIG_FILE $([[ -f "$CONFIG_FILE" ]] && echo "(exists)" || echo "(missing)")"
echo "config tier:      $CONFIG_TIER"
echo "\$KAREN_CONFIG:    ${KAREN_CONFIG:-<unset>}"
echo "\$KAREN_HUB_DIR:   ${KAREN_HUB_DIR:-<unset>}"
echo ""

if [[ -z "$HUB_DIR" ]]; then
  echo "hub dir:          UNRESOLVED — no hub or .agent/ directory found."
  echo "                  Set KAREN_HUB_DIR, run 'karen up', or cd into a project"
  echo "                  initialized with 'karen add' / init.sh, or create a"
  echo "                  .karen/config.yaml to make this dir a self-contained"
  echo "                  workspace."
  exit 1
fi

echo "hub dir:          $HUB_DIR"
echo "hub tier:         $HUB_TIER"
echo "inbox dir:        $HUB_DIR/inbox"
echo "state dir:        $HUB_DIR/state"
echo "memory dir:       $HUB_DIR/memory"
echo "context dir:      $HUB_DIR/context"
echo "knowledge dir:    $HUB_DIR/knowledge"
echo "beads dir:        $HUB_DIR/beads"
echo "communications:   $HUB_DIR/communications.md"
