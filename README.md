# agent-karen

<img width="437" height="493" alt="image" src="https://github.com/user-attachments/assets/0511a49e-d551-4e06-a680-937f4250a413" />

*keeping your agents on a short leash since 2025.*

Will escalate to the manager. Will file a ticket for it, and keep spawning and killing agents until it is closed. Karen don't quit.

---

**Multi-agent coordination for Claude Code.** Spawn a team of autonomous AI agents — PM, Dev Lead, developers, QA, CMO, or any custom role — that work in parallel, each in their own terminal workspace. You talk to the manager. It runs the team.

No orchestration server. No custom SDK. Shell scripts, JSONL inboxes, and markdown files.

---

## How it works

```
You (human)
  └─ Manager agent        <- you talk to this one
       ├─ PM agent         <- writes the product brief
       ├─ Dev Lead agent   <- breaks tasks, spawns devs
       │    ├─ Dev 1
       │    ├─ Dev 2
       │    └─ Dev N
       └─ QA agent         <- validates dev output
```

Each agent gets:
- A **role definition** (markdown file = `CLAUDE.md`)
- A **private inbox** (`~/.karen/hub/inbox/<agent-id>.jsonl`)
- **Persistent task memory** via [Beads](https://github.com/steveyegge/beads)
- Access to **shared context** and **knowledge bases**

Every message and spawn is logged to `~/.karen/hub/communications.md` — a full audit trail.

---

## Architecture: Central Hub

All agent state lives in a single hub directory (`~/.karen/hub/`), not scattered across projects:

```
~/.karen/
  config.yaml                       # declare your projects + agents
  hub/
    inbox/
      myproject-manager.jsonl       # agent ID = project-role
      myproject-dev1.jsonl
      other-manager.jsonl           # multi-project support
    state/                          # workspace IDs, cursors
    memory/
      shared.md                     # global shared memory
      myproject-manager.md          # per-agent persistent memory
    context/
      myproject/brief.md            # per-project context
    knowledge/
      myproject/docs -> ~/proj/docs # symlinked knowledge bases
    communications.md               # single global audit log
```

Agents in different projects can message each other. Short names work within a project (`msg.sh dev1 "hello"` auto-resolves to `myproject-dev1`). Full IDs work cross-project (`msg.sh other-manager "need your API spec"`).

---

## Prerequisites

- [Claude Code](https://claude.ai/code) (`npm install -g @anthropic-ai/claude-code`)
- A terminal multiplexer (see below)
- Node.js >= 16
- Python 3 + PyYAML (`pip3 install pyyaml`)

### Terminal backend: cmux vs tmux

| | [cmux](https://cmux.com) | [tmux](https://github.com/tmux/tmux) |
|---|---|---|
| **Visual** | Each agent gets a **visible tab** (`project:role` labels) | Agents run in **hidden windows** |
| **Notifications** | Native macOS notifications | None |
| **Install** | macOS only — [cmux.com](https://cmux.com) | Everywhere — `brew install tmux` |
| **Best for** | Watching agents work in real time | Headless / Linux / WSL |

---

## Install

```bash
npm install -g agent-karen
pip3 install pyyaml
```

---

## Quick Start

### 1. Create your config

```bash
mkdir -p ~/.karen
cat > ~/.karen/config.yaml << 'EOF'
hub: ~/.karen/hub

projects:
  myapp:
    dir: ~/projects/my-app
    knowledge:
      - ~/projects/my-app/docs
    agents:
      manager: { role: manager, autostart: true }
      lead: { role: lead }
      dev1: { role: dev }
      dev2: { role: dev }
      qa: { role: qa }
EOF
```

### 2. Start everything

```bash
karen up
```

This creates the hub, sets up permissions, and spawns all `autostart: true` agents. The manager launches in its own workspace tab (`myapp:manager`).

### 3. Talk to the manager

```
I want to build a multi-tenant invoicing SaaS for freelancers. MVP only.
Spawn a PM and let's figure out the scope.
```

### 4. Monitor

```bash
karen health                               # all agent statuses
karen health --project myapp               # filter by project
karen config agents                        # list all defined agents
tail -f ~/.karen/hub/communications.md     # watch the conversation
bd list                                    # task state
```

### 5. Clean up

```bash
karen shutdown --all                       # stop everything
karen shutdown --project myapp             # stop one project
karen shutdown myapp-dev1                  # stop one agent
karen shutdown --idle 15                   # reap idle agents
```

---

## Multi-Project Setup

Define multiple projects in your config. Agents get unique IDs (`project-role`) and can message across projects:

```yaml
hub: ~/.karen/hub

projects:
  backend:
    dir: ~/projects/api-server
    knowledge:
      - ~/projects/api-server/docs
    agents:
      manager: { role: manager, autostart: true }
      dev1: { role: dev }

  frontend:
    dir: ~/projects/web-app
    agents:
      manager: { role: manager, autostart: true }
      dev1: { role: dev }
      ux: { role: ux }
```

```bash
karen up                                            # starts both projects
karen msg frontend-dev1 "API spec changed" message  # cross-project message
```

---

## Commands

```bash
karen up [--project <key>]                   # Start agents from config.yaml
karen config {show|projects|agents}          # Inspect configuration
karen spawn <agent_id> "<context>" [dir]     # Spawn an agent manually
karen msg <target> "<message>" [type]        # Send a message
karen health [--project <key>]               # Check agent health
karen shutdown <id|--all|--project|--idle>   # Shut down agents
```

---

## Custom Roles

Roles are markdown files. Three-tier lookup:

1. **Project-local** — `your-project/.agent-roles/analyst.md`
2. **Custom** — `custom-roles/analyst.md` in the karen install dir
3. **Defaults** — `roles/dev.md` shipped with Karen

```bash
mkdir -p ~/projects/my-app/.agent-roles
cat > ~/projects/my-app/.agent-roles/analyst.md << 'EOF'
# ROLE: Analyst
You analyze data and produce reports.

## Inbox
`$KAREN_HUB_DIR/inbox/$KAREN_AGENT_ID.jsonl`

## Sending messages
$AGENT_SCAFFOLD_ROOT/scripts/msg.sh manager "<findings>" result
EOF
```

Then spawn: `karen spawn myapp-analyst "Analyze Q1 revenue data"`

---

## Memory System

- **Shared memory** (`hub/memory/shared.md`) — cross-agent facts and decisions. All agents read on boot.
- **Agent memory** (`hub/memory/<agent-id>.md`) — per-agent. Written before shutdown, read on respawn.
- **Knowledge base** (`hub/knowledge/<project>/`) — reference docs symlinked from config.

Memory persists across shutdowns and respawns. Agents are reminded to save before exit.

---

## Environment Variables

Spawned agents receive these automatically:

| Variable | Example | Purpose |
|----------|---------|---------|
| `KAREN_HUB_DIR` | `~/.karen/hub` | Central hub for all state |
| `KAREN_AGENT_ID` | `myapp-dev1` | Full agent identity |
| `KAREN_PROJECT_KEY` | `myapp` | Project namespace |
| `KAREN_PROJECT_DIR` | `~/projects/my-app` | Code working directory |
| `AGENT_ROLE` | `dev` | Short role name |
| `AGENT_SCAFFOLD_ROOT` | `/path/to/scaffold` | Karen scripts location |

---

## Default Roles

| Role | What it does |
|------|-------------|
| `manager` | Orchestrates the team. Delegates everything. Talks to you. |
| `pm` | Clarifies the vision. Writes the product brief. |
| `lead` | Tech lead. Designs architecture. Assigns and monitors dev tasks. |
| `dev` | Implements features. Writes tests. Used for `dev1`, `dev2`, etc. |
| `qa` | Tests features. Files bug reports. Approves releases. |
| `security` | Audits code. Finds vulnerabilities. |
| `ux` | Designs UI/UX. Writes specs. |
| `cmo` | Writes copy. Handles positioning and marketing. |

---

## Migrating from Per-Project .agent/

If you have an existing project using the old per-project `.agent/` model:

```bash
# Migrate state to the hub
karen-scripts/migrate-to-hub.sh myapp ~/projects/my-app

# Then use karen up going forward
karen up
```

The old `.agent/` directory is preserved (not deleted). Both models coexist — scripts fall back to `pwd/.agent` if no hub is configured.

---

## Tips

- **Start small.** Manager -> 1 dev. Scale once the pattern works.
- **Audit trail.** `cat ~/.karen/hub/communications.md` for the full story.
- **Task state.** `bd list` from any workspace.
- **Auto-cleanup.** Set `AUTO_SHUTDOWN_MINS=15` to reap idle agents.
- **Respawn.** State persists. `karen spawn myapp-pm "Resume. Check inbox."` picks up where it left off.
- **Tab names.** cmux tabs show `project:role` (e.g., `myapp:dev1`) for easy identification.

---

## Learn more

- [GitHub](https://github.com/sivaranjansahu/agent-karen)
