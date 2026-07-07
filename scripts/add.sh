#!/usr/bin/env bash
# add.sh — Register the current (or given) directory as a Karen project
#
# Usage:
#   karen add                          # register $(pwd)
#   karen add --name myapp             # override project key
#   karen add --knowledge ./docs       # add knowledge dir(s)
#   karen add --no-init                # only update config, skip init
#   karen add /path/to/project         # explicit path

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

CONFIG_FILE="${KAREN_CONFIG:-$HOME/.karen/config.yaml}"
KNOWLEDGE_DIRS=()
PROJECT_DIR=""
PROJECT_KEY=""
SKIP_INIT=false
AUTOSTART=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name|-n)       PROJECT_KEY="$2"; shift 2 ;;
    --knowledge|-k)  KNOWLEDGE_DIRS+=("$(cd "$2" && pwd)"); shift 2 ;;
    --no-init)       SKIP_INIT=true; shift ;;
    --no-autostart)  AUTOSTART=false; shift ;;
    -*)              echo "Unknown option: $1"; exit 1 ;;
    *)               PROJECT_DIR="$1"; shift ;;
  esac
done

# Default to cwd
PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

# Derive key from dirname (lowercase, replace non-alphanum with -)
if [[ -z "$PROJECT_KEY" ]]; then
  PROJECT_KEY="$(basename "$PROJECT_DIR" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/-\+/-/g' | sed 's/^-//;s/-$//')"
fi

echo "▸ Karen: registering project"
echo "  Dir:  $PROJECT_DIR"
echo "  Key:  $PROJECT_KEY"
echo "  Config: $CONFIG_FILE"
echo ""

# ── Ensure config file exists ─────────────────────────────────────────────────
mkdir -p "$(dirname "$CONFIG_FILE")"

if [[ ! -f "$CONFIG_FILE" ]]; then
  cat > "$CONFIG_FILE" << 'EOF'
hub: ~/.karen/hub
projects: {}
EOF
  echo "  ✓ Created $CONFIG_FILE"
fi

# ── Upsert project into config.yaml ──────────────────────────────────────────
python3 - "$CONFIG_FILE" "$PROJECT_KEY" "$PROJECT_DIR" "$AUTOSTART" "${KNOWLEDGE_DIRS[@]+"${KNOWLEDGE_DIRS[@]}"}" << 'PYUPSERT'
import sys, yaml, os

config_file = sys.argv[1]
project_key = sys.argv[2]
project_dir = sys.argv[3]
autostart   = sys.argv[4] == "true"
knowledge   = sys.argv[5:] if len(sys.argv) > 5 else []

with open(config_file, 'r') as f:
    config = yaml.safe_load(f) or {}

config.setdefault('hub', '~/.karen/hub')
projects = config.setdefault('projects', {})

# Tilde-ify the project dir for portability
home = os.path.expanduser('~')
display_dir = '~' + project_dir[len(home):] if project_dir.startswith(home) else project_dir

existed = project_key in projects
proj = projects.setdefault(project_key, {})
proj['dir'] = display_dir

if knowledge:
    proj['knowledge'] = ['~' + k[len(home):] if k.startswith(home) else k for k in knowledge]

proj.setdefault('agents', {})['manager'] = {'role': 'manager', 'autostart': autostart}

with open(config_file, 'w') as f:
    yaml.dump(config, f, default_flow_style=False, allow_unicode=True, sort_keys=False)

verb = "Updated" if existed else "Added"
print(f"  ✓ {verb} project '{project_key}' in config")
PYUPSERT

# ── Run init unless skipped ────────────────────────────────────────────────────
if [[ "$SKIP_INIT" == "false" ]]; then
  echo ""
  echo "▸ Running init for $PROJECT_DIR"
  KNOWLEDGE_ARGS=()
  for k in "${KNOWLEDGE_DIRS[@]+"${KNOWLEDGE_DIRS[@]}"}"; do
    KNOWLEDGE_ARGS+=(--knowledge "$k")
  done
  "$ROOT/init.sh" "$PROJECT_DIR" "${KNOWLEDGE_ARGS[@]+"${KNOWLEDGE_ARGS[@]}"}"
fi

echo ""
echo "══════════════════════════════════════════"
echo "  ✓ Project '$PROJECT_KEY' is ready."
echo ""
echo "  Start agents:   karen up --project $PROJECT_KEY"
echo "  Check config:   karen config projects"
echo "══════════════════════════════════════════"
