#!/usr/bin/env bash
# spawn.sh — create a new workspace, launch an agent, and log to communications.md
#
# Usage:
#   ./scripts/spawn.sh <agent_id_or_role> "<context>" [working_dir]
#
# agent_id_or_role:
#   - Full agent ID: "prepare-dev1" (explicit)
#   - Short role name: "dev1" (auto-prefixed with $KAREN_PROJECT_KEY)
#
# Examples:
#   ./scripts/spawn.sh pm "Build an invoicing SaaS. MVP only."
#   ./scripts/spawn.sh dev1 "Implement the auth module. See brief." src/
#   ./scripts/spawn.sh tagger-dev1 "Cross-project task" ~/Projects/tagger

set -euo pipefail

TARGET="${1:?Usage: spawn.sh <agent_id_or_role> \"<context>\" [working_dir]}"
CONTEXT="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# Load hub resolution helpers
source "$ROOT/lib/hub.sh"

HUB_DIR=$(resolve_hub_dir) || exit 1
AGENT_ID=$(resolve_agent_id "$TARGET")
SHORT_ROLE=$(extract_role "$AGENT_ID")
PROJECT_KEY=$(extract_project_key "$AGENT_ID")

# Resolve working directory: explicit arg > project dir from config > pwd
if [[ -n "${3:-}" ]]; then
  WORKDIR="$3"
elif [[ -n "${KAREN_PROJECT_DIR:-}" ]]; then
  WORKDIR="$KAREN_PROJECT_DIR"
else
  WORKDIR="$(pwd)"
fi

COMMS="$HUB_DIR/communications.md"
FROM=$(get_sender_id)

# Load multiplexer abstraction
export AGENT_SCAFFOLD_ROOT="$ROOT"
export KAREN_HUB_DIR="$HUB_DIR"
source "$ROOT/lib/mux.sh"

# Resolve role file — 3-tier lookup: project-local → custom-roles → defaults
# Handles: dev1 → dev, makerpad-messenger → messenger
ROLE_FILE=""
BASE_ROLE="${SHORT_ROLE%%[0-9]*}"
for CANDIDATE in \
  "$WORKDIR/.agent-roles/${SHORT_ROLE}.md" \
  "$WORKDIR/.agent-roles/${BASE_ROLE}.md" \
  "$ROOT/custom-roles/${SHORT_ROLE}.md" \
  "$ROOT/custom-roles/${BASE_ROLE}.md" \
  "$ROOT/roles/${SHORT_ROLE}.md" \
  "$ROOT/roles/${BASE_ROLE}.md"; do
  if [[ -f "$CANDIDATE" ]]; then
    ROLE_FILE="$CANDIDATE"
    break
  fi
done
if [[ -z "$ROLE_FILE" ]]; then
  echo "ERROR: No role file for '$SHORT_ROLE' (agent: $AGENT_ID)" >&2
  echo "  Searched: $WORKDIR/.agent-roles/, $ROOT/custom-roles/, $ROOT/roles/" >&2
  exit 1
fi

# ── Check if agent is already alive — reuse instead of duplicate spawn ────────
mkdir -p "$HUB_DIR/inbox" "$HUB_DIR/state" "$HUB_DIR/memory" "$HUB_DIR/context/$PROJECT_KEY"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TS_HUMAN=$(date "+%Y-%m-%d %H:%M:%S UTC")

WS_FILE="$HUB_DIR/state/${AGENT_ID}_workspace"
AGENT_ALIVE=false
if [[ -f "$WS_FILE" ]]; then
  EXISTING_WS=$(cat "$WS_FILE")
  ACTIVE_WS=$(mux_list 2>/dev/null || true)
  if echo "$ACTIVE_WS" | grep -qE "$EXISTING_WS|$AGENT_ID"; then
    AGENT_ALIVE=true
  fi
fi

