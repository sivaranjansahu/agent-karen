#!/usr/bin/env bash
# wake.sh — send text to another agent's terminal (with Enter)
#
# This is a thin wrapper around cmux send that always appends \n.
# Agents should use this instead of calling cmux send directly.
#
# Usage:
#   ./scripts/wake.sh <role> "your message here"
#
# Examples:
#   ./scripts/wake.sh dev1 "Check your inbox for a new task"
#   ./scripts/wake.sh manager "Task complete — see results"
#
# NOTE: For sending structured messages (with inbox + comms logging),
# use msg.sh instead. wake.sh is only for raw terminal text injection.

set -euo pipefail

ROLE="${1:?Usage: wake.sh <role> \"<message>\"}"
TEXT="${2:?Usage: wake.sh <role> \"<message>\"}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# Resolve agent dir
if [[ -n "${KAREN_PROJECT_AGENT_DIR:-}" && -d "$KAREN_PROJECT_AGENT_DIR" ]]; then
  AGENT_DIR="$KAREN_PROJECT_AGENT_DIR"
elif [[ -d "$(pwd)/.agent" ]]; then
  AGENT_DIR="$(pwd)/.agent"
else
  echo "ERROR: No .agent/ directory found." >&2
  exit 1
fi

WS_FILE="$AGENT_DIR/state/${ROLE}_workspace"
if [[ ! -f "$WS_FILE" ]]; then
  echo "⚠ No workspace for $ROLE" >&2
  exit 1
fi

WS_ID=$(cat "$WS_FILE")
cmux send --workspace "$WS_ID" "${TEXT}"$'\n' 2>/dev/null
echo "✓ Sent to $ROLE"
