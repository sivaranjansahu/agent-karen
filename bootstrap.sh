#!/usr/bin/env bash
# bootstrap.sh — start the manager session in the current cmux workspace
#
# Run this ONCE to kick off the entire system.
# Usage: ./bootstrap.sh [working_dir]

set -euo pipefail

WORKDIR="${1:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "╔══════════════════════════════════════════╗"
echo "║   Multi-Agent cmux Scaffold Bootstrap    ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── 1. Check cmux ─────────────────────────────────────────────────────────
if ! command -v cmux &>/dev/null; then
  echo "ERROR: cmux CLI not found. Add it to PATH:"
  echo "  sudo ln -sf \"/Applications/cmux.app/Contents/Resources/bin/cmux\" /usr/local/bin/cmux"
  exit 1
fi
SOCK="${CMUX_SOCKET_PATH:-/tmp/cmux.sock}"
if [[ ! -S "$SOCK" ]]; then
  echo "ERROR: cmux socket not found at $SOCK — is cmux running?"
  exit 1
fi
echo "✓ cmux socket: $SOCK"

# ── 2. Check / install beads ───────────────────────────────────────────────
if ! command -v bd &>/dev/null; then
  echo "▸ Beads (bd) not found. Installing..."
  curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash
  # Reload PATH in case install.sh put bd in a new location
  export PATH="$HOME/.local/bin:$HOME/bin:$PATH"
fi
if command -v bd &>/dev/null; then
  echo "✓ beads: $(bd --version 2>/dev/null || echo 'installed')"
else
  echo "⚠ beads install may have succeeded but bd not on PATH yet."
  echo "  Open a new shell or add ~/.local/bin to PATH, then re-run bootstrap.sh"
fi

# ── 3. Init .agent/ directory ─────────────────────────────────────────────
mkdir -p "$SCRIPT_DIR/.agent/inbox" \
         "$SCRIPT_DIR/.agent/context" \
         "$SCRIPT_DIR/.agent/state"

# Clear stale surface/workspace files from a previous session
rm -f "$SCRIPT_DIR/.agent/state/"*_surface \
      "$SCRIPT_DIR/.agent/state/"*_workspace
echo "✓ .agent/ directory ready"

# ── 4. Init / reset communications.md ─────────────────────────────────────
COMMS="$SCRIPT_DIR/.agent/communications.md"
TS_HUMAN=$(date "+%Y-%m-%d %H:%M:%S UTC")
cat > "$COMMS" << EOF
# Agent Communications Log

> Session started: $TS_HUMAN

All inter-agent messages, spawns, and escalations are appended here automatically
by \`scripts/msg.sh\` and \`scripts/spawn.sh\`.

Format: \`## [timestamp] sender → recipient (type)\`

Types: \`spawn\` | \`message\` | \`question\` | \`escalation\` | \`result\` | \`unblock\`

---

EOF
echo "✓ communications.md initialised"

# ── 5. Init Beads in this project ─────────────────────────────────────────
if command -v bd &>/dev/null; then
  cd "$WORKDIR"
  if [[ ! -d ".beads" ]]; then
    bd init 2>/dev/null && echo "✓ Beads initialised (.beads/)" || echo "⚠ bd init failed — check beads install"
  else
    echo "✓ Beads already initialised"
  fi
fi

# ── 6. Identify current surface ────────────────────────────────────────────
SF_JSON=$(cmux identify --json 2>/dev/null || echo "")
SF_ID=$(python3 -c "
import sys, json
raw = '''$SF_JSON'''
if not raw.strip():
    print('')
else:
    d = json.loads(raw)
    r = d.get('result', d)
    for key in ['surface_id', 'surface', 'pane_id']:
        v = r.get(key)
        if v:
            print(v)
            break
" 2>/dev/null || echo "")

if [[ -z "$SF_ID" ]]; then
  SF_ID="${CMUX_SURFACE_ID:-}"
fi
if [[ -n "$SF_ID" ]]; then
  echo "$SF_ID" > "$SCRIPT_DIR/.agent/state/manager_surface"
  echo "✓ Manager surface: $SF_ID"
else
  echo "⚠ Surface ID unknown. Run: cmux identify --json"
  echo "  Then: echo <surface_id> > .agent/state/manager_surface"
fi

# ── 7. Set manager CLAUDE.md ───────────────────────────────────────────────
cp "$SCRIPT_DIR/roles/manager.md" "$WORKDIR/CLAUDE.md"
echo "✓ CLAUDE.md set to manager role"

# ── 8. Start Mattermost watcher (if configured) ─────────────────────────────
MM_ENV="$SCRIPT_DIR/.agent/state/mattermost.env"
if [[ -f "$MM_ENV" ]]; then
  source "$MM_ENV"
  if [[ -n "${MM_BOT_TOKEN:-}" && "$MM_BOT_TOKEN" != "PASTE_TOKEN_HERE" ]]; then
    "$SCRIPT_DIR/scripts/mm-watch.sh" general tasks escalations > "$SCRIPT_DIR/.agent/state/mm-watch.log" 2>&1 &
    MM_WATCH_PID=$!
    echo "$MM_WATCH_PID" > "$SCRIPT_DIR/.agent/state/mm-watch.pid"
    echo "✓ Mattermost watcher started (PID $MM_WATCH_PID)"
  else
    echo "⚠ Mattermost configured but bot token missing — skipping watcher"
  fi
else
  echo "· Mattermost not configured — skipping watcher (run ./mattermost/setup.sh to enable)"
fi

# ── 9. Sidebar status ──────────────────────────────────────────────────────
export AGENT_ROLE="manager"
cmux set-status role "manager" 2>/dev/null || true
cmux log --level info "Manager session started" 2>/dev/null || true

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Ready. Launching Claude Code as manager..."
echo ""
echo 'First prompt: "I want to build [your product]. Spawn a PM and let'\''s brainstorm."'
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

cd "$WORKDIR"
exec claude