if $AGENT_ALIVE; then
  # Agent is alive — reuse by sending context as a new task message
  echo "▸ $AGENT_ID is already alive in $EXISTING_WS — reusing (not spawning)"

  CONTEXT_JSON=$(python3 -c "import json, sys; print(json.dumps(sys.argv[1]))" "$CONTEXT")
  echo "{\"from\":\"$FROM\",\"type\":\"message\",\"ts\":\"$TIMESTAMP\",\"body\":$CONTEXT_JSON}" \
    >> "$HUB_DIR/inbox/${AGENT_ID}.jsonl"

  # Log reuse to communications.md
  {
    echo "## [$TS_HUMAN] \`$FROM\` → \`$AGENT_ID\` (reuse)"
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
  PROMPT="📬 New task from $FROM. Check ${HUB_DIR}/inbox/${AGENT_ID}.jsonl and respond."
  mux_send "$AGENT_ID" "$PROMPT" 2>/dev/null && \
    echo "✓ Woke $AGENT_ID with new task" || \
    echo "⚠ Send failed — message queued in inbox"

  mux_notify "Task assigned" "$AGENT_ID got new work"
  exit 0
fi

# ── Agent is not alive — proceed with fresh spawn ────────────────────────────

# Clean up stale state files if they exist
rm -f "$HUB_DIR/state/${AGENT_ID}_workspace" "$HUB_DIR/state/${AGENT_ID}_surface"

echo "▸ Spawning $AGENT_ID workspace... (backend: $(mux_backend))"

# Write init message to inbox
CONTEXT_JSON=$(python3 -c "import json, sys; print(json.dumps(sys.argv[1]))" "$CONTEXT")
echo "{\"from\":\"system\",\"type\":\"init\",\"ts\":\"$TIMESTAMP\",\"body\":$CONTEXT_JSON}" \
  >> "$HUB_DIR/inbox/${AGENT_ID}.jsonl"

# Log spawn to communications.md
{
  echo "## [$TS_HUMAN] \`$FROM\` → \`$AGENT_ID\` (spawn)"
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

# Bootstrap command for the new workspace
BOOTSTRAP=$(cat <<EOF
cd "$WORKDIR" && \
  export AGENT_ROLE="$SHORT_ROLE" && \
  export AGENT_SCAFFOLD_ROOT="$ROOT" && \
  export KAREN_HUB_DIR="$HUB_DIR" && \
  export KAREN_AGENT_ID="$AGENT_ID" && \
  export KAREN_PROJECT_KEY="$PROJECT_KEY" && \
  export KAREN_PROJECT_DIR="$WORKDIR" && \
  if [[ ! -f CLAUDE.md ]] || ! grep -q '^# ROLE:' CLAUDE.md 2>/dev/null; then cp "$ROLE_FILE" CLAUDE.md; else echo '# Role file preserved (already exists with ROLE header)'; fi && \
  bd quickstart 2>/dev/null || true && \
  claude --dangerously-skip-permissions "You have been activated as $AGENT_ID (role: $SHORT_ROLE, project: $PROJECT_KEY). Orient yourself in this order:
1. Read CLAUDE.md for your role instructions.
2. Read $HUB_DIR/memory/shared.md for cross-agent shared context.
3. If $HUB_DIR/memory/${AGENT_ID}.md exists, read it for your memory from prior sessions.
4. If $HUB_DIR/knowledge/$PROJECT_KEY/ contains files, scan them for project reference material.
5. Read $HUB_DIR/inbox/${AGENT_ID}.jsonl for your task context.
6. Begin working immediately.

IDENTITY: You are $AGENT_ID. Your short role is $SHORT_ROLE. Your project is $PROJECT_KEY.

PATHS — Central hub (all agent state):
  Inbox: $HUB_DIR/inbox/${AGENT_ID}.jsonl
  Memory: $HUB_DIR/memory/${AGENT_ID}.md
  Shared memory: $HUB_DIR/memory/shared.md
  Context: $HUB_DIR/context/$PROJECT_KEY/
  Knowledge: $HUB_DIR/knowledge/$PROJECT_KEY/
  Comms log: $HUB_DIR/communications.md

SCRIPTS: $ROOT/scripts/msg.sh, spawn.sh, health.sh, shutdown.sh, wake.sh

MESSAGING: Use msg.sh for all communication. Short names work within your project:
  $ROOT/scripts/msg.sh manager \"update\" result     → sends to $PROJECT_KEY-manager
  $ROOT/scripts/msg.sh tagger-dev1 \"hello\" message  → cross-project messaging
NEVER call cmux send directly — always use msg.sh or wake.sh.

IMPORTANT: After completing your current task, check your inbox ($HUB_DIR/inbox/${AGENT_ID}.jsonl) for new messages before exiting. If inbox has no new tasks, report to your coordinator that you are idle and available. Only exit if explicitly told to or if no new work arrives within 60 seconds.

IMPORTANT: Before you finish your session, write key learnings, decisions, and context you want to preserve to $HUB_DIR/memory/${AGENT_ID}.md so your next spawn can pick up where you left off."
EOF
)

# Spawn using the detected multiplexer backend
RESULT=$(mux_spawn "$AGENT_ID" "$BOOTSTRAP" "$WORKDIR") || {
  echo "ERROR: Failed to spawn workspace. Backend: $(mux_backend)" >&2
  exit 1
}

# Rename tab to project:role format for readability (e.g., "prepare:dev1")
DISPLAY_NAME="${PROJECT_KEY}:${SHORT_ROLE}"
mux_rename "$AGENT_ID" "$DISPLAY_NAME" 2>/dev/null || true

mux_notify "Agent spawned" "$DISPLAY_NAME is online"

echo "✓ $AGENT_ID spawned as $DISPLAY_NAME — $(mux_backend):$RESULT"
