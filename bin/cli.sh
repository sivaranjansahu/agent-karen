#!/usr/bin/env bash
# karen — "I want to talk to the manager."
#
# Usage:
#   karen up [--project <key>]                   Start agents from config.yaml
#   karen config {show|projects|agents}           Inspect configuration
#   karen init <project> [--knowledge <dir>]      Initialize a project
#   karen start <project>                         Start the manager agent
#   karen spawn <agent_id> "<context>" [dir]      Spawn an agent
#   karen msg <target> "<message>" [type]         Send a message
#   karen health [--project <key>]                Check agent health
#   karen shutdown <agent|--all|--project <key>>  Shut down agents

set -euo pipefail

# Resolve the scaffold root (follow symlinks to find real package location)
SOURCE="${BASH_SOURCE[0]}"
while [[ -L "$SOURCE" ]]; do
  DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ "$SOURCE" != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
export AGENT_SCAFFOLD_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT="$AGENT_SCAFFOLD_ROOT"

CMD="${1:-help}"
shift || true

case "$CMD" in
  up)
    exec "$ROOT/scripts/up.sh" "$@"
    ;;
  config)
    exec "$ROOT/scripts/config.sh" "$@"
    ;;
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

Multi-agent coordination for Claude Code. Define your team in config.yaml,
run `karen up`, and talk to the manager.

Usage:
  karen up [--project <key>]                 Start agents from ~/.karen/config.yaml
  karen config {show|projects|agents}        Inspect configuration
  karen init <project> [--knowledge <dir>]   Initialize a single project
  karen start <project>                      Start the manager agent
  karen spawn <agent_id> "<context>" [dir]   Spawn an agent
  karen msg <target> "<message>" [type]      Send a message to an agent
  karen health [--project <key>]             Check agent health
  karen shutdown <id|--all|--project <key>>  Shut down agents

Config file: ~/.karen/config.yaml

  hub: ~/.karen/hub
  projects:
    myproject:
      dir: ~/Projects/myproject
      knowledge:
        - ~/Projects/myproject/docs
      agents:
        manager: { role: manager, autostart: true }
        lead: { role: lead }
        dev1: { role: dev }

Examples:
  karen up                                   # start all autostart agents
  karen up --project myproject               # start one project only
  karen config agents                        # list all defined agents
  karen spawn myproject-dev2 "Build auth"    # spawn specific agent
  karen msg dev1 "Brief is ready" result     # message within project
  karen msg other-manager "Need API" message # cross-project message
  karen health                               # check all agents
  karen shutdown --all                       # stop everything

Backends (auto-detected): cmux, tmux, terminal (macOS)

Learn more: https://github.com/sivaranjansahu/agent-karen
HELP
    ;;
  *)
    echo "Unknown command: $CMD"
    echo "Run 'karen help' for usage."
    exit 1
    ;;
esac
