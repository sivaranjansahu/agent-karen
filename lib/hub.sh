#!/usr/bin/env bash
# hub.sh — shared functions for central hub resolution and agent ID logic
#
# Source this in any script that needs hub paths or agent ID resolution.
# Usage: source "$ROOT/lib/hub.sh"

# ── Hub directory resolution ─────────────────────────────────────────────────
# Priority: KAREN_HUB_DIR (central hub) > KAREN_PROJECT_AGENT_DIR > pwd/.agent > error
resolve_hub_dir() {
  if [[ -n "${KAREN_HUB_DIR:-}" ]]; then
    echo "$KAREN_HUB_DIR"
  elif [[ -n "${KAREN_PROJECT_AGENT_DIR:-}" && -d "$KAREN_PROJECT_AGENT_DIR" ]]; then
    echo "$KAREN_PROJECT_AGENT_DIR"
  elif [[ -d "$(pwd)/.agent" ]]; then
    echo "$(pwd)/.agent"
  else
    echo "ERROR: No hub or .agent/ directory found. Set KAREN_HUB_DIR or run 'karen up'." >&2
    return 1
  fi
}

# ── Agent ID resolution ──────────────────────────────────────────────────────
# Resolves a target name to a full agent ID.
# If target already contains the project prefix, return as-is.
# Otherwise, prepend KAREN_PROJECT_KEY.
#
# Examples:
#   resolve_agent_id "dev1"           -> "prepare-dev1"  (if KAREN_PROJECT_KEY=prepare)
#   resolve_agent_id "prepare-dev1"   -> "prepare-dev1"  (already qualified)
#   resolve_agent_id "tagger-manager" -> "tagger-manager" (cross-project)
resolve_agent_id() {
  local TARGET="$1"
  # If target contains a dash and doesn't match a known bare role, assume it's already a full ID
  # Known bare roles that contain dashes: none currently
  if [[ "$TARGET" == *-* ]]; then
    echo "$TARGET"
  elif [[ -n "${KAREN_PROJECT_KEY:-}" ]]; then
    echo "${KAREN_PROJECT_KEY}-${TARGET}"
  else
    # No project context — return as-is (legacy mode)
    echo "$TARGET"
  fi
}

# ── Extract short role from agent ID ─────────────────────────────────────────
# "prepare-dev1" -> "dev1", "prepare-manager" -> "manager"
extract_role() {
  local AGENT_ID="$1"
  if [[ -n "${KAREN_PROJECT_KEY:-}" && "$AGENT_ID" == "${KAREN_PROJECT_KEY}-"* ]]; then
    echo "${AGENT_ID#${KAREN_PROJECT_KEY}-}"
  elif [[ "$AGENT_ID" == *-* ]]; then
    # Strip first segment (project key)
    echo "${AGENT_ID#*-}"
  else
    echo "$AGENT_ID"
  fi
}

# ── Extract project key from agent ID ────────────────────────────────────────
# "prepare-dev1" -> "prepare"
extract_project_key() {
  local AGENT_ID="$1"
  if [[ "$AGENT_ID" == *-* ]]; then
    echo "${AGENT_ID%%-*}"
  else
    echo "${KAREN_PROJECT_KEY:-unknown}"
  fi
}

# ── Get sender ID ────────────────────────────────────────────────────────────
get_sender_id() {
  if [[ -n "${KAREN_AGENT_ID:-}" ]]; then
    echo "$KAREN_AGENT_ID"
  elif [[ -n "${KAREN_PROJECT_KEY:-}" && -n "${AGENT_ROLE:-}" ]]; then
    echo "${KAREN_PROJECT_KEY}-${AGENT_ROLE}"
  elif [[ -n "${AGENT_ROLE:-}" ]]; then
    echo "$AGENT_ROLE"
  else
    echo "manager"
  fi
}
