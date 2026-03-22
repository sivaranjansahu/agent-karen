#!/usr/bin/env bash
# bootstrap.sh — start the manager session in the current cmux workspace
#
# Run this ONCE to kick off the entire system.
# Usage: ./bootstrap.sh [working_dir]

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

# Build claude flags
CLAUDE_FLAGS=""
if $SKIP_PERMS; then
  CLAUDE_FLAGS="--dangerously-skip-permissions"
fi

# Permission mode stored after .agent/ dirs are created (see below)

WORKDIR="${ARGS[0]:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "╔══════════════════════════════════════════╗"
echo "║   agent-karen — talk to the manager      ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── 1. Check terminal multiplexer ─────────────────────────────────────────
source "$SCRIPT_DIR/lib/mux.sh"
BACKEND=$(mux_backend)
if [[ "$BACKEND" == "none" ]]; then
  echo "ERROR: No supported terminal found."
  echo ""
  echo "  Options:"
  echo "    1. Install tmux:  brew install tmux  (then run this from inside tmux)"
  echo "    2. Install cmux:  https://cmux.com   (then run this from inside cmux)"
  echo ""
  echo "  Quick start with tmux:"
  echo "    tmux new-session -s agents"
  echo "    karen start $WORKDIR"
  exit 1
fi
if [[ "$BACKEND" == "terminal" ]]; then
  echo "⚠ Running in plain terminal mode (iTerm/Terminal.app)"
  echo "  Agents will open in new tabs. For best experience, use tmux or cmux."
  echo ""
fi
echo "✓ Backend: $BACKEND"

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
mkdir -p "$WORKDIR/.agent/inbox" \
         "$WORKDIR/.agent/context" \
         "$WORKDIR/.agent/state"

# Clear stale surface/workspace files from a previous session
rm -f "$WORKDIR/.agent/state/"*_surface \
      "$WORKDIR/.agent/state/"*_workspace
echo "✓ .agent/ directory ready"

# Store permission mode so spawned agents inherit it
echo "$SKIP_PERMS" > "$WORKDIR/.agent/state/skip_permissions"

# ── 4. Init / reset communications.md ─────────────────────────────────────
COMMS="$WORKDIR/.agent/communications.md"
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
  echo "$SF_ID" > "$WORKDIR/.agent/state/manager_surface"
  echo "✓ Manager surface: $SF_ID"
else
  echo "⚠ Surface ID unknown. Run: cmux identify --json"
  echo "  Then: echo <surface_id> > .agent/state/manager_surface"
fi

# Store manager workspace so msg.sh can wake the manager terminal
# For cmux: extract workspace from the identify JSON or list-workspaces
# For tmux: the manager runs in the current window
WS_ID=""
if [[ "$BACKEND" == "cmux" ]]; then
  WS_ID=$(python3 -c "
import json
raw = '''$SF_JSON'''
if raw.strip():
    d = json.loads(raw)
    r = d.get('result', d)
    for key in ['workspace_id', 'workspace']:
        v = r.get(key)
        if v:
            print(v)
            break
" 2>/dev/null || echo "")
  if [[ -z "$WS_ID" ]]; then
    # Fallback: get the currently selected workspace
    WS_ID=$(cmux list-workspaces 2>/dev/null | grep '\[selected\]' | grep -oE 'workspace:[0-9]+' || echo "")
  fi
elif [[ "$BACKEND" == "tmux" ]]; then
  WS_ID="agents:manager"
fi

if [[ -n "$WS_ID" ]]; then
  echo "$WS_ID" > "$WORKDIR/.agent/state/manager_workspace"
  echo "✓ Manager workspace: $WS_ID"
fi

# ── 7. Set manager CLAUDE.md ───────────────────────────────────────────────
cp "$SCRIPT_DIR/roles/manager.md" "$WORKDIR/CLAUDE.md"
echo "✓ CLAUDE.md set to manager role"

# ── 8. Start Mattermost watcher (if configured) ─────────────────────────────
MM_ENV="$WORKDIR/.agent/state/mattermost.env"
if [[ -f "$MM_ENV" ]]; then
  source "$MM_ENV"
  if [[ -n "${MM_BOT_TOKEN:-}" && "$MM_BOT_TOKEN" != "PASTE_TOKEN_HERE" ]]; then
    "$SCRIPT_DIR/scripts/mm-watch.sh" general tasks escalations > "$WORKDIR/.agent/state/mm-watch.log" 2>&1 &
    MM_WATCH_PID=$!
    echo "$MM_WATCH_PID" > "$WORKDIR/.agent/state/mm-watch.pid"
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
exec claude $CLAUDE_FLAGS
