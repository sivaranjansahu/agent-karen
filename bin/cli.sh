#!/usr/bin/env bash
# karen — "I want to talk to the manager."
#
# Usage:
#   karen init /path/to/project [--knowledge /path/to/docs]
#   karen start /path/to/project
#   karen spawn <role> "<context>" [working_dir]
#   karen msg <role> "<message>" [type]
#   karen health
#   karen shutdown <role|--all|--idle [mins]>
#   karen status

set -euo pipefail

# Resolve the scaffold root (where this package is installed)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AGENT_SCAFFOLD_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$AGENT_SCAFFOLD_ROOT"

CMD="${1:-help}"
shift || true

case "$CMD" in
  init)
    exec "$ROOT/init.sh" "$@"
    ;;
  start|bootstrap)
    exec "$ROOT/bootstrap.sh" "$@"
    ;;
  spawn)
    exec "$ROOT/scripts/spawn.sh" "$@"
    ;;
  msg|message|send)
    exec "$ROOT/scripts/msg.sh" "$@"
    ;;
  health|check)
    exec "$ROOT/scripts/health.sh" "$@"
    ;;
  shutdown|kill)
    exec "$ROOT/scripts/shutdown.sh" "$@"
    ;;
  status)
    exec "$ROOT/scripts/status.sh" "$@"
    ;;
  help|--help|-h)
    cat <<'HELP'
agent-karen — "I want to talk to the manager."

Multi-agent coordination for Claude Code. Spawn a team of AI agents.
Talk to the manager. It runs the team.

Usage:
  karen init <project> [--knowledge <dir>]   Initialize for a project
  karen start <project>                      Start the manager agent
  karen spawn <role> "<context>" [dir]       Spawn an agent
  karen msg <role> "<message>" [type]        Send a message to an agent
  karen health                              Check all agents are alive
  karen shutdown <role|--all|--idle N>       Shut down agents
  karen status                              Show agent overview

Examples:
  karen init ~/projects/my-app --knowledge ~/projects/my-app/docs
  karen start ~/projects/my-app
  karen spawn pm "Build an invoicing SaaS. MVP only."
  karen msg lead "Brief is ready at .agent/context/brief.md" result
  karen health
  karen shutdown --idle 10

Backends (auto-detected):
  cmux     Best experience — named tabs, status bar, notifications
  tmux     Universal — works on macOS, Linux, WSL
  terminal Plain terminal tabs (macOS only, no push messaging)

Learn more: https://github.com/sivaranjansahu/agent-karen
HELP
    ;;
  *)
    echo "Unknown command: $CMD"
    echo "Run 'karen help' for usage."
    exit 1
    ;;
esac
