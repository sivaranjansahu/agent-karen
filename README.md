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
  └─ Manager agent        ← you talk to this one
       ├─ PM agent         ← writes the product brief
       ├─ Dev Lead agent   ← breaks tasks, spawns devs
       │    ├─ Dev 1
       │    ├─ Dev 2
       │    └─ Dev N
       └─ QA agent         ← validates dev output
```

Each agent gets:
- A **role definition** (markdown file = `CLAUDE.md`)
- A **private inbox** (`.agent/inbox/<role>.jsonl`)
- **Persistent task memory** via [Beads](https://github.com/steveyegge/beads)
- Access to **shared context files** (`.agent/context/`)

Every message and spawn is logged to `.agent/communications.md` — a full audit trail of everything the team did.

---

## Prerequisites

- [Claude Code](https://claude.ai/code) (`npm install -g @anthropic-ai/claude-code`)
- A terminal multiplexer (see below)
- Node.js ≥ 16
- Python 3

### Terminal backend: cmux vs tmux

Karen auto-detects your terminal and picks the best available backend. **The visual experience is very different:**

| | [cmux](https://cmux.com) | [tmux](https://github.com/tmux/tmux) |
|---|---|---|
| **Visual** | Each agent gets a **visible tab** — you see all agents side by side, switch with a click | Agents run in **hidden windows** — you switch with `Ctrl-b <number>` |
| **Notifications** | Native macOS notifications when agents finish | No notifications |
| **Status bar** | Shows agent role, task status, progress | None |
| **Install** | macOS only — [cmux.com](https://cmux.com) | Everywhere — `brew install tmux` |
| **Best for** | Watching agents work in real time | Headless / Linux / WSL |

**Recommendation:** If you're on macOS and want to *see* your agents working in parallel — use cmux. If you're on Linux/WSL or prefer keyboard-driven workflows — tmux works fine, you just navigate between agent windows with `Ctrl-b` + window number.

---

## Install

```bash
npm install -g agent-karen
```

---

## Getting Started

Pick the scenario that matches what you want to do.

---

### Use Case 1 — Build something new from scratch

You have an idea. No code yet. You want Karen to spin up a PM, plan the product, then hand off to a dev team.

**Step 1: Initialize Karen for your project**

```bash
mkdir ~/projects/my-app
karen init ~/projects/my-app
```

You'll see Karen check dependencies, create the `.agent/` directory, and initialize Beads.

**Step 2: Start the manager**

Open tmux, then start Karen:

```bash
tmux new-session -s agents -n manager
karen start ~/projects/my-app
```

Claude Code launches in manager mode. You're now talking to the manager.

**Step 3: Give the manager your idea**

Type your goal directly into Claude:

```
I want to build a multi-tenant invoicing SaaS for freelancers. MVP only.
Spawn a PM and let's figure out the scope.
```

The manager will spawn a PM agent in a new tmux window. Switch to it with `Ctrl+b` then the window number, or watch `.agent/communications.md` for updates.

**Step 4: Answer the PM's questions**

The PM will message the manager with clarifying questions (target users, core features, pricing, etc.). The manager will relay them to you. Answer in the manager terminal.

**Step 5: PM writes the brief — dev team kicks off**

Once you've answered the PM's questions, the PM writes `.agent/context/brief.md` and notifies the manager. The manager then spawns a Dev Lead, who reads the brief, breaks it into tasks, and spawns dev agents.

**Step 6: Monitor progress**

```bash
# See all agent statuses
karen health

# Watch the full conversation
tail -f .agent/communications.md

