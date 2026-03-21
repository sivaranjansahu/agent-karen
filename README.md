# agent-karen
<img width="437" height="493" alt="image" src="https://github.com/user-attachments/assets/0511a49e-d551-4e06-a680-937f4250a413" />


*"I want to talk to the manager."*

**Multi-agent coordination for Claude Code.** Spawn a team of autonomous AI agents — PM, Dev Lead, developers, QA, CMO, or any custom role — that work in parallel across cmux workspaces. Each agent gets a scoped role definition, a private inbox, persistent task memory ([Beads](https://github.com/steveyegge/beads)), and access to shared context files. Agents communicate through async message passing, delegate subtasks, and produce artifacts — all captured in a full audit trail.

**Who it's for:** Developers building with AI agents who want to move beyond single-agent workflows. If you're using Claude Code and want multiple instances collaborating on the same codebase — planning, building, testing, and reviewing in parallel — this is the coordination layer.

**Why it matters:** Current AI coding tools run one agent at a time. This scaffold gives you role separation, parallel execution, and structured communication between agents. No orchestration server, no custom SDK — just shell scripts, JSONL inboxes, and markdown files. One bootstrap command sets it up. You talk to the manager; it runs the team.

## Architecture

```
You (human)
  └─ Manager agent        (workspace 1 — you talk to this one)
       ├─ PM agent         (workspace 2 — brainstorms product brief)
       ├─ Dev Lead agent   (workspace 3 — breaks tasks, spawns devs)
       │    ├─ Dev 1       (workspace 4)
       │    ├─ Dev 2       (workspace 5)
       │    └─ Dev N       (workspace N)
       └─ QA agent         (workspace 6 — validates dev output)
```

## Key systems

| System | Purpose |
|--------|---------|
| **cmux socket** | Spawn workspaces, send commands, notifications |
| **Beads (`bd`)** | Persistent task memory — survives session resets, multi-agent safe |
| **Inbox files** | `.agent/inbox/<role>.jsonl` — message queue per agent |
| **Push trigger** | `cmux send-surface` wakes target terminal after each message |
| **communications.md** | Append-only log of every inter-agent message and spawn event |

## Quick start

```bash
# Install
npm install -g agent-karen

# Initialize for your project
karen init /path/to/your/project

# Talk to the manager
karen start /path/to/your/project
# "I want to build a multi-tenant invoicing SaaS. Spawn a PM and let's brainstorm."
```

Or without installing:
```bash
npx agent-karen init .
```

## Commands

```bash
karen init <project> [--knowledge <dir>]   # Initialize for a project
karen start <project>                      # Start the manager agent
karen spawn <role> "<context>" [dir]       # Spawn an agent
karen msg <role> "<message>" [type]        # Send a message to an agent
karen health                              # Check all agents are alive
karen shutdown <role|--all|--idle N>       # Shut down agents
karen status                              # Show agent overview
```

## Custom roles

Roles are markdown files that define an agent's behavior. Three-tier lookup:

1. **Project-local** (`your-project/.agent-roles/pm.md`) — highest priority
2. **Custom** (`custom-roles/pm.md` in karen install dir) — your personal overrides
3. **Defaults** (`roles/pm.md`) — shipped with karen

```bash
mkdir -p /path/to/your/project/.agent-roles
cp $(npm root -g)/agent-karen/roles/pm.md /path/to/your/project/.agent-roles/pm.md
# Edit to fit your domain
```

## File structure

```
.
├── bootstrap.sh                  # Run once to start the manager
├── .claude/
│   └── settings.json             # Claude Code Stop hook → cmux notification
├── .agent/
│   ├── communications.md         # ← Every inter-agent message logged here
│   ├── inbox/
│   │   ├── manager.jsonl
│   │   ├── pm.jsonl
│   │   ├── lead.jsonl
│   │   ├── dev1.jsonl
│   │   └── qa.jsonl
│   ├── context/
│   │   ├── brief.md              # PM writes, everyone reads
│   │   └── decisions.md          # Architectural decision log
│   └── state/
│       ├── manager_surface       # cmux surface IDs (auto-written on spawn)
│       ├── lead_surface
│       ├── dev1_result.md        # Dev output summaries
│       └── qa_report.md          # QA verdict
├── roles/                        # CLAUDE.md definitions per role
│   ├── manager.md
│   ├── pm.md
│   ├── lead.md
│   ├── dev.md                    # Used for devN (dev1, dev2, …)
│   └── qa.md
├── hooks/
│   └── notify-done.sh            # Claude Code Stop hook
└── scripts/
    ├── spawn.sh                  # Create workspace + launch agent (logs to comms.md)
    ├── msg.sh                    # Send message + wake terminal (logs to comms.md)
    └── status.sh                 # Snapshot of all agents
```

## Scripts

### `./bootstrap.sh [workdir]`
- Checks cmux socket
- Installs Beads if not present, runs `bd init`
- Creates/resets `.agent/communications.md`
- Registers manager surface
- Copies `roles/manager.md` → `CLAUDE.md`
- Launches Claude Code

### `./scripts/spawn.sh <role> "<context>" [workdir]`
Creates a workspace, writes init message to inbox, logs the spawn to
`communications.md`, and launches Claude Code with the correct role.

```bash
./scripts/spawn.sh pm "Build a SaaS for freelance invoicing. MVP first."
./scripts/spawn.sh lead "Brief ready at .agent/context/brief.md"
./scripts/spawn.sh dev1 "Implement auth module (bd-a1b2). See brief."
./scripts/spawn.sh qa "Validate auth + invoice CRUD. Bead IDs: bd-a1b2, bd-c3d4"
```

### `./scripts/msg.sh <role> "<message>" [type]`
Appends to inbox, logs to `communications.md`, sends push-trigger to wake terminal.

Message types: `message` (default) | `question` | `escalation` | `result` | `unblock`

```bash
./scripts/msg.sh manager "Brief complete. See .agent/context/brief.md" result
./scripts/msg.sh lead "Unblock dev1: use Redis for session store" unblock
./scripts/msg.sh dev2 "Can you also add rate limiting to /api/login?" question
```

### `./scripts/status.sh`
Active surfaces, inbox sizes, Beads task summary, recent cmux log.

## Beads quick reference

```bash
bd quickstart           # orient: open tasks, ready tasks, blockers
bd list                 # all open issues
bd ready                # issues with no open blockers (start here)
bd create "Title" --priority P1 --description "..."
bd claim <id>           # atomically mark in_progress + assign to self
bd close <id>           # mark done
bd link <id> blocks <id2>     # dependency
bd link <id> relates_to <id2> # related
bd show <id>            # full detail + audit trail
bd compact              # summarise old closed issues (keep db light)
```

Beads stores everything in Git (`.beads/` dir). Multi-agent safe: hash-based
IDs prevent merge conflicts. Survives session resets — agents pick up where they left off.

## communications.md format

Auto-appended by `msg.sh` and `spawn.sh`. Looks like:

```markdown
## [2026-03-18 14:22:01 UTC] `manager` → `pm` (spawn)

**Spawned new agent workspace.** Workspace: `ws-abc` · Surface: `sf-xyz`

**Init context:** Build a multi-tenant invoicing SaaS. MVP first.

---

## [2026-03-18 14:25:10 UTC] `pm` → `manager` (question)

Before I draft the brief, a few questions:
1. B2B or B2C?
2. What payment processors do we need to support?
...

---

## [2026-03-18 14:31:45 UTC] `manager` → `pm` (message)

B2B. Stripe only for now.

---
```

## Tips

- **Start small**: manager → PM → lead → 1 dev. Scale once the pattern works.
- **Audit trail**: `cat .agent/communications.md` for the full story.
- **Task state**: `bd list` from any workspace — shared via git.
- **After cmux restart**: run `bootstrap.sh` again to re-register surface IDs.
- **Longer sessions**: tell agents to run `bd quickstart` at the start to re-orient.
