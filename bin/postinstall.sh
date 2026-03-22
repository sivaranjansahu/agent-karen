#!/usr/bin/env bash
# postinstall.sh — runs after npm install, checks for terminal multiplexer

# Don't fail the install if this script errors
set +e

echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║   agent-karen installed successfully      ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

# Check for multiplexer
HAS_CMUX=false
HAS_TMUX=false
command -v cmux &>/dev/null && HAS_CMUX=true
command -v tmux &>/dev/null && HAS_TMUX=true

if $HAS_CMUX; then
  echo "  ✓ cmux detected — best experience, visual agent tabs"
elif $HAS_TMUX; then
  echo "  ✓ tmux detected"
  echo ""
  echo "  For the best experience (visual tabs, notifications, status bar):"
  if [[ "$(uname)" == "Darwin" ]]; then
    echo "    brew install --cask cmux    # https://cmux.com"
  else
    echo "    cmux is macOS only — tmux works fine for Linux/WSL"
  fi
else
  echo "  ⚠ No terminal multiplexer found. You need one to run agents."
  echo ""
  if [[ "$(uname)" == "Darwin" ]]; then
    echo "  Recommended (visual tabs, click to switch between agents):"
    echo "    brew install --cask cmux    # https://cmux.com"
    echo ""
    echo "  Or universal (keyboard-driven, Ctrl-b to switch):"
    echo "    brew install tmux"
  else
    echo "  Install tmux:"
    echo "    sudo apt install tmux       # Debian/Ubuntu"
    echo "    brew install tmux           # macOS"
  fi
fi

echo ""
echo "  Get started:"
echo "    karen init /path/to/your/project"
echo "    karen start /path/to/your/project"
echo ""
