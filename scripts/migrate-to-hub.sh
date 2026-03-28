#!/usr/bin/env bash
# migrate-to-hub.sh — migrate a project's .agent/ data to the central hub
#
# Usage: migrate-to-hub.sh <project_key> <project_dir>
#
# Copies memory, inbox, context, and comms to the hub.
# Does NOT delete the original .agent/ directory.

set -euo pipefail

PROJECT_KEY="${1:?Usage: migrate-to-hub.sh <project_key> <project_dir>}"
PROJECT_DIR="${2:?Usage: migrate-to-hub.sh <project_key> <project_dir>}"
HUB_DIR="${KAREN_HUB_DIR:-$HOME/.karen/hub}"

OLD_AGENT="$PROJECT_DIR/.agent"

if [[ ! -d "$OLD_AGENT" ]]; then
  echo "ERROR: No .agent/ directory found in $PROJECT_DIR" >&2
  exit 1
fi

echo "▸ Migrating $PROJECT_KEY from $OLD_AGENT → $HUB_DIR"

mkdir -p "$HUB_DIR/inbox" "$HUB_DIR/state" "$HUB_DIR/memory" "$HUB_DIR/context/$PROJECT_KEY"

# 1. Migrate memory files
if [[ -d "$OLD_AGENT/memory" ]]; then
  for f in "$OLD_AGENT/memory"/*.md; do
    [[ -f "$f" ]] || continue
    BASENAME=$(basename "$f")
    if [[ "$BASENAME" == "shared.md" ]]; then
      # Append to global shared memory
      if [[ -f "$HUB_DIR/memory/shared.md" ]]; then
        echo "" >> "$HUB_DIR/memory/shared.md"
        echo "## Migrated from $PROJECT_KEY" >> "$HUB_DIR/memory/shared.md"
        cat "$f" >> "$HUB_DIR/memory/shared.md"
      else
        cp "$f" "$HUB_DIR/memory/shared.md"
      fi
      echo "  ✓ memory/shared.md → appended to hub shared memory"
    else
      # Prefix with project key
      ROLE="${BASENAME%.md}"
      cp "$f" "$HUB_DIR/memory/${PROJECT_KEY}-${ROLE}.md"
      echo "  ✓ memory/$BASENAME → memory/${PROJECT_KEY}-${ROLE}.md"
    fi
  done
fi

# 2. Migrate inbox files
if [[ -d "$OLD_AGENT/inbox" ]]; then
  for f in "$OLD_AGENT/inbox"/*.jsonl; do
    [[ -f "$f" ]] || continue
    BASENAME=$(basename "$f")
    ROLE="${BASENAME%.jsonl}"
    cp "$f" "$HUB_DIR/inbox/${PROJECT_KEY}-${ROLE}.jsonl"
    echo "  ✓ inbox/$BASENAME → inbox/${PROJECT_KEY}-${ROLE}.jsonl"
  done
fi

# 3. Migrate context files
if [[ -d "$OLD_AGENT/context" ]]; then
  for f in "$OLD_AGENT/context"/*; do
    [[ -f "$f" ]] || continue
    cp "$f" "$HUB_DIR/context/$PROJECT_KEY/"
    echo "  ✓ context/$(basename "$f") → context/$PROJECT_KEY/$(basename "$f")"
  done
fi

# 4. Migrate inbox cursors from state
if [[ -d "$OLD_AGENT/state" ]]; then
  for f in "$OLD_AGENT/state"/*_inbox_cursor; do
    [[ -f "$f" ]] || continue
    ROLE=$(basename "$f" _inbox_cursor)
    cp "$f" "$HUB_DIR/state/${PROJECT_KEY}-${ROLE}_inbox_cursor"
    echo "  ✓ state/${ROLE}_inbox_cursor → state/${PROJECT_KEY}-${ROLE}_inbox_cursor"
  done
fi

# 5. Append communications log
if [[ -f "$OLD_AGENT/communications.md" ]]; then
  {
    echo ""
    echo "# ═══ Migrated from $PROJECT_KEY ═══"
    echo ""
    cat "$OLD_AGENT/communications.md"
  } >> "$HUB_DIR/communications.md"
  echo "  ✓ communications.md → appended to hub comms"
fi

echo ""
echo "✓ Migration complete for $PROJECT_KEY"
echo "  Original .agent/ preserved at: $OLD_AGENT"
echo "  To clean up: rm -rf $OLD_AGENT"
