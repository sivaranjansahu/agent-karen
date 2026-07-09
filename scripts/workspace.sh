#!/usr/bin/env bash
# workspace.sh — scaffold and list karen workspaces
#
# A workspace groups projects by domain (e.g. "development", "marketing").
# It is its OWN git repo holding the shared brain (memory, comms, inboxes) —
# projects are referenced by pointer (config.yaml `projects.<key>.dir`), not
# contained. See docs/workspace-model-design.md.
#
# Usage:
#   karen workspace create <name>   Scaffold ~/karen-workspaces/<name>/ as its own git repo
#   karen workspace list            List existing workspaces
#
# P1 scope: scaffold only — purely additive, no remote automation (document
# private-remote creation as a manual follow-up, same as the fleet repo).

set -euo pipefail

WORKSPACES_ROOT="${KAREN_WORKSPACES_ROOT:-$HOME/karen-workspaces}"

CMD="${1:-}"
shift || true

case "$CMD" in
  create)
    NAME="${1:?Usage: karen workspace create <name>}"
    WS_DIR="$WORKSPACES_ROOT/$NAME"

    if [[ -e "$WS_DIR" ]]; then
      echo "ERROR: workspace '$NAME' already exists at $WS_DIR" >&2
      exit 1
    fi

    mkdir -p "$WS_DIR/.karen/inbox" "$WS_DIR/.karen/memory" "$WS_DIR/.karen/state" "$WS_DIR/.karen/knowledge"

    cat > "$WS_DIR/.karen/config.yaml" << YAML
# Karen workspace: $NAME
# Groups projects by domain — each entry is a POINTER (dir:) to the
# project's own code repo, not a copy. See docs/workspace-model-design.md.
projects: {}
YAML

    cat > "$WS_DIR/.karen/communications.md" << COMMS
# Agent Communications Log — workspace: $NAME

> Workspace created: $(date "+%Y-%m-%d %H:%M:%S UTC")

All inter-agent messages, spawns, and escalations across every project in
this workspace are appended here automatically by \`scripts/msg.sh\` and
\`scripts/spawn.sh\`.

---

COMMS

    echo "# Shared Memory — workspace: $NAME" > "$WS_DIR/.karen/memory/shared.md"

    git init -q "$WS_DIR"
    git -C "$WS_DIR" add -A
    git -C "$WS_DIR" commit -q -m "init: scaffold $NAME workspace" || true

    echo "✓ Workspace '$NAME' created at $WS_DIR"
    echo "  Own git repo — no remote configured yet (P1 scope)."
    echo "  Manual follow-up: create a private remote and 'git push -u origin main' (same as the fleet repo)."
    echo "  Register a project: cd $WS_DIR && KAREN_CONFIG=$WS_DIR/.karen/config.yaml karen add <project-dir>"
    ;;

  list)
    if [[ ! -d "$WORKSPACES_ROOT" ]]; then
      echo "No workspaces found ($WORKSPACES_ROOT does not exist)."
      exit 0
    fi
    FOUND=false
    for WS in "$WORKSPACES_ROOT"/*/; do
      [[ -f "${WS}.karen/config.yaml" ]] || continue
      FOUND=true
      echo "$(basename "$WS")  ($WS)"
    done
    if [[ "$FOUND" == "false" ]]; then
      echo "No workspaces found in $WORKSPACES_ROOT."
    fi
    ;;

  *)
    echo "Usage: karen workspace {create <name>|list}" >&2
    exit 1
    ;;
esac
