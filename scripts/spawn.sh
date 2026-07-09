#!/usr/bin/env bash
# spawn.sh — create a new workspace, launch an agent, and log to communications.md
#
# Usage:
#   ./scripts/spawn.sh [--runtime <claude|pi>] <agent_id_or_role> "<context>" [working_dir]
#
# agent_id_or_role:
#   - Full agent ID: "prepare-dev1" (explicit)
#   - Short role name: "dev1" (auto-prefixed with $KAREN_PROJECT_KEY)
#
# Examples:
#   ./scripts/spawn.sh pm "Build an invoicing SaaS. MVP only."
#   ./scripts/spawn.sh dev1 "Implement the auth module. See brief." src/
#   ./scripts/spawn.sh tagger-dev1 "Cross-project task" ~/Projects/tagger
#   ./scripts/spawn.sh --runtime pi dev1 "Implement the auth module." src/

set -euo pipefail

# ── Parse --runtime flag (may appear anywhere); everything else stays positional ──
RUNTIME_ARG=""
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime) RUNTIME_ARG="${2:?--runtime requires a value}"; shift 2 ;;
    --runtime=*) RUNTIME_ARG="${1#--runtime=}"; shift ;;
    *) POSITIONAL_ARGS+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL_ARGS[@]+"${POSITIONAL_ARGS[@]}"}"

TARGET="${1:?Usage: spawn.sh [--runtime <claude|pi>] <agent_id_or_role> \"<context>\" [working_dir]}"
CONTEXT="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# Load hub resolution helpers
source "$ROOT/lib/hub.sh"

HUB_DIR=$(resolve_hub_dir) || exit 1
AGENT_ID=$(resolve_agent_id "$TARGET")
SHORT_ROLE=$(extract_role "$AGENT_ID")
PROJECT_KEY=$(extract_project_key "$AGENT_ID")

# Resolve working directory: explicit arg > configured project path > KAREN_PROJECT_DIR > pwd
# (resolve_karen_config's return code just distinguishes workspace-found vs.
# global-fallback — irrelevant here, we want the path either way.)
KAREN_CONFIG_FILE=$(resolve_karen_config) || true
CONFIGURED_DIR=""
if [[ -z "${3:-}" && -n "$PROJECT_KEY" && -f "$KAREN_CONFIG_FILE" ]]; then
  CONFIGURED_DIR=$(python3 -c "
import yaml, os, sys
config = yaml.safe_load(open(os.path.expanduser('$KAREN_CONFIG_FILE'))) or {}
proj = (config.get('projects') or {}).get('$PROJECT_KEY')
print(os.path.expanduser(proj['dir']) if proj and proj.get('dir') else '', end='')
" 2>/dev/null || true)
fi

if [[ -n "${3:-}" ]]; then
  WORKDIR="$3"
elif [[ -n "$CONFIGURED_DIR" ]]; then
  WORKDIR="$CONFIGURED_DIR"
elif [[ -n "${KAREN_PROJECT_DIR:-}" ]]; then
  WORKDIR="$KAREN_PROJECT_DIR"
elif [[ -n "$PROJECT_KEY" ]]; then
  echo "ERROR: agent ID '$AGENT_ID' is project-prefixed ('$PROJECT_KEY') but no working directory could be resolved." >&2
  echo "  Checked: explicit arg, '$PROJECT_KEY' in $KAREN_CONFIG_FILE, \$KAREN_PROJECT_DIR." >&2
  echo "  Fix: register the project (karen add <path> --name $PROJECT_KEY) or pass an explicit working_dir." >&2
  exit 1
else
  WORKDIR="$(pwd)"
fi

if [[ ! -d "$WORKDIR" ]]; then
  echo "ERROR: resolved working directory does not exist: $WORKDIR" >&2
  exit 1
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

# Model selection. Precedence: SPAWN_MODEL env (caller's per-spawn discretion —
# e.g. escalate a struggling agent to opus) > role-file directive (a role may
# declare `<!-- model: sonnet -->`, also opus/haiku or a full id) > harness default.
# Lets cheaper roles (devs, lead, UI test engineer) run on Sonnet by default while
# the manager can override to Opus for a specific spawn.
MODEL_FLAG=""
ROLE_MODEL=$(grep -ioE '<!--[[:space:]]*model:[[:space:]]*[a-z0-9._-]+' "$ROLE_FILE" 2>/dev/null | head -1 | sed -E 's/.*model:[[:space:]]*//I' || true)
EFFECTIVE_MODEL="${SPAWN_MODEL:-$ROLE_MODEL}"
if [[ -n "$EFFECTIVE_MODEL" ]]; then
  MODEL_FLAG="--model $EFFECTIVE_MODEL"
  echo "  Model for $SHORT_ROLE: $EFFECTIVE_MODEL$([[ -n "${SPAWN_MODEL:-}" ]] && echo ' (SPAWN_MODEL override)')" >&2
fi

# Runtime selection. Precedence: --runtime arg / SPAWN_RUNTIME env (spawn-time,
# always wins) > config.yaml agents.<agent_key>.runtime (per-agent default) >
# config.yaml project runtime (project default) > "claude" (global default).
# Mirrors the model-selection seam above; claude stays the default so this
# feature is strictly opt-in.
CONFIG_RUNTIME=""
if [[ -n "$PROJECT_KEY" && -f "$KAREN_CONFIG_FILE" ]]; then
  CONFIG_RUNTIME=$(python3 -c "
import yaml, os
config = yaml.safe_load(open(os.path.expanduser('$KAREN_CONFIG_FILE'))) or {}
proj = (config.get('projects') or {}).get('$PROJECT_KEY') or {}
agents = proj.get('agents') or {}
agent_conf = agents.get('$SHORT_ROLE')
agent_runtime = agent_conf.get('runtime') if isinstance(agent_conf, dict) else None
print(agent_runtime or proj.get('runtime') or '', end='')
" 2>/dev/null || true)
fi
EFFECTIVE_RUNTIME="${RUNTIME_ARG:-${SPAWN_RUNTIME:-${CONFIG_RUNTIME:-claude}}}"

case "$EFFECTIVE_RUNTIME" in
  claude|pi) ;;
  *)
    echo "ERROR: unknown runtime '$EFFECTIVE_RUNTIME' (supported: claude, pi)" >&2
    exit 1
    ;;
