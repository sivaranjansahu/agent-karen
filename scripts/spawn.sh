#!/usr/bin/env bash
# spawn.sh — create a new workspace, launch an agent, and log to communications.md
#
# Usage:
#   ./scripts/spawn.sh <role> "<context>" [working_dir]
#
# Examples:
#   ./scripts/spawn.sh pm "Build an invoicing SaaS. MVP only."
#   ./scripts/spawn.sh dev1 "Implement the auth module. See brief." src/

set -euo pipefail

ROLE="${1:?Usage: spawn.sh <role> \"<context>\" [working_dir]}"
CONTEXT="${2:-}"
WORKDIR="${3:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMS="$ROOT/.agent/communications.md"
FROM="${AGENT_ROLE:-manager}"

# Load multiplexer abstraction
source "$ROOT/lib/mux.sh"

# Resolve role file — 3-tier lookup: project-local → custom-roles → defaults
# Also handles devN → dev.md fallback
ROLE_FILE=""
BASE_ROLE="${ROLE%%[0-9]*}"
for CANDIDATE in \
  "$WORKDIR/.agent-roles/${ROLE}.md" \
  "$WORKDIR/.agent-roles/${BASE_ROLE}.md" \
  "$ROOT/custom-roles/${ROLE}.md" \
  "$ROOT/custom-roles/${BASE_ROLE}.md" \
  "$ROOT/roles/${ROLE}.md" \
  "$ROOT/roles/${BASE_ROLE}.md"; do
  if [[ -f "$CANDIDATE" ]]; then
    ROLE_FILE="$CANDIDATE"
    break
  fi
done
if [[ -z "$ROLE_FILE" ]]; then
  echo "ERROR: No role file for '$ROLE'" >&2
  echo "  Searched: $WORKDIR/.agent-roles/, $ROOT/custom-roles/, $ROOT/roles/" >&2
  exit 1
fi

echo "▸ Spawning $ROLE workspace... (backend: $(mux_backend))"

# Write init message to inbox
mkdir -p "$ROOT/.agent/inbox"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TS_HUMAN=$(date "+%Y-%m-%d %H:%M:%S UTC")
CONTEXT_JSON=$(python3 -c "import json, sys; print(json.dumps(sys.argv[1]))" "$CONTEXT")
echo "{\"from\":\"system\",\"type\":\"init\",\"ts\":\"$TIMESTAMP\",\"body\":$CONTEXT_JSON}" \
  >> "$ROOT/.agent/inbox/${ROLE}.jsonl"

# Log spawn to communications.md
{
  echo "## [$TS_HUMAN] \`$FROM\` → \`$ROLE\` (spawn)"
  echo ""
  echo "**Spawned new agent workspace.** Backend: \`$(mux_backend)\`"
  echo ""
  if [[ -n "$CONTEXT" ]]; then
    echo "**Init context:** $CONTEXT"
    echo ""
  fi
  echo "---"
  echo ""
} >> "$COMMS"

# Bootstrap command for the new workspace:
#   cd → set env → copy role CLAUDE.md → run bd quickstart → launch claude
BOOTSTRAP=$(cat <<EOF
cd "$WORKDIR" && \
  export AGENT_ROLE="$ROLE" && \
  export AGENT_SCAFFOLD_ROOT="$ROOT" && \
  cp "$ROLE_FILE" CLAUDE.md && \
  bd quickstart 2>/dev/null || true && \
  claude "You have been activated as $ROLE. Orient yourself in this order:
1. Read CLAUDE.md for your role instructions.
2. Read \$AGENT_SCAFFOLD_ROOT/.agent/memory/shared.md for cross-agent shared context.
3. If \$AGENT_SCAFFOLD_ROOT/.agent/memory/${ROLE}.md exists, read it for your role-specific memory from prior sessions.
4. If \$AGENT_SCAFFOLD_ROOT/.agent/knowledge/ contains files, scan them for project reference material.
5. Read \$AGENT_SCAFFOLD_ROOT/.agent/inbox/${ROLE}.jsonl for your task context.
6. Begin working immediately.

IMPORTANT: Before you finish your session, write key learnings, decisions, and context you want to preserve to \$AGENT_SCAFFOLD_ROOT/.agent/memory/${ROLE}.md so your next spawn can pick up where you left off."
EOF
)

# Spawn using the detected multiplexer backend
RESULT=$(mux_spawn "$ROLE" "$BOOTSTRAP" "$WORKDIR") || {
  echo "ERROR: Failed to spawn workspace. Backend: $(mux_backend)" >&2
  exit 1
}

mux_notify "Agent spawned" "$ROLE is online"

echo "✓ $ROLE spawned — $(mux_backend):$RESULT"