# See open tasks across all agents
bd list
```

**Step 7: Clean up idle agents**

```bash
karen shutdown --idle 15    # kill agents idle for 15+ minutes
karen shutdown --all        # shut everything down
```

---

### Use Case 2 — Add a feature to an existing codebase

You have existing code. You want to implement a specific feature without touching PM planning.

**Step 1: Initialize Karen, pointing it at your docs**

```bash
karen init ~/projects/my-app --knowledge ~/projects/my-app/docs
```

The `--knowledge` flag symlinks your docs directory into `.agent/knowledge/` so every agent can read them.

**Step 2: Start the manager**

```bash
tmux new-session -s agents -n manager
karen start ~/projects/my-app
```

**Step 3: Skip PM — go straight to Dev Lead**

Tell the manager exactly what to build:

```
Skip the PM. Spawn a Dev Lead and tell them to implement Stripe webhook handling
for invoice payment events. The existing Stripe integration is in src/payments/.
Use the architecture in docs/. Tests required.
```

The manager spawns a Dev Lead, who reads the codebase and your knowledge docs, then spawns one or more dev agents to implement in parallel.

**Step 4: Spawn QA when dev signals done**

When the Dev Lead reports completion, ask the manager to bring in QA:

```
Dev Lead says the Stripe webhooks are done. Spawn a QA agent to validate.
```

QA reads the code, runs tests, and files a report at `.agent/state/qa_report.md`.

---

### Use Case 3 — Review and harden an existing codebase

You want a security audit and quality review of your existing code, running in parallel.

**Step 1: Initialize Karen**

```bash
karen init ~/projects/my-app --knowledge ~/projects/my-app/docs
```

**Step 2: Start the manager and spawn reviewers directly**

```bash
tmux new-session -s agents -n manager
karen start ~/projects/my-app
```

Then tell the manager:

```
Spawn a Security agent and a QA agent in parallel.
Security: audit src/ for OWASP Top 10 — focus on auth and API endpoints.
QA: review test coverage and flag any untested critical paths.
Both should write their findings to .agent/context/.
```

**Step 3: Monitor and collect results**

```bash
karen health                        # both agents should show UP
tail -f .agent/communications.md    # watch findings come in
```

Results land in:
- `.agent/context/security-report.md`
- `.agent/context/qa-report.md`

**Step 4: Ask the manager to triage**

```
Security and QA are done. Read their reports and give me a prioritized fix list.
```

---

## Commands

```bash
karen init <project> [--knowledge <dir>]    # Initialize for a project
karen start <project>                       # Start the manager agent
karen spawn <role> "<context>" [dir]        # Spawn an agent manually
karen msg <role> "<message>" [type]         # Send a message to an agent
karen health                                # Check all agents are alive
karen shutdown <role|--all|--idle N>        # Shut down agents
karen status                                # Show agent overview
```

### Skip permission prompts

Agents will ask for approval on bash commands by default. To skip all prompts:

```bash
karen start --dangerously-skip-permissions ~/projects/my-app
```

Spawned agents inherit this automatically — set it once on the manager, the whole team runs without prompts.

**What's actually happening:** Karen translates this into `--allowedTools "Bash(*)"` but keeps your deny rules active. So `git push`, `rm -rf`, and `sudo` are still blocked. It's "skip the annoying prompts" not "skip all safety."

---

## Custom roles

Roles are markdown files. Three-tier lookup — highest priority first:

1. **Project-local** — `your-project/.agent-roles/pm.md`
2. **Custom** — `custom-roles/pm.md` in the karen install dir
3. **Defaults** — `roles/pm.md` shipped with Karen

To customize a role for your project:

```bash
mkdir -p ~/projects/my-app/.agent-roles
cp $(npm root -g)/agent-karen/roles/pm.md ~/projects/my-app/.agent-roles/pm.md
# Edit it — it's just markdown
```

---

## Memory system

Agents have persistent memory that survives shutdown and respawn:

- **Shared memory** (`.agent/memory/shared.md`) — cross-agent facts and decisions. All agents read this on boot.
- **Role memory** (`.agent/memory/{role}.md`) — per-agent memory. Agents write key learnings here before shutdown so the next spawn picks up where they left off.
- **Knowledge base** (`.agent/knowledge/`) — reference docs symlinked during `karen init --knowledge`.

Agents are reminded to save memory on shutdown. Memory files persist in the project's `.agent/` directory.

---

## Permissions

`karen init` sets up safe default permissions in your project's `.claude/settings.json`:

- **Allowed:** Read, Write, Edit, git (safe ops), npm, node, python3, shell utilities, cmux/tmux, beads
- **Denied:** `git push`, `git reset --hard`, `rm -rf`, `sudo` — these always require manual approval

Re-running `karen init` merges new permissions without overwriting your custom rules.

---

## Tips

- **Start small.** Manager → Dev Lead → 1 dev. Scale once the pattern works.
- **Audit trail.** `cat .agent/communications.md` for the full story of what every agent did.
- **Task state.** `bd list` from any workspace — Beads is shared via git.
- **Context window.** Long-running agents accumulate history. Shut down and respawn with a summary context for very long tasks.
- **Auto-cleanup.** Set `AUTO_SHUTDOWN_MINS=15` to automatically reap idle agents after 15 minutes.
- **Respawn anytime.** State is preserved on disk. `karen spawn pm "Resume. Check inbox and bd quickstart."` picks up where it left off.

---

## Default roles

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

## Learn more

- [Full product spec](.agent/context/agent-karen-spec.md) — architecture, file protocol, lifecycle, all commands
- [GitHub](https://github.com/sivaranjansahu/agent-karen)