esac

# ── Check if agent is already alive — reuse instead of duplicate spawn ────────
mkdir -p "$HUB_DIR/inbox" "$HUB_DIR/state" "$HUB_DIR/memory" "$HUB_DIR/context/$PROJECT_KEY"
# BEADS_ROOT points at the project working dir, matching the project-local .beads/
# convention bootstrap.sh/init.sh already use — a separate hub-side beads path here
# would fragment the task DB between the manager and the agents it spawns.
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TS_HUMAN=$(date "+%Y-%m-%d %H:%M:%S UTC")

# Backward-compat (naming transition): an agent spawned before the naming fix
# is still alive under its bare short-role identity — resolve to whichever
# identity actually has a live state file so we reuse it instead of shadowing
# it with a duplicate spawn under the new qualified name. See
# lib/hub.sh:resolve_live_target_id.
LIVE_AGENT_ID=$(resolve_live_target_id "$AGENT_ID" "$SHORT_ROLE" "$HUB_DIR")
WS_FILE="$HUB_DIR/state/${LIVE_AGENT_ID}_workspace"
DISPLAY_NAME="${PROJECT_KEY}:${SHORT_ROLE}"
AGENT_ALIVE=false
EXISTING_WS=""

if [[ -f "$WS_FILE" ]]; then
  EXISTING_WS=$(cat "$WS_FILE")
  ACTIVE_WS=$(mux_list 2>/dev/null || true)
  # Match by workspace ID AND verify the display name on that workspace matches this agent.
  # Matching ID alone can cause stale cross-project reuse: if workspace:1 belonged to a
  # different project's lead and that workspace is still open, ID-only matching would
  # incorrectly treat it as alive. We require the line that contains the ID to also
  # contain the expected display name (project:role) OR the bare short role — a tab
  # spawned before the naming fix was renamed to the bare role (or ":role") only, not
  # the qualified form, and grep -w's word-boundary match still finds "role" inside
  # ":role" correctly.
  WS_LINE=$(echo "$ACTIVE_WS" | grep -E "$EXISTING_WS" | head -1 || true)
  if [[ -n "$WS_LINE" ]] && (echo "$WS_LINE" | grep -qwF "$DISPLAY_NAME" || echo "$WS_LINE" | grep -qwF "$SHORT_ROLE"); then
    AGENT_ALIVE=true
  elif echo "$ACTIVE_WS" | grep -qwF "$DISPLAY_NAME"; then
    # Workspace ID is stale but an identically-named tab exists — recover its ID
    MATCHED_LINE=$(echo "$ACTIVE_WS" | grep -wF "$DISPLAY_NAME" | head -1)
    EXISTING_WS=$(echo "$MATCHED_LINE" | grep -oE 'workspace:[0-9]+' | head -1 || true)
    if [[ -n "$EXISTING_WS" ]]; then
      echo "$EXISTING_WS" > "$WS_FILE"
      AGENT_ALIVE=true
    else
      # Can't recover — treat as dead and clean up
      rm -f "$WS_FILE"
    fi
  else
    # Workspace ID exists but belongs to a different agent — stale state file, clean up
    echo "▸ Stale state: $WS_FILE points to $EXISTING_WS which belongs to a different agent. Cleaning up."
    rm -f "$WS_FILE" "$HUB_DIR/state/${LIVE_AGENT_ID}_surface"
  fi
