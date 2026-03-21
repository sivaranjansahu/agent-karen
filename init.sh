#!/usr/bin/env bash
# init.sh — Initialize agent scaffold for a project
#
# Usage:
#   ./init.sh /path/to/your/project
#   ./init.sh .                        # current directory
#
# This wires the scaffold into your project without modifying your code.
# Run once per project. Safe to re-run (additive, non-destructive).

set -euo pipefail

SCAFFOLD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse arguments
KNOWLEDGE_DIRS=()
PROJECT_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --knowledge|-k)
      shift
      KNOWLEDGE_DIRS+=("$1")
      shift
      ;;
    *)
      PROJECT_DIR="$1"
      shift
      ;;
  esac
done

if [[ -z "$PROJECT_DIR" ]]; then
  echo "Usage: ./init.sh /path/to/your/project [--knowledge /path/to/docs] [--knowledge /path/to/more/docs]"
  exit 1
fi

# Resolve to absolute path
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

echo "▸ Initializing agent scaffold"
echo "  Scaffold: $SCAFFOLD_ROOT"
echo "  Project:  $PROJECT_DIR"
echo ""

# ── 1. Check dependencies ────────────────────────────────────────────────────

if ! command -v cmux &>/dev/null; then
  echo "ERROR: cmux is not installed or not in PATH."
  echo "  Install: https://cmux.com"
  echo "  Then: sudo ln -sf /Applications/cmux.app/Contents/Resources/bin/cmux /usr/local/bin/cmux"
  exit 1
fi

if ! command -v claude &>/dev/null; then
  echo "ERROR: claude (Claude Code CLI) is not installed or not in PATH."
  echo "  Install: npm install -g @anthropic-ai/claude-code"
  exit 1
fi

echo "  ✓ cmux found"
echo "  ✓ claude found"

# ── 2. Install beads if missing ───────────────────────────────────────────────

if ! command -v bd &>/dev/null; then
  echo "  ⚠ Beads (bd) not found — installing..."
  if command -v pip3 &>/dev/null; then
    pip3 install beads-cli --quiet 2>/dev/null || pip3 install beads --quiet 2>/dev/null || {
      echo "  ⚠ Could not install beads. Install manually: pip3 install beads-cli"
      echo "  Continuing without beads — agents can still work, just no persistent task memory."
    }
  else
    echo "  ⚠ pip3 not found. Install beads manually: pip3 install beads-cli"
    echo "  Continuing without beads."
  fi
else
  echo "  ✓ beads (bd) found"
fi

# ── 3. Create .agent/ runtime directories ─────────────────────────────────────

echo ""
echo "▸ Creating runtime directories"

# Runtime state lives in the PROJECT, not the scaffold install
mkdir -p "$PROJECT_DIR/.agent/inbox"
mkdir -p "$PROJECT_DIR/.agent/context"
mkdir -p "$PROJECT_DIR/.agent/state"
mkdir -p "$PROJECT_DIR/.agent/memory"
mkdir -p "$PROJECT_DIR/.agent/knowledge"

# Initialize communications log if missing
if [[ ! -f "$PROJECT_DIR/.agent/communications.md" ]]; then
  cat > "$PROJECT_DIR/.agent/communications.md" << EOF
# Agent Communications Log

> Session started: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

All inter-agent messages, spawns, and escalations are appended here automatically
by \`scripts/msg.sh\` and \`scripts/spawn.sh\`.

Format: \`## [timestamp] sender → recipient (type)\`

Types: \`spawn\` | \`message\` | \`question\` | \`escalation\` | \`result\` | \`unblock\`

---

EOF
  echo "  ✓ Created communications.md"
fi

echo "  ✓ .agent/ directories ready"

# ── 4. Store project path and scaffold root ───────────────────────────────────

echo "$PROJECT_DIR" > "$PROJECT_DIR/.agent/state/project_dir"
echo "$SCAFFOLD_ROOT" > "$PROJECT_DIR/.agent/state/scaffold_root"
echo "  ✓ Project path stored"

# ── 5. Link knowledge base directories ────────────────────────────────────────

if [[ ${#KNOWLEDGE_DIRS[@]} -gt 0 ]]; then
  echo ""
  echo "▸ Linking knowledge base"
  mkdir -p "$PROJECT_DIR/.agent/knowledge"
  for KDIR in "${KNOWLEDGE_DIRS[@]}"; do
    KDIR_ABS="$(cd "$KDIR" && pwd)"
    LINK_NAME=$(basename "$KDIR_ABS")
    ln -sfn "$KDIR_ABS" "$PROJECT_DIR/.agent/knowledge/$LINK_NAME"
    echo "  ✓ Linked: $LINK_NAME → $KDIR_ABS"
  done
fi

# ── 6. Initialize beads in project if needed ─────────────────────────────────

if command -v bd &>/dev/null; then
  if [[ ! -d "$PROJECT_DIR/.beads" ]]; then
    (cd "$PROJECT_DIR" && bd init 2>/dev/null) || true
    echo "  ✓ Beads initialized in project"
  else
    echo "  ✓ Beads already initialized"
  fi
fi

# ── 6. Make scripts executable ────────────────────────────────────────────────

chmod +x "$SCAFFOLD_ROOT/bootstrap.sh" "$SCAFFOLD_ROOT/init.sh" 2>/dev/null
chmod +x "$SCAFFOLD_ROOT/scripts/"*.sh 2>/dev/null
chmod +x "$SCAFFOLD_ROOT/hooks/"*.sh 2>/dev/null
echo "  ✓ Scripts are executable"

# ── 7. Done ───────────────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════"
echo "  ✓ Agent scaffold initialized!"
echo "═══════════════════════════════════════════"
echo ""
echo "  Quick start:"
echo ""
echo "  # Start the manager agent"
echo "  karen start $PROJECT_DIR"
echo ""
echo "  # Spawn agents"
echo "  karen spawn pm \"Your task here\" $PROJECT_DIR"
echo ""
echo "  # Check agent health"
echo "  karen health"
echo ""
echo "  # Customize roles"
echo "  mkdir -p $PROJECT_DIR/.agent-roles"
echo "  cp $SCAFFOLD_ROOT/roles/pm.md $PROJECT_DIR/.agent-roles/pm.md"
echo "  # Project-local roles take priority over defaults."
echo ""
