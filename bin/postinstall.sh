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
  echo "  ✓ cmux detected — visual tabs, notifications, the works."
  echo "    Karen approves."
elif $HAS_TMUX; then
  echo "  ✓ tmux detected — it'll work, but Karen's not impressed."
  echo ""
  echo "    tmux hides your agents in background windows."
  echo "    cmux gives you visual tabs — see all your agents at once."
  echo ""
  if [[ "$(uname)" == "Darwin" ]]; then
    echo "    Upgrade your experience:"
    echo "      brew install --cask cmux    # https://cmux.com"
  else
    echo "    cmux is macOS only — tmux is your best option on Linux/WSL."
    echo "    Karen will make it work."
  fi
else
  echo ""
  echo "  ┌─────────────────────────────────────────────────────────┐"
  echo "  │                                                         │"
  echo "  │   Karen needs a terminal multiplexer to manage agents.  │"
  echo "  │                                                         │"
  echo "  │   Without one, she can't spawn anyone. And she WILL     │"
  echo "  │   complain about it.                                    │"
  echo "  │                                                         │"
  echo "  │   Pick one:                                             │"
  echo "  │                                                         │"
  if [[ "$(uname)" == "Darwin" ]]; then
    echo "  │   RECOMMENDED (visual tabs, click to switch agents):   │"
    echo "  │     brew install --cask cmux                           │"
    echo "  │                                                        │"
    echo "  │   ALSO WORKS (keyboard-driven, Ctrl-b to switch):      │"
    echo "  │     brew install tmux                                  │"
  else
    echo "  │   INSTALL:                                             │"
    echo "  │     sudo apt install tmux       # Debian/Ubuntu        │"
    echo "  │     brew install tmux           # macOS                │"
  fi
  echo "  │                                                         │"
  echo "  │   Then come back. Karen will be waiting.                │"
  echo "  │                                                         │"
  echo "  └─────────────────────────────────────────────────────────┘"
fi

echo ""
echo "  Get started:"
echo "    karen init /path/to/your/project"
echo "    karen start /path/to/your/project"
echo ""
