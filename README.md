# agent-karen

<img width="437" height="493" alt="image" src="https://github.com/user-attachments/assets/0511a49e-d551-4e06-a680-937f4250a413" />

*keeping your agents on a short leash since 2025.*

Will escalate to the manager. Will file a ticket for it, and keep spawning and killing agents until it is closed. Karen don't quit.

---

**Workspace-based multiagent coordination for Claude Code (and Pi).** Spawn a team of autonomous AI agents — PM, Dev Lead, developers, QA, CMO, or any custom role — that work in parallel, each in their own terminal workspace. You talk to the manager. It runs the team.

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
- A **role definition** (markdown file = `CLAUDE.md`, also read by Pi for compat)
- A **private inbox** (`<hub>/inbox/<agent-id>.jsonl`)
- **Persistent task memory** via [Beads](https://github.com/steveyegge/beads)
- Access to **shared context** and **knowledge bases**
- A choice of **runtime** — Claude Code (default) or [Pi](#pluggable-runtime-claude-code--pi), picked per spawn

Every message and spawn is logged to `<hub>/communications.md` — a full audit trail.

---

## Architecture: Central Hub

All agent state lives in a single hub directory (`~/.karen/hub/` by default), not scattered across projects:

```
~/.karen/
  config.yaml                       # declare your projects + agents
  hub/
    inbox/
      myproject-manager.jsonl       # agent ID = project-role
      myproject-dev1.jsonl
      other-manager.jsonl           # multi-project support
    state/                          # workspace IDs, cursors, heartbeat pidfile
    memory/
      shared.md                     # global shared memory
      myproject-manager.md          # per-agent persistent memory
    context/
      myproject/brief.md            # per-project context
    knowledge/
      myproject/docs -> ~/proj/docs # symlinked knowledge bases
    beads/                          # per-project task DB (via `bd`)
    communications.md               # single global audit log
```

Agents in different projects can message each other. Short names work within a project (`msg.sh dev1 "hello"` auto-resolves to `myproject-dev1`). Full IDs work cross-project (`msg.sh other-manager "need your API spec"`).

---

## Architecture: Workspace-Based Multiagent Coordination

For a repo you want fully self-contained — its own hub, its own state, nothing hand-wired into a global config — drop a `.karen/config.yaml` at its root:

```
my-workspace/
  .karen/
    config.yaml     # projects/agents for this workspace only
    hub/             # this workspace's own inbox/state/memory/beads
                     # (default when config.yaml declares no `hub:` key)
  src/
  ...
```

Run `karen` (any command — `spawn`, `msg`, `status`, `where`, ...) from anywhere inside `my-workspace/`, including nested subdirectories, and it finds this config via an **upward search** — nearest wins. Multiple independent workspaces coexist on one machine without touching each other's state or the global hub.

Resolution is one ladder, checked in order, for both which config applies and (derived from it) which hub applies:

1. **Explicit override** — `$KAREN_CONFIG` env var, or `$KAREN_HUB_DIR` / `$KAREN_PROJECT_AGENT_DIR` for the hub directly. Highest priority; this is how a central-hub setup (`karen up`) and any script that already exports these keeps working unchanged.
2. **Nearest workspace config** — walk up from `$PWD` to `/`, first `.karen/config.yaml` found wins. Its hub is that config's own `hub:` key if declared, otherwise the config's own directory (`.karen/`) — self-contained, no hand-wired path needed.
3. **Global fallback** — `~/.karen/config.yaml` (the central-hub setup above).

If neither a workspace config nor an explicit override applies, standalone project-local `.agent/` discovery (the original, pre-hub model) still works exactly as before.

Run `karen where` (or `karen paths`) anywhere to see exactly what resolved and why — the workspace root, which config won and via which tier, the hub directory and its tier, and every state/inbox/memory/context path.

---

## Pluggable Runtime: Claude Code + Pi

Every agent — including the manager — can run on **Claude Code** (default) or **[Pi](https://github.com/earendil-works/pi-mono)** (`@earendil-works/pi-coding-agent`), chosen independently per spawn. Mixed teams work: a Claude manager can spawn Pi agents and vice versa, and they message each other exactly the same way (`msg.sh`, no router, no adapter — Pi calls it via its `bash` tool).

```bash
karen spawn myapp-dev1 --runtime pi "Implement the auth module."   # this one dev runs on Pi
karen start --runtime pi                                            # the manager itself runs on Pi
```

Resolution ladder (spawn-time always wins):

1. `--runtime <claude|pi>` flag (spawn.sh, karen start/bootstrap.sh) or `$SPAWN_RUNTIME` env — explicit, per-spawn.
2. `config.yaml` per-agent default: `projects.<key>.agents.<agent>.runtime`.
3. `config.yaml` per-project default: `projects.<key>.runtime`.
4. `claude` — the global default. Pi is strictly opt-in.

```yaml
projects:
  myapp:
    dir: ~/projects/my-app
    runtime: claude            # project default
    agents:
      manager: { role: manager, autostart: true }
      dev1:    { role: dev, runtime: pi }   # this agent defaults to Pi
```

What's identical either way: role file (`CLAUDE.md`, Pi reads it for compat), inbox, memory, wake mechanism (`msg.sh` + heartbeat — a **running** Pi agent wakes on the same keystroke-injection nudge as Claude, no Pi-specific hook needed). What differs: the launch flags. Claude gets `--dangerously-skip-permissions`; Pi gets an explicit `--tools bash,read,write,edit` allowlist instead (its own permission model). Karen never touches Pi's credentials, provider, or model selection — Pi owns all of that (`pi` → `/login`, or the standard provider env vars/`auth.json`); karen only ever passes `--provider`/`--model` if you explicitly set them.

Requires `npm i -g @earendil-works/pi-coding-agent` and a Pi credential already configured (`pi` then `/login`, or an API key) — that setup is yours to do once, karen doesn't touch it.

---

## Prerequisites

- [Claude Code](https://claude.ai/code) (`npm install -g @anthropic-ai/claude-code`) — and/or [Pi](https://github.com/earendil-works/pi-mono) (`npm i -g @earendil-works/pi-coding-agent`) if you want to run any agents on it
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

```bash
cd ~/projects/my-app
karen start
```

That's it. If the project isn't registered yet, `karen start` auto-registers it, sets up permissions, and launches the manager in your current terminal. No config editing required.

### Talk to the manager

```
I want to build a multi-tenant invoicing SaaS for freelancers. MVP only.
Spawn a PM and let's figure out the scope.
```

The manager spawns whatever agents it needs from there.

### Monitor

```bash
karen health                               # all agent statuses
karen status                               # active tabs, inbox counts, tasks, QA state
karen where                                # resolved hub/config paths + why
tail -f ~/.karen/hub/communications.md     # watch the conversation
bd list                                    # task state
```

### Clean up

```bash
karen shutdown --all                       # stop everything
karen shutdown --project myapp             # stop one project
karen shutdown myapp-dev1                  # stop one agent
karen clean                                # interactively close idle/orphaned tabs
karen clean --force                        # close all idle tabs without asking
```

---

## Adding knowledge or customizing a project

After starting, use `karen add` to update the project's config without relaunching:

```bash
karen add --knowledge ./docs               # link a knowledge directory
karen add --knowledge ./specs              # add another
karen add --name better-name              # rename the project key
```

`karen add` is safe to re-run — it upserts, never duplicates.

---

## Starting multiple projects at once

If you prefer to declare everything upfront and launch all at once, use `~/.karen/config.yaml` + `karen up`:

```yaml
hub: ~/.karen/hub

projects:
  myapp:
    dir: ~/projects/my-app
    runtime: claude              # optional project-level runtime default
    knowledge:
      - ~/projects/my-app/docs
    agents:
      manager: { role: manager, autostart: true }
      lead: { role: lead }
      dev1: { role: dev }
      dev2: { role: dev, runtime: pi }   # optional per-agent runtime override
      qa: { role: qa }
```

```bash
karen up                    # spawn all autostart agents across all projects
karen up --project myapp    # one project only
```

---

## Multi-Project Setup

Agents get unique IDs (`project-role`) and can message across projects:

```bash
# Register each project from its own directory
cd ~/projects/api-server && karen start
cd ~/projects/web-app    && karen start
```

Or declare them all in `~/.karen/config.yaml` and `karen up`.

Cross-project messaging works automatically — full IDs resolve across hubs:

```bash
karen msg frontend-dev1 "API spec changed" message
```

---

## Commands

```bash
karen start [--runtime <claude|pi>] [dir]     # Launch manager (auto-registers if needed)
karen add [--name <key>] [--knowledge <dir>]  # Register/update a project in config
karen up [--project <key>]                    # Spawn all autostart agents from config
karen config {show|projects|agents}           # Inspect configuration
karen spawn [--runtime <claude|pi>] <agent_id> "<context>" [dir]   # Spawn an agent manually
karen msg <target> "<message>" [type]         # Send a message
karen health [--project <key>]                # Check agent health
karen status                                  # Snapshot: tabs, inboxes, tasks, QA, cmux log
karen shutdown <id|--all|--project|--idle>    # Shut down agents
karen clean [--force|--all]                   # Close idle/orphaned tabs
karen where                                   # Resolved path model: workspace root,
                                               #  which config/hub won and via which
                                               #  tier (aliases: karen paths)
```

---

## Custom Roles

Roles are markdown files. Three-tier lookup:

1. **Project-local** — `your-project/.agent-roles/analyst.md`
2. **Custom** — `custom-roles/analyst.md` in the karen install dir
3. **Defaults** — `roles/dev.md` shipped with Karen

A role file can also pin its own default model with a directive on the first line:

```markdown
<!-- model: opus -->
# ROLE: Analyst
You analyze data and produce reports.

## Inbox
`$KAREN_HUB_DIR/inbox/$KAREN_AGENT_ID.jsonl`

## Sending messages
$AGENT_SCAFFOLD_ROOT/scripts/msg.sh manager "<findings>" result
```

```bash
mkdir -p ~/projects/my-app/.agent-roles
# ...write the role file above to ~/projects/my-app/.agent-roles/analyst.md...
karen spawn myapp-analyst "Analyze Q1 revenue data"
```

---

## Memory System

- **Shared memory** (`hub/memory/shared.md`) — cross-agent facts and decisions. All agents read on boot.
- **Agent memory** (`hub/memory/<agent-id>.md`) — per-agent. Written before shutdown, read on respawn.
- **Knowledge base** (`hub/knowledge/<project>/`) — reference docs symlinked from config.
- **Task memory** (`bd`/[Beads](https://github.com/steveyegge/beads)) — per-project, git-backed, survives shutdowns.

Memory persists across shutdowns and respawns. Agents are reminded to save before exit.

---

## Heartbeat Daemon

Every `karen up`/`karen start` starts (or reuses) one heartbeat daemon per hub — a background loop that keeps the team moving without you watching it:

- Wakes idle agents that have unread inbox messages.
- Auto-approves stuck permission prompts.
- Detects a dead agent (its tab/workspace is gone) and escalates to the manager once, deduped.

```bash
./scripts/heartbeat.sh status    # is a daemon running for this hub?
./scripts/heartbeat.sh stop      # stop it
```

It's a **per-hub singleton** — starting a second `loop` while one is already running for the same hub refuses immediately instead of piling up duplicate daemons.

---

## Chat Integrations (optional)

The manager's inbox can be fed from Slack or Telegram instead of (or alongside) the terminal, via standalone poller daemons:

```bash
scripts/slack-daemon.sh {start|stop|status}      # polls Slack every 3s, wakes the manager tab
scripts/telegram-daemon.sh                        # polls Telegram every 5s, same idea
```

Both write incoming messages straight into the manager's inbox and nudge its tab via the same `mux_send` wake path everything else uses — no special handling on the agent side.

---

## Environment Variables

Spawned agents receive these automatically:

| Variable | Example | Purpose |
|----------|---------|---------|
| `KAREN_HUB_DIR` | `~/.karen/hub` | Explicit hub override — highest priority |
| `KAREN_CONFIG` | `~/.karen/config.yaml` | Explicit config override — highest priority |
| `KAREN_AGENT_ID` | `myapp-dev1` | Full agent identity |
| `KAREN_PROJECT_KEY` | `myapp` | Project namespace |
| `KAREN_PROJECT_DIR` | `~/projects/my-app` | Code working directory |
| `AGENT_ROLE` | `dev` | Short role name |
| `AGENT_SCAFFOLD_ROOT` | `/path/to/scaffold` | Karen scripts location |
| `BEADS_ROOT` | `~/projects/my-app` | Shared task-DB root for `bd` (manager + all its agents) |

None of these are required day-to-day — a `.karen/config.yaml` at your workspace root (upward-searched, nearest wins) or the global `~/.karen/config.yaml` fallback covers everything; see [Architecture: Workspace-Based Multiagent Coordination](#architecture-workspace-based-multiagent-coordination). Set `KAREN_HUB_DIR`/`KAREN_CONFIG` only to pin a specific hub/config regardless of cwd.

Caller-side overrides for a single spawn (not exported to the agent, just read by `spawn.sh`/`bootstrap.sh` at launch time):

| Variable | Purpose |
|----------|---------|
| `SPAWN_MODEL` | Force a specific Claude model for this spawn (overrides the role file's `<!-- model: X -->` directive) |
| `SPAWN_RUNTIME` | Force `claude` or `pi` for this spawn (overrides config.yaml's `runtime:` default) |
| `SPAWN_RC` | If set, adds `--remote-control <agent-id>` to a Claude launch |

---

## Default Roles

| Role | Default model | What it does |
|------|---------------|-------------|
| `manager` | opus | Orchestrates the team. Delegates everything. Talks to you. |
| `pm` | (harness default) | Clarifies the vision. Writes the product brief. |
| `lead` | sonnet | Tech lead. Designs architecture. Assigns and monitors dev tasks. |
| `dev` | sonnet | Implements features. Writes tests. Used for `dev1`, `dev2`, etc. |
| `qa` | (harness default) | Tests features. Files bug reports. Approves releases. |
| `security` | (harness default) | Audits code. Finds vulnerabilities. |
| `ux` | (harness default) | Designs UI/UX. Writes specs. |
| `cmo` | sonnet | Writes copy. Handles positioning and marketing. |

("Default model" only applies when running on Claude Code — see each role's `<!-- model: X -->` directive. Pi agents pick their own model per Pi's own configuration.)

---

## Migrating from Per-Project .agent/

If you have an existing project using the old per-project `.agent/` model:

```bash
# Migrate state to the hub
scripts/migrate-to-hub.sh myapp ~/projects/my-app

# Then use karen up going forward
karen up
```

The old `.agent/` directory is preserved (not deleted). Both models coexist — scripts fall back to `pwd/.agent` if no hub or workspace config is found.

---

## Tips

- **Start small.** Manager -> 1 dev. Scale once the pattern works.
- **Audit trail.** `cat ~/.karen/hub/communications.md` for the full story.
- **Task state.** `bd list` from any workspace.
- **Auto-cleanup.** Set `AUTO_SHUTDOWN_MINS=15` to reap idle agents.
- **Respawn.** State persists. `karen spawn myapp-pm "Resume. Check inbox."` picks up where it left off.
- **Tab names.** cmux tabs show `project:role` (e.g., `myapp:dev1`) for easy identification.
- **Debugging paths.** `karen where` is the fastest way to find out which hub/config an agent actually resolved, and why.
- **Mixed teams.** Not sure if Pi is worth trying for a role? Spawn just that one agent with `--runtime pi` — everything else keeps running on Claude, no config changes needed.

---

## Learn more

- [GitHub](https://github.com/sivaranjansahu/agent-karen)
