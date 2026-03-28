#!/usr/bin/env bash
# up.sh — read config.yaml, create hub, spawn autostart agents
#
# Usage:
#   karen up                    # start everything with autostart: true
#   karen up --project <key>    # start only one project's agents
#   karen up --config <path>    # use specific config file

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# Parse args
CONFIG_FILE="${KAREN_CONFIG:-$HOME/.karen/config.yaml}"
FILTER_PROJECT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --project) FILTER_PROJECT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Config file not found: $CONFIG_FILE" >&2
  echo "" >&2
  echo "Create one at ~/.karen/config.yaml:" >&2
  echo "" >&2
  echo "  hub: ~/.karen/hub" >&2
  echo "  projects:" >&2
  echo "    myproject:" >&2
  echo "      dir: ~/Projects/myproject" >&2
  echo "      agents:" >&2
  echo "        manager: { role: manager, autostart: true }" >&2
  exit 1
fi

# Check PyYAML
if ! python3 -c "import yaml" 2>/dev/null; then
  echo "ERROR: PyYAML required. Install with: pip3 install pyyaml" >&2
  exit 1
fi

echo "╔══════════════════════════════════════════╗"
echo "║   karen up — starting agent system       ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# Parse YAML config and emit shell variables
eval "$(python3 -c "
import yaml, os, json, sys

config = yaml.safe_load(open(os.path.expanduser('$CONFIG_FILE')))
hub = os.path.expanduser(config.get('hub', '~/.karen/hub'))
scaffold = config.get('scaffold', 'auto')
if scaffold == 'auto':
    scaffold = '$ROOT'
else:
    scaffold = os.path.expanduser(scaffold)

print(f'HUB_DIR=\"{hub}\"')
print(f'SCAFFOLD_DIR=\"{scaffold}\"')

projects = config.get('projects', {})
print(f'PROJECT_KEYS=({\" \".join(projects.keys())})')

for pkey, pconf in projects.items():
    pdir = os.path.expanduser(pconf.get('dir', ''))
    knowledge = pconf.get('knowledge', [])
    knowledge_expanded = [os.path.expanduser(k) for k in knowledge]
    agents = pconf.get('agents', {})

    print(f'PROJECT_{pkey}_DIR=\"{pdir}\"')
    print(f'PROJECT_{pkey}_KNOWLEDGE=({\" \".join(json.dumps(k) for k in knowledge_expanded)})')

    agent_keys = []
    for akey, aconf in agents.items():
        if isinstance(aconf, dict):
            role = aconf.get('role', akey)
            autostart = aconf.get('autostart', False)
        else:
            role = akey
            autostart = False
        agent_keys.append(akey)
        print(f'AGENT_{pkey}_{akey}_ROLE=\"{role}\"')
        print(f'AGENT_{pkey}_{akey}_AUTOSTART={\"true\" if autostart else \"false\"}')

    print(f'PROJECT_{pkey}_AGENTS=({\" \".join(agent_keys)})')
")"

export KAREN_HUB_DIR="$HUB_DIR"
export AGENT_SCAFFOLD_ROOT="$SCAFFOLD_DIR"

echo "▸ Hub: $HUB_DIR"
echo "▸ Scaffold: $SCAFFOLD_DIR"
echo ""

# ── Create hub directory structure ────────────────────────────────────────────
mkdir -p "$HUB_DIR/inbox" "$HUB_DIR/state" "$HUB_DIR/memory" "$HUB_DIR/context" "$HUB_DIR/knowledge"

# Symlink scripts and hooks
ln -sfn "$SCAFFOLD_DIR/scripts" "$HUB_DIR/scripts"
ln -sfn "$SCAFFOLD_DIR/hooks" "$HUB_DIR/hooks"

# Initialize shared memory if missing
if [[ ! -f "$HUB_DIR/memory/shared.md" ]]; then
  echo "# Shared Agent Memory" > "$HUB_DIR/memory/shared.md"
  echo "" >> "$HUB_DIR/memory/shared.md"
  echo "Cross-project facts, decisions, and conventions." >> "$HUB_DIR/memory/shared.md"
