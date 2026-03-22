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

# Parse --dangerously-skip-permissions flag
SKIP_PERMS=false
ARGS=()
for arg in "$@"; do
  if [[ "$arg" == "--dangerously-skip-permissions" ]]; then
    SKIP_PERMS=true
  else
    ARGS+=("$arg")
  fi
done

# Build claude flags: broad allow but keep deny rules for safety
CLAUDE_FLAGS=""
if $SKIP_PERMS; then
  CLAUDE_FLAGS='--allowedTools "Bash(*)" "Read" "Write" "Edit" "Glob" "Grep" "WebSearch" "WebFetch" "NotebookEdit"'
fi

ROLE="${ARGS[0]:?Usage: spawn.sh [--dangerously-skip-permissions] <role> \"<context>\" [working_dir]}"
CONTEXT="${ARGS[1]:-}"
WORKDIR="${ARGS[2]:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AGENT_DIR="$WORKDIR/.agent"
COMMS="$AGENT_DIR/communications.md"
FROM="${AGENT_ROLE:-manager}"

# Load multiplexer abstraction
export AGENT_SCAFFOLD_ROOT="$ROOT"
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
mkdir -p "$AGENT_DIR/inbox"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TS_HUMAN=$(date "+%Y-%m-%d %H:%M:%S UTC")
CONTEXT_JSON=$(python3 -c "import json, sys; print(json.dumps(sys.argv[1]))" "$CONTEXT")
echo "{\"from\":\"system\",\"type\":\"init\",\"ts\":\"$TIMESTAMP\",\"body\":$CONTEXT_JSON}" \
  >> "$AGENT_DIR/inbox/${ROLE}.jsonl"

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
  claude $CLAUDE_FLAGS "You have been activated as $ROLE. Orient yourself in this order:
1. Read CLAUDE.md for your role instructions.
2. Read .agent/memory/shared.md for cross-agent shared context.
3. If .agent/memory/${ROLE}.md exists, read it for your role-specific memory from prior sessions.
4. If .agent/knowledge/ contains files, scan them for project reference material.
5. Read .agent/inbox/${ROLE}.jsonl for your task context.
6. Begin working immediately.

CRITICAL PATH INFO: The scaffold scripts are at $ROOT/scripts/. When your role file says \\\$AGENT_SCAFFOLD_ROOT/scripts/msg.sh, use this actual path: $ROOT/scripts/msg.sh. Similarly for spawn.sh, health.sh, shutdown.sh.

IMPORTANT: Before you finish your session, write key learnings, decisions, and context you want to preserve to .agent/memory/${ROLE}.md so your next spawn can pick up where you left off."
EOF
)

# Spawn using the detected multiplexer backend
RESULT=$(mux_spawn "$ROLE" "$BOOTSTRAP" "$WORKDIR") || {
  echo "ERROR: Failed to spawn workspace. Backend: $(mux_backend)" >&2
  exit 1
}

mux_notify "Agent spawned" "$ROLE is online"

echo "✓ $ROLE spawned — $(mux_backend):$RESULT"