else
  # No state file — still check if a tab with this name exists (leftover from old spawn)
  ACTIVE_WS=$(mux_list 2>/dev/null || true)
  if echo "$ACTIVE_WS" | grep -qwF "$DISPLAY_NAME"; then
    # Found a matching workspace by exact display name — try to recover its ID
    MATCHED_LINE=$(echo "$ACTIVE_WS" | grep -wF "$DISPLAY_NAME" | head -1)
    EXISTING_WS=$(echo "$MATCHED_LINE" | grep -oE 'workspace:[0-9]+' | head -1 || true)
    if [[ -n "$EXISTING_WS" ]]; then
      echo "$EXISTING_WS" > "$WS_FILE"
      AGENT_ALIVE=true
    fi
  fi
fi

# If agent is detected as alive but can't be woken, kill it and respawn fresh
if $AGENT_ALIVE && [[ -n "$EXISTING_WS" ]]; then
  # Try to wake — if send fails, the workspace might be zombie
  if ! mux_send "$LIVE_AGENT_ID" "ping" 2>/dev/null; then
    echo "▸ $LIVE_AGENT_ID workspace exists but unresponsive — killing and respawning"
    mux_close "$LIVE_AGENT_ID" 2>/dev/null || true
    rm -f "$WS_FILE" "$HUB_DIR/state/${LIVE_AGENT_ID}_surface"
    AGENT_ALIVE=false
  fi
fi

if $AGENT_ALIVE; then
  # Agent is alive — reuse by sending context as a new task message
  echo "▸ $LIVE_AGENT_ID is already alive in $EXISTING_WS — reusing (not spawning)"

  CONTEXT_JSON=$(python3 -c "import json, sys; print(json.dumps(sys.argv[1]))" "$CONTEXT")
  echo "{\"from\":\"$FROM\",\"type\":\"message\",\"ts\":\"$TIMESTAMP\",\"body\":$CONTEXT_JSON}" \
    >> "$HUB_DIR/inbox/${LIVE_AGENT_ID}.jsonl"

  # Log reuse to communications.md
  {
    echo "## [$TS_HUMAN] \`$FROM\` → \`$LIVE_AGENT_ID\` (reuse)"
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
  PROMPT="📬 New task from $FROM. Check ${HUB_DIR}/inbox/${LIVE_AGENT_ID}.jsonl and respond."
  mux_send "$LIVE_AGENT_ID" "$PROMPT" 2>/dev/null && \
    echo "✓ Woke $LIVE_AGENT_ID with new task" || \
    echo "⚠ Send failed — message queued in inbox"

  mux_notify "Task assigned" "$LIVE_AGENT_ID got new work"
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

# Launch dispatch. claude path is byte-for-byte identical to before this
# feature existed (same flags, same order); pi is strictly opt-in.
# Pi runs interactively (prompt as a trailing positional arg, NO -p) so it
# stays open in the tab and can be woken later via mux_send keystrokes —
# same wake mechanism claude already relies on. `-p`/--print would exit
# after one turn, breaking that (see docs/pi-runtime-support-design.md).
if [[ "$EFFECTIVE_RUNTIME" == "pi" ]]; then
  LAUNCH_LINE="pi --tools bash,read,write,edit"
else
  LAUNCH_LINE="claude"
  [[ -n "${SPAWN_RC:-}" ]] && LAUNCH_LINE="$LAUNCH_LINE --remote-control $AGENT_ID"
  LAUNCH_LINE="$LAUNCH_LINE --dangerously-skip-permissions"
  [[ -n "$MODEL_FLAG" ]] && LAUNCH_LINE="$LAUNCH_LINE $MODEL_FLAG"
fi

# Bootstrap command for the new workspace
BOOTSTRAP=$(cat <<EOF
cd "$WORKDIR" && \
  export AGENT_ROLE="$SHORT_ROLE" && \
  export AGENT_SCAFFOLD_ROOT="$ROOT" && \
  export KAREN_HUB_DIR="$HUB_DIR" && \
  export KAREN_AGENT_ID="$AGENT_ID" && \
  export KAREN_PROJECT_KEY="$PROJECT_KEY" && \
  export KAREN_PROJECT_DIR="$WORKDIR" && \
  export BEADS_ROOT="$WORKDIR" && \
  if [[ ! -f CLAUDE.md ]] || ! grep -q '^# ROLE:' CLAUDE.md 2>/dev/null; then cp "$ROLE_FILE" CLAUDE.md; else echo '# Role file preserved (already exists with ROLE header)'; fi && \
  if [[ ! -d .beads ]]; then bd init </dev/null 2>/dev/null || true; fi && \
  bd quickstart 2>/dev/null || true && \
  $LAUNCH_LINE "You have been activated as $AGENT_ID (role: $SHORT_ROLE, project: $PROJECT_KEY). Orient yourself in this order:
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

IMPORTANT: After completing your current task, check your inbox ($HUB_DIR/inbox/${AGENT_ID}.jsonl) for new messages before exiting. If inbox has no new tasks, report to your coordinator that you are idle and available. Only exit if explicitly told to or if no new work arrives within 600 seconds (10 minutes).

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