fi

# Initialize communications log
TS_HUMAN=$(date "+%Y-%m-%d %H:%M:%S UTC")
cat > "$HUB_DIR/communications.md" << EOF
# Agent Communications Log
> Session started: $TS_HUMAN
> Hub: $HUB_DIR

| sender | → | recipient | type | format: markdown sections below |
|--------|---|-----------|------|--------------------------------|

---

EOF

echo "✓ Hub directories ready"

# ── Process each project ──────────────────────────────────────────────────────
SPAWNED=0

for PROJECT_KEY in "${PROJECT_KEYS[@]}"; do
  # Apply project filter if specified
  if [[ -n "$FILTER_PROJECT" && "$PROJECT_KEY" != "$FILTER_PROJECT" ]]; then
    continue
  fi

  # Get project config
  DIR_VAR="PROJECT_${PROJECT_KEY}_DIR"
  PROJECT_DIR="${!DIR_VAR}"
  KNOWLEDGE_VAR="PROJECT_${PROJECT_KEY}_KNOWLEDGE[@]"
  AGENTS_VAR="PROJECT_${PROJECT_KEY}_AGENTS[@]"

  if [[ ! -d "$PROJECT_DIR" ]]; then
    echo "⚠ Project $PROJECT_KEY: directory not found ($PROJECT_DIR) — skipping"
    continue
  fi

  echo ""
  echo "── Project: $PROJECT_KEY ($PROJECT_DIR) ──"

  # Create context subdir
  mkdir -p "$HUB_DIR/context/$PROJECT_KEY"

  # Link knowledge dirs
  mkdir -p "$HUB_DIR/knowledge/$PROJECT_KEY"
  for KDIR in "${!KNOWLEDGE_VAR}"; do
    if [[ -d "$KDIR" ]]; then
      LINK_NAME=$(basename "$KDIR")
      ln -sfn "$KDIR" "$HUB_DIR/knowledge/$PROJECT_KEY/$LINK_NAME"
      echo "  ✓ Knowledge linked: $LINK_NAME"
    fi
  done 2>/dev/null || true

  # Set up .claude/settings.json in project dir
  CLAUDE_DIR="$PROJECT_DIR/.claude"
  mkdir -p "$CLAUDE_DIR"
  SETTINGS_FILE="$CLAUDE_DIR/settings.json"

  # Write or merge settings
  if [[ ! -f "$SETTINGS_FILE" ]]; then
    python3 -c "
import json
settings = {
  'hooks': {
    'UserPromptSubmit': [{'matcher': '', 'hooks': [{'type': 'command', 'command': '$SCAFFOLD_DIR/hooks/check-inbox.sh'}]}],
    'Stop': [{'matcher': '', 'hooks': [
      {'type': 'command', 'command': '$SCAFFOLD_DIR/hooks/notify-done.sh'},
      {'type': 'command', 'command': '$SCAFFOLD_DIR/hooks/auto-shutdown.sh'}
    ]}]
  },
  'permissions': {
    'allow': [
      'Read', 'Edit', 'Write', 'Glob', 'Grep', 'NotebookEdit',
      'Bash(git status *)', 'Bash(git diff *)', 'Bash(git log *)', 'Bash(git show *)',
      'Bash(git branch *)', 'Bash(git blame *)', 'Bash(git stash *)',
      'Bash(git add *)', 'Bash(git commit *)', 'Bash(git checkout -- *)',
      'Bash(bd *)', 'Bash(cmux *)',
      'Bash($SCAFFOLD_DIR/scripts/*)', 'Bash(bash $SCAFFOLD_DIR/scripts/*)',
      'Bash(bash tests/*)',
      'Bash(karen *)',
      'Bash(npm run *)', 'Bash(npm test *)', 'Bash(npm install *)', 'Bash(npx *)',
      'Bash(node *)', 'Bash(python3 *)', 'Bash(pip3 install *)',
      'Bash(ls *)', 'Bash(cat *)', 'Bash(head *)', 'Bash(tail *)',
      'Bash(wc *)', 'Bash(sort *)', 'Bash(mkdir *)', 'Bash(cp *)', 'Bash(mv *)',
      'Bash(touch *)', 'Bash(chmod *)', 'Bash(which *)', 'Bash(echo *)',
      'Bash(date *)', 'Bash(curl *)', 'Bash(jq *)',
      'Bash(tsc *)', 'Bash(eslint *)', 'Bash(prettier *)'
    ],
    'deny': [
      'Bash(git push *)', 'Bash(git reset --hard *)', 'Bash(git clean *)',
      'Bash(git branch -D *)', 'Bash(git push --force *)',
      'Bash(rm -rf *)', 'Bash(sudo *)'
    ]
  }
}
print(json.dumps(settings, indent=2))
" > "$SETTINGS_FILE"
    echo "  ✓ .claude/settings.json created"
  else
    # Merge hooks with absolute paths into existing settings
    python3 -c "
