#!/usr/bin/env bash
# where.sh — print the resolved path model for this workspace/hub
#
# Usage:
#   ./scripts/where.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

source "$ROOT/lib/hub.sh"

CONFIG_FILE="${KAREN_CONFIG:-$HOME/.karen/config.yaml}"
HUB_DIR=$(resolve_hub_dir 2>/dev/null || true)

echo "╔══════════════════════════════════════════╗"
echo "║   karen where — resolved path model      ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "cwd:              $(pwd)"
echo "scaffold root:    $ROOT"
echo "config file:      $CONFIG_FILE $([[ -f "$CONFIG_FILE" ]] && echo "(exists)" || echo "(missing)")"
echo "\$KAREN_CONFIG:    ${KAREN_CONFIG:-<unset>}"
echo "\$KAREN_HUB_DIR:   ${KAREN_HUB_DIR:-<unset>}"
echo ""

if [[ -z "$HUB_DIR" ]]; then
  echo "hub dir:          UNRESOLVED — no hub or .agent/ directory found."
  echo "                  Set KAREN_HUB_DIR, run 'karen up', or cd into a project"
  echo "                  initialized with 'karen add' / init.sh."
  exit 1
fi

echo "hub dir:          $HUB_DIR"
echo "inbox dir:        $HUB_DIR/inbox"
echo "state dir:        $HUB_DIR/state"
echo "memory dir:       $HUB_DIR/memory"
echo "context dir:      $HUB_DIR/context"
echo "knowledge dir:    $HUB_DIR/knowledge"
echo "beads dir:        $HUB_DIR/beads"
echo "communications:   $HUB_DIR/communications.md"
