#!/usr/bin/env bash
# mux.sh — Terminal multiplexer abstraction layer
#
# Supports three backends: cmux, tmux, plain terminal (macOS)
# Auto-detects the best available backend.
#
# Usage: source this file, then call mux_* functions.
#
#   source "$AGENT_SCAFFOLD_ROOT/lib/mux.sh"
#   mux_spawn "pm" "cd /project && claude 'hello'"
#   mux_send "pm" "check your inbox"
#   mux_list
#   mux_close "pm"

set -euo pipefail

_MUX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MUX_ROOT="$(cd "$_MUX_DIR/.." && pwd)"
# State lives in the project's .agent/ dir, resolved from pwd
STATE="$(pwd)/.agent/state"

# ── Backend detection ─────────────────────────────────────────────────────────

_detect_backend() {
  if [[ -n "${AGENT_MUX_BACKEND:-}" ]]; then
    echo "$AGENT_MUX_BACKEND"
    return
  fi
  if command -v cmux &>/dev/null && cmux ping &>/dev/null 2>&1; then
    echo "cmux"
  elif command -v tmux &>/dev/null && tmux has-session 2>/dev/null; then
    echo "tmux"
  elif command -v tmux &>/dev/null; then
    # tmux available but no session — start one
    echo "tmux"
  elif [[ "$(uname)" == "Darwin" ]]; then
    echo "terminal"
  else
    echo "none"
  fi
}

MUX_BACKEND="$(_detect_backend)"

# ── cmux backend ──────────────────────────────────────────────────────────────

_cmux_spawn() {
  local NAME="$1" CMD="$2" WORKDIR="${3:-$(pwd)}"
  local WS_OUTPUT WS_ID SF_OUTPUT SF_ID

  WS_OUTPUT=$(cmux new-workspace --cwd "$WORKDIR" 2>&1) || return 1
  WS_ID=$(echo "$WS_OUTPUT" | grep -oE 'workspace:[0-9]+')
  [[ -z "$WS_ID" ]] && return 1

  cmux rename-workspace --workspace "$WS_ID" "$NAME"
  sleep 0.5

  SF_OUTPUT=$(cmux list-pane-surfaces --workspace "$WS_ID" 2>&1) || return 1
  SF_ID=$(echo "$SF_OUTPUT" | grep -oE 'surface:[0-9]+' | head -1)

  echo "$WS_ID" > "$STATE/${NAME}_workspace"
  echo "$SF_ID" > "$STATE/${NAME}_surface"

  cmux send --workspace "$WS_ID" "${CMD}"$'\n'
  cmux notify --title "Agent spawned" --body "$NAME is online" 2>/dev/null || true

  echo "$WS_ID $SF_ID"
}

_cmux_send() {
  local NAME="$1" TEXT="$2"
  local WS_FILE="$STATE/${NAME}_workspace"
  [[ -f "$WS_FILE" ]] || return 1
  local WS_ID=$(cat "$WS_FILE")
  cmux send --workspace "$WS_ID" "${TEXT}"$'\n' 2>/dev/null
}

_cmux_list() {
  cmux list-workspaces 2>/dev/null
}

_cmux_close() {
  local NAME="$1"
  local WS_FILE="$STATE/${NAME}_workspace"
  [[ -f "$WS_FILE" ]] || return 1
  local WS_ID=$(cat "$WS_FILE")
  cmux close-workspace --workspace "$WS_ID" 2>/dev/null || true
  rm -f "$WS_FILE" "$STATE/${NAME}_surface"
}

_cmux_rename() {
  local NAME="$1" NEW_NAME="$2"
  local WS_FILE="$STATE/${NAME}_workspace"
  [[ -f "$WS_FILE" ]] || return 1
  local WS_ID=$(cat "$WS_FILE")
  cmux rename-workspace --workspace "$WS_ID" "$NEW_NAME" 2>/dev/null
}

_cmux_notify() {
  local TITLE="$1" BODY="$2"
  cmux notify --title "$TITLE" --body "$BODY" 2>/dev/null || true
}

# ── tmux backend ──────────────────────────────────────────────────────────────

_ensure_tmux_session() {
  if ! tmux has-session -t agents 2>/dev/null; then
    tmux new-session -d -s agents -n orchestrator
  fi
}

_tmux_spawn() {
  local NAME="$1" CMD="$2" WORKDIR="${3:-$(pwd)}"
  _ensure_tmux_session

  tmux new-window -t agents -n "$NAME" -c "$WORKDIR"
  sleep 0.3
  tmux send-keys -t "agents:$NAME" "$CMD" Enter

  # Store window index for tracking
  local WIN_IDX
  WIN_IDX=$(tmux list-windows -t agents -F '#{window_name} #{window_index}' | grep "^${NAME} " | awk '{print $2}')
  echo "$WIN_IDX" > "$STATE/${NAME}_workspace"
  echo "tmux:agents:$NAME" > "$STATE/${NAME}_surface"

  echo "agents:$NAME $WIN_IDX"
}

_tmux_send() {
  local NAME="$1" TEXT="$2"
  _ensure_tmux_session
  tmux send-keys -t "agents:$NAME" "$TEXT" Enter 2>/dev/null
}

_tmux_list() {
  _ensure_tmux_session
  tmux list-windows -t agents -F '  #{window_name}  #{window_index}  #{?window_active,* ,  }' 2>/dev/null
}

_tmux_close() {
  local NAME="$1"
  tmux kill-window -t "agents:$NAME" 2>/dev/null || true
  rm -f "$STATE/${NAME}_workspace" "$STATE/${NAME}_surface"
}