import json
with open('$SETTINGS_FILE', 'r') as f:
    settings = json.load(f)

# Ensure hooks use absolute scaffold paths
hooks = settings.setdefault('hooks', {})
hooks['UserPromptSubmit'] = [{'matcher': '', 'hooks': [{'type': 'command', 'command': '$SCAFFOLD_DIR/hooks/check-inbox.sh'}]}]
hooks['Stop'] = [{'matcher': '', 'hooks': [
    {'type': 'command', 'command': '$SCAFFOLD_DIR/hooks/notify-done.sh'},
    {'type': 'command', 'command': '$SCAFFOLD_DIR/hooks/auto-shutdown.sh'}
]}]

# Ensure cmux and scaffold script permissions exist
perms = settings.setdefault('permissions', {}).setdefault('allow', [])
for rule in ['Bash(cmux *)', 'Bash($SCAFFOLD_DIR/scripts/*)', 'Bash(bash $SCAFFOLD_DIR/scripts/*)']:
    if rule not in perms:
        perms.append(rule)

with open('$SETTINGS_FILE', 'w') as f:
    json.dump(settings, f, indent=2)
" 2>/dev/null
    echo "  ✓ .claude/settings.json updated (hooks + permissions)"
  fi

  # ── Spawn autostart agents ───────────────────────────────────────────────
  for AGENT_KEY in "${!AGENTS_VAR}"; do
    ROLE_VAR="AGENT_${PROJECT_KEY}_${AGENT_KEY}_ROLE"
    AUTOSTART_VAR="AGENT_${PROJECT_KEY}_${AGENT_KEY}_AUTOSTART"
    ROLE="${!ROLE_VAR}"
    AUTOSTART="${!AUTOSTART_VAR}"

    AGENT_ID="${PROJECT_KEY}-${AGENT_KEY}"

    if [[ "$AUTOSTART" != "true" ]]; then
      echo "  · $AGENT_ID ($ROLE) — not autostart, skipping"
      continue
    fi

    # Export env vars for spawn.sh
    export KAREN_HUB_DIR="$HUB_DIR"
    export KAREN_PROJECT_KEY="$PROJECT_KEY"
    export KAREN_PROJECT_DIR="$PROJECT_DIR"
    export KAREN_AGENT_ID="$AGENT_ID"
    export AGENT_ROLE="$ROLE"

    echo "  ▸ Starting $AGENT_ID ($ROLE)..."
    "$SCAFFOLD_DIR/scripts/spawn.sh" "$AGENT_ID" "You are $AGENT_ID. Project: $PROJECT_KEY. Working dir: $PROJECT_DIR. Read your inbox and CLAUDE.md, then begin." "$PROJECT_DIR" 2>&1 | sed 's/^/    /'

    SPAWNED=$((SPAWNED + 1))
  done 2>/dev/null || true
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✓ Karen is up. $SPAWNED agent(s) started."
echo "  Hub: $HUB_DIR"
echo "  Health: $SCAFFOLD_DIR/scripts/health.sh"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
