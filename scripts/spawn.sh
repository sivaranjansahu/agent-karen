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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
AGENT_DIR="$WORKDIR/.agent"
COMMS="$AGENT_DIR/communications.md"
FROM="${AGENT_ROLE:-manager}"

# Load multiplexer abstraction
export AGENT_SCAFFOLD_ROOT="$ROOT"
source "$ROOT/lib/mux.sh"

# Resolve role file — 3-tier lookup: project-local → custom-roles → defaults
# Handles: devN → dev, makerpad-messenger → messenger, makerpad-dev1 → dev
ROLE_FILE=""
BASE_ROLE="${ROLE%%[0-9]*}"
# Strip project prefix (e.g., makerpad-messenger → messenger)
SHORT_ROLE="${ROLE#*-}"
SHORT_BASE="${SHORT_ROLE%%[0-9]*}"
for CANDIDATE in \
  "$WORKDIR/.agent-roles/${ROLE}.md" \
  "$WORKDIR/.agent-roles/${BASE_ROLE}.md" \
  "$WORKDIR/.agent-roles/${SHORT_ROLE}.md" \
  "$WORKDIR/.agent-roles/${SHORT_BASE}.md" \
  "$ROOT/custom-roles/${ROLE}.md" \
  "$ROOT/custom-roles/${BASE_ROLE}.md" \
  "$ROOT/custom-roles/${SHORT_ROLE}.md" \
  "$ROOT/custom-roles/${SHORT_BASE}.md" \
  "$ROOT/roles/${ROLE}.md" \
  "$ROOT/roles/${BASE_ROLE}.md" \
  "$ROOT/roles/${SHORT_ROLE}.md" \
  "$ROOT/roles/${SHORT_BASE}.md"; do
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

# ── Check if agent is already alive — reuse instead of duplicate spawn ────────
mkdir -p "$AGENT_DIR/inbox" "$AGENT_DIR/state"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TS_HUMAN=$(date "+%Y-%m-%d %H:%M:%S UTC")

WS_FILE="$AGENT_DIR/state/${ROLE}_workspace"
AGENT_ALIVE=false
if [[ -f "$WS_FILE" ]]; then
  EXISTING_WS=$(cat "$WS_FILE")
  ACTIVE_WS=$(mux_list 2>/dev/null || true)
  if echo "$ACTIVE_WS" | grep -qE "$EXISTING_WS|$ROLE"; then
    AGENT_ALIVE=true
  fi
fi

if $AGENT_ALIVE; then
  # Agent is alive — reuse by sending context as a new task message
  echo "▸ $ROLE is already alive in $EXISTING_WS — reusing (not spawning)"

  CONTEXT_JSON=$(python3 -c "import json, sys; print(json.dumps(sys.argv[1]))" "$CONTEXT")
  echo "{\"from\":\"$FROM\",\"type\":\"message\",\"ts\":\"$TIMESTAMP\",\"body\":$CONTEXT_JSON}" \
    >> "$AGENT_DIR/inbox/${ROLE}.jsonl"

  # Log reuse to communications.md
  {
    echo "## [$TS_HUMAN] \`$FROM\` → \`$ROLE\` (reuse)"
    echo ""
    echo "**Reused existing workspace** \`$EXISTING_WS\` instead of spawning."
    echo ""
    if [[ -n "$CONTEXT" ]]; then
      echo "**New task context:** $CONTEXT"
      echo ""
    fi
    echo "---"
    echo ""
  } >> "$COMMS"

  # Wake the agent
  PROMPT="📬 New task from $FROM. Check ${AGENT_DIR}/inbox/${ROLE}.jsonl and respond."
  mux_send "$ROLE" "$PROMPT" 2>/dev/null && \
    echo "✓ Woke $ROLE with new task" || \
    echo "⚠ Send failed — message queued in inbox"

  mux_notify "Task assigned" "$ROLE got new work"
  exit 0
fi

# ── Agent is not alive — proceed with fresh spawn ────────────────────────────

# Clean up stale state files if they exist
rm -f "$AGENT_DIR/state/${ROLE}_workspace" "$AGENT_DIR/state/${ROLE}_surface"

echo "▸ Spawning $ROLE workspace... (backend: $(mux_backend))"

# Write init message to inbox
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
  export KAREN_PROJECT_AGENT_DIR="$WORKDIR/.agent" && \
  if [[ ! -f CLAUDE.md ]] || ! grep -q '^# ROLE:' CLAUDE.md 2>/dev/null; then cp "$ROLE_FILE" CLAUDE.md; else echo '# Role file preserved (already exists with ROLE header)'; fi && \
  bd quickstart 2>/dev/null || true && \
  claude --dangerously-skip-permissions "You have been activated as $ROLE. Orient yourself in this order:
1. Read CLAUDE.md for your role instructions.
2. Read .agent/memory/shared.md for cross-agent shared context.
3. If .agent/memory/${ROLE}.md exists, read it for your role-specific memory from prior sessions.
4. If .agent/knowledge/ contains files, scan them for project reference material.
5. Read .agent/inbox/${ROLE}.jsonl for your task context.
6. Begin working immediately.

CRITICAL PATH INFO: The scaffold scripts are at $ROOT/scripts/. When your role file says \\\$AGENT_SCAFFOLD_ROOT/scripts/msg.sh, use this actual path: $ROOT/scripts/msg.sh. Similarly for spawn.sh, health.sh, shutdown.sh, wake.sh.

NEVER call cmux send directly — it requires a newline suffix that is easy to forget, causing text to sit in the input without submitting. Always use msg.sh (for inbox + logging + wake) or wake.sh (for raw terminal text). Both handle the newline automatically.

ENV VARS: KAREN_PROJECT_AGENT_DIR=$WORKDIR/.agent — use this for all .agent/ paths (inbox, state, memory, comms). AGENT_SCAFFOLD_ROOT=$ROOT — use this for scaffold scripts only.

IMPORTANT: After completing your current task, check your inbox ($WORKDIR/.agent/inbox/${ROLE}.jsonl) for new messages before exiting. If inbox has no new tasks, report to your coordinator that you are idle and available. Only exit if explicitly told to or if no new work arrives within 60 seconds.

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