_tmux_rename() {
  local NAME="$1" NEW_NAME="$2"
  tmux rename-window -t "agents:$NAME" "$NEW_NAME" 2>/dev/null
}

_tmux_notify() {
  local TITLE="$1" BODY="$2"
  # Use terminal-notifier on macOS, notify-send on Linux
  if command -v terminal-notifier &>/dev/null; then
    terminal-notifier -title "$TITLE" -message "$BODY" 2>/dev/null || true
  elif command -v notify-send &>/dev/null; then
    notify-send "$TITLE" "$BODY" 2>/dev/null || true
  fi
}

# ── Plain terminal backend (macOS) ────────────────────────────────────────────

_terminal_spawn() {
  local NAME="$1" CMD="$2" WORKDIR="${3:-$(pwd)}"

  # Detect terminal app
  local TERM_APP="Terminal"
  if [[ "$TERM_PROGRAM" == "iTerm.app" ]] || pgrep -q iTerm2; then
    TERM_APP="iTerm"
  fi

  if [[ "$TERM_APP" == "iTerm" ]]; then
    osascript <<APPLESCRIPT
tell application "iTerm2"
  tell current window
    create tab with default profile
    tell current session of current tab
      write text "cd \"$WORKDIR\" && $CMD"
    end tell
  end tell
end tell
APPLESCRIPT
  else
    osascript -e "tell application \"Terminal\" to do script \"cd \\\"$WORKDIR\\\" && $CMD\""
  fi

  # Track by PID of the claude process (best effort)
  sleep 1
  local PID
  PID=$(pgrep -f "claude.*$NAME" | tail -1 || echo "unknown")
  echo "$PID" > "$STATE/${NAME}_workspace"
  echo "terminal:$NAME" > "$STATE/${NAME}_surface"

  echo "terminal:$NAME $PID"
}

_terminal_send() {
  local NAME="$1" TEXT="$2"
  # Plain terminals don't support programmatic text injection.
  # Agent will pick up messages via inbox polling (Stop hook).
  echo "  ⚠ Plain terminal mode: message queued in inbox (no push delivery)"
}

_terminal_list() {
  echo "  Plain terminal mode — check your terminal tabs manually"
  for ws_file in "$STATE"/*_workspace; do
    [[ -f "$ws_file" ]] || continue
    local ROLE=$(basename "$ws_file" _workspace)
    local ID=$(cat "$ws_file")
    echo "  $ROLE  (pid: $ID)"
  done
}

_terminal_close() {
  local NAME="$1"
  local WS_FILE="$STATE/${NAME}_workspace"
  if [[ -f "$WS_FILE" ]]; then
    local PID=$(cat "$WS_FILE")
    if [[ "$PID" != "unknown" ]] && kill -0 "$PID" 2>/dev/null; then
      kill "$PID" 2>/dev/null || true
    fi
  fi
  rm -f "$WS_FILE" "$STATE/${NAME}_surface"
}

_terminal_rename() {
  # No-op for plain terminals
  true
}

_terminal_notify() {
  local TITLE="$1" BODY="$2"
  osascript -e "display notification \"$BODY\" with title \"$TITLE\"" 2>/dev/null || true
}

# ── Public API ────────────────────────────────────────────────────────────────

mux_backend() {
  echo "$MUX_BACKEND"
}

mux_spawn() {
  local NAME="$1" CMD="$2" WORKDIR="${3:-$(pwd)}"
  case "$MUX_BACKEND" in
    cmux)     _cmux_spawn "$NAME" "$CMD" "$WORKDIR" ;;
    tmux)     _tmux_spawn "$NAME" "$CMD" "$WORKDIR" ;;
    terminal) _terminal_spawn "$NAME" "$CMD" "$WORKDIR" ;;
    *)        echo "ERROR: No supported terminal multiplexer found. Install tmux or cmux." >&2; return 1 ;;
  esac
}

mux_send() {
  local NAME="$1" TEXT="$2"
  case "$MUX_BACKEND" in
    cmux)     _cmux_send "$NAME" "$TEXT" ;;
    tmux)     _tmux_send "$NAME" "$TEXT" ;;
    terminal) _terminal_send "$NAME" "$TEXT" ;;
    *)        return 1 ;;
  esac
}

mux_list() {
  case "$MUX_BACKEND" in
    cmux)     _cmux_list ;;
    tmux)     _tmux_list ;;
    terminal) _terminal_list ;;
    *)        echo "No multiplexer available" ;;
  esac
}

mux_close() {
  local NAME="$1"
  case "$MUX_BACKEND" in
    cmux)     _cmux_close "$NAME" ;;
    tmux)     _tmux_close "$NAME" ;;
    terminal) _terminal_close "$NAME" ;;
    *)        return 1 ;;
  esac
}

mux_rename() {
  local NAME="$1" NEW_NAME="$2"
  case "$MUX_BACKEND" in
    cmux)     _cmux_rename "$NAME" "$NEW_NAME" ;;
    tmux)     _tmux_rename "$NAME" "$NEW_NAME" ;;
    terminal) _terminal_rename "$NAME" "$NEW_NAME" ;;
    *)        return 1 ;;
  esac
}

mux_notify() {
  local TITLE="$1" BODY="$2"
  case "$MUX_BACKEND" in
    cmux)     _cmux_notify "$TITLE" "$BODY" ;;
    tmux)     _tmux_notify "$TITLE" "$BODY" ;;
    terminal) _terminal_notify "$TITLE" "$BODY" ;;
    *)        true ;;
  esac
}
