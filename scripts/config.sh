#!/usr/bin/env bash
# config.sh — inspect karen configuration
#
# Usage:
#   karen config show       # dump parsed config
#   karen config projects   # list projects
#   karen config agents     # list all agents

set -euo pipefail

CONFIG_FILE="${KAREN_CONFIG:-$HOME/.karen/config.yaml}"
SUBCMD="${1:-show}"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "No config found at: $CONFIG_FILE"
  echo "Create one with 'karen init-config' or manually."
  exit 1
fi

case "$SUBCMD" in
  show)
    cat "$CONFIG_FILE"
    ;;
  projects)
    python3 -c "
import yaml, os
config = yaml.safe_load(open(os.path.expanduser('$CONFIG_FILE')))
for pkey, pconf in config.get('projects', {}).items():
    pdir = os.path.expanduser(pconf.get('dir', '?'))
    agents = len(pconf.get('agents', {}))
    print(f'  {pkey:20s} {pdir:40s} ({agents} agents)')
"
    ;;
  agents)
    python3 -c "
import yaml, os
config = yaml.safe_load(open(os.path.expanduser('$CONFIG_FILE')))
for pkey, pconf in config.get('projects', {}).items():
    for akey, aconf in pconf.get('agents', {}).items():
        if isinstance(aconf, dict):
            role = aconf.get('role', akey)
            auto = '✓' if aconf.get('autostart', False) else '·'
        else:
            role = akey
            auto = '·'
        agent_id = f'{pkey}-{akey}'
        print(f'  {auto} {agent_id:25s} role={role:12s} project={pkey}')
"
    ;;
  *)
    echo "Usage: karen config {show|projects|agents}"
    exit 1
    ;;
esac
