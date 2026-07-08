#!/usr/bin/env bash
# bootstrap.sh — start the manager session in the current cmux workspace
#
# Run this ONCE to kick off the entire system.
# Usage: ./bootstrap.sh [--runtime <claude|pi>] [working_dir]

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

WORKDIR="${1:-$(pwd)}"
WORKDIR="$(cd "$WORKDIR" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "╔══════════════════════════════════════════╗"
echo "║   agent-karen — talk to the manager      ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── 0. Auto-register project if not in config ─────────────────────────────
CONFIG_FILE="${KAREN_CONFIG:-$HOME/.karen/config.yaml}"
PROJECT_KEY="$(basename "$WORKDIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\+/-/g' | sed 's/^-//;s/-$//')"

ALREADY_REGISTERED=false
if [[ -f "$CONFIG_FILE" ]]; then
  if python3 -c "
import yaml, os, sys
config = yaml.safe_load(open(os.path.expanduser('$CONFIG_FILE'))) or {}
sys.exit(0 if '$PROJECT_KEY' in config.get('projects', {}) else 1)
" 2>/dev/null; then
    ALREADY_REGISTERED=true
  fi
fi

if [[ "$ALREADY_REGISTERED" == "false" ]]; then
  echo "▸ Project '$PROJECT_KEY' not in config — registering..."
  "$SCRIPT_DIR/scripts/add.sh" "$WORKDIR"
  echo ""
fi

# Runtime selection (manager tier-1). Precedence: --runtime arg / SPAWN_RUNTIME
# env (spawn-time, always wins) > config.yaml project runtime (default) >
# "claude" (global default). Mirrors spawn.sh's agent-level seam.
CONFIG_RUNTIME=""
if [[ -f "$CONFIG_FILE" ]]; then
  CONFIG_RUNTIME=$(python3 -c "
import yaml, os
config = yaml.safe_load(open(os.path.expanduser('$CONFIG_FILE'))) or {}
proj = (config.get('projects') or {}).get('$PROJECT_KEY') or {}
print(proj.get('runtime') or '', end='')
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

# Ensure symlinks to scaffold scripts and hooks exist
ln -sfn "$SCRIPT_DIR/scripts" "$WORKDIR/.agent/scripts"
ln -sfn "$SCRIPT_DIR/hooks" "$WORKDIR/.agent/hooks"
echo "✓ .agent/scripts and .agent/hooks linked"

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
# BEADS_ROOT is exported so it's visible to `claude` below and to every agent
# this manager spawns (spawn.sh exports the same convention) — same project
# working dir, one shared task DB for the whole team.
export BEADS_ROOT="$WORKDIR"
if command -v bd &>/dev/null; then
  cd "$WORKDIR"
  if [[ ! -d ".beads" ]]; then
    bd init </dev/null 2>/dev/null && echo "✓ Beads initialised (.beads/)" || echo "⚠ bd init failed — check beads install"
  else
    echo "✓ Beads already initialised"
  fi
  bd quickstart 2>/dev/null || true
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

# ── 8. Start heartbeat daemon ─────────────────────────────────────────────
export KAREN_HUB_DIR="$WORKDIR/.agent"
if [[ "${KAREN_HEARTBEAT:-on}" == "off" ]]; then
  echo "⚠ Heartbeat disabled (KAREN_HEARTBEAT=off)"
else
  # The daemon owns its own pidfile (per-hub singleton). Do NOT write the pidfile
  # here: bootstrap runs on EVERY agent spawn, so N concurrent boots would race —
  # the singleton makes the 2nd..Nth refuse, but writing their dead pids here
  # would corrupt the live daemon's entry (root cause of the 102-daemon leak).
  "$SCRIPT_DIR/scripts/heartbeat.sh" loop 20 > "$WORKDIR/.agent/state/heartbeat.log" 2>&1 &
  echo "✓ Heartbeat daemon started (every 20s)"
fi

# ── 9. Sidebar status ──────────────────────────────────────────────────────
export AGENT_ROLE="manager"
cmux set-status role "manager" 2>/dev/null || true
cmux log --level info "Manager session started" 2>/dev/null || true

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Ready. Launching $EFFECTIVE_RUNTIME as manager..."
echo ""
echo 'First prompt: "I want to build [your product]. Spawn a PM and let'\''s brainstorm."'
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

cd "$WORKDIR"
# claude path is byte-for-byte identical to before this feature existed; pi
# is strictly opt-in. No initial prompt either way — the human types the
# first message (see "First prompt" hint above).
if [[ "$EFFECTIVE_RUNTIME" == "pi" ]]; then
  exec pi --tools bash,read,write,edit
else
  exec claude --dangerously-skip-permissions
fi
