#!/usr/bin/env bash
# hub.sh — shared functions for central hub resolution and agent ID logic
#
# Source this in any script that needs hub paths or agent ID resolution.
# Usage: source "$ROOT/lib/hub.sh"

# ── Karen config resolution ──────────────────────────────────────────────────
# The single source of truth for "which karen config.yaml applies here."
# Priority (nearest/explicit wins):
#   1. $KAREN_CONFIG — explicit override, used as-is (existence not required;
#      callers that need it to exist already check that themselves).
#   2. Nearest workspace config: walk up from $PWD to /, first .karen/config.yaml
#      that EXISTS wins (nearest ancestor, not furthest).
#   3. Global fallback: ~/.karen/config.yaml (used as-is).
# Every script reading a karen config.yaml should call this instead of hand-rolling
# ${KAREN_CONFIG:-$HOME/.karen/config.yaml}, so workspace-scoped configs are found
# automatically.
#
# Return code doubles as "did we find a workspace-scoped config": 0 if resolved via
# $KAREN_CONFIG or the upward search, 1 if it had to fall back to the bare global
# default (the path is still printed either way — callers that just want "the"
# config file can ignore the exit code; resolve_hub_dir() below uses it to decide
# whether a self-contained workspace hub applies).
resolve_karen_config() {
  if [[ -n "${KAREN_CONFIG:-}" ]]; then
    echo "$KAREN_CONFIG"
    return 0
  fi

  # Guard against a stale/deleted cwd: pwd failing or returning empty must not
  # loop forever — dirname on "" (or ".") returns "." indefinitely, never "/".
  local DIR
  DIR="$(pwd 2>/dev/null)" || DIR=""
  while [[ -n "$DIR" && "$DIR" != "/" ]]; do
    if [[ -f "$DIR/.karen/config.yaml" ]]; then
      echo "$DIR/.karen/config.yaml"
      return 0
    fi
    DIR="$(dirname "$DIR")"
  done

  echo "$HOME/.karen/config.yaml"
  return 1
}

# ── Hub directory resolution ─────────────────────────────────────────────────
# Priority: KAREN_HUB_DIR (central hub) > KAREN_PROJECT_AGENT_DIR >
#           nearest workspace .karen/config.yaml > pwd/.agent (standalone) > error
resolve_hub_dir() {
  local WORKSPACE_CONFIG
  if [[ -n "${KAREN_HUB_DIR:-}" ]]; then
    echo "$KAREN_HUB_DIR"
  elif [[ -n "${KAREN_PROJECT_AGENT_DIR:-}" && -d "$KAREN_PROJECT_AGENT_DIR" ]]; then
    echo "$KAREN_PROJECT_AGENT_DIR"
  elif WORKSPACE_CONFIG=$(resolve_karen_config) && [[ -f "$WORKSPACE_CONFIG" ]]; then
    # A workspace-scoped config was found (not the bare global fallback) — derive
    # its hub: its own `hub:` key if declared, else the config's own directory
    # (self-contained: a workspace needs no hand-wired hub path).
    local WS_HUB
    WS_HUB=$(python3 -c "
import yaml, os
config = yaml.safe_load(open('$WORKSPACE_CONFIG')) or {}
hub = config.get('hub')
print(os.path.expanduser(hub) if hub else '', end='')
" 2>/dev/null || true)
    if [[ -n "$WS_HUB" ]]; then
      echo "$WS_HUB"
    else
      echo "$(dirname "$WORKSPACE_CONFIG")"
    fi
  elif [[ -d "$(pwd)/.agent" ]]; then
    echo "$(pwd)/.agent"
  else
    # Last resort: walk up from pwd to find .agent/ (handles agents that cd'd during work)
    # Same stale-cwd guard as resolve_karen_config() above.
    local DIR
    DIR="$(pwd 2>/dev/null)" || DIR=""
    while [[ -n "$DIR" && "$DIR" != "/" ]]; do
      if [[ -d "$DIR/.agent/inbox" ]]; then
        echo "$DIR/.agent"
        return 0
      fi
      DIR="$(dirname "$DIR")"
    done
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
# "prepare-dev1" -> "prepare", bare "manager" -> $KAREN_PROJECT_KEY or ""
extract_project_key() {
  local AGENT_ID="$1"
  if [[ -n "${KAREN_PROJECT_KEY:-}" ]]; then
    echo "$KAREN_PROJECT_KEY"
  elif [[ "$AGENT_ID" == *-* ]]; then
    echo "${AGENT_ID%%-*}"
  else
    echo ""
  fi
}

# ── Get sender ID ────────────────────────────────────────────────────────────
get_sender_id() {
  if [[ -n "${KAREN_AGENT_ID:-}" ]]; then
    echo "$KAREN_AGENT_ID"
  elif [[ -n "${KAREN_PROJECT_KEY:-}" && -n "${AGENT_ROLE:-}" ]]; then
    echo "${KAREN_PROJECT_KEY}-${AGENT_ROLE}"
  elif [[ -n "${AGENT_ROLE:-}" ]]; then
    # No project context (legacy/old-model agents) — use bare role
    echo "$AGENT_ROLE"
  else
    echo "manager"
  fi
}
