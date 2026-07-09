# Workspace model — design

**Status:** DESIGN ONLY — converge with fleet manager, then human approval before ANY implementation.
**Authors:** karen-manager (workspace-feature author, design authority) from the human's requirements + fleet-manager convergence.
**Supersedes:** `hub-messaging-unification-design.md` (global-registry approach — abandoned).
**Closes on ship:** bead `jes` (cross-hub messaging — dissolved, not indexed), the localmind mis-address finding.

## Requirements (from the human, 2026-07-08 — locked)

1. **A workspace groups projects by DOMAIN/type** — a `development` workspace for all coding projects, a
   `marketing` workspace for marketing. Not grouped by function/monitoring.
2. **A workspace is its OWN git repo** — it stores the workspace's *brain*: memory, the full comms/message
   history, inboxes, decisions — versioned + backed up to a private remote so nothing is ever lost.
3. **A workspace holds POINTERS to projects, not the project folders** — it references each project's code dir
   by path. Project code stays in its own repo/dir on disk; the workspace points to it.
4. **One shared hub per workspace** → every project-manager in a workspace shares that hub's inbox space, so
   **manager↔manager messaging within a workspace is same-hub and just works** (the cross-hub bug cannot occur).
5. **Cross-WORKSPACE messaging is OUT OF SCOPE** — workspaces are isolated coordination domains. Nothing global
   is built. (A `coding` manager does not message a `marketing` manager.)
6. **Migration required** — fold the existing scattered Karen hubs into the appropriate workspace.

## Why this is mostly formalize-and-migrate, not build-from-scratch

The existing primitives already implement most of it:
- `config.yaml` `projects: { <key>: { dir: <path> } }` — the `dir:` **is** the pointer (req 3). `add.sh` upserts it.
- `up.sh` already starts EVERY project in a config, all sharing the ONE hub = the config's dir (req 4).
- The fleet workspace already proved "workspace = its own git repo with a private remote" (req 2).
- **Same-hub messaging already works with zero `msg.sh` changes** — msg.sh writes to `resolve_hub_dir()/inbox/<id>.jsonl`;
  when sender+recipient share a hub, that's correct. The cross-hub bug only ever occurred because we put related
  projects in SEPARATE hubs. Co-locating them in a workspace removes the cause (req 1/4).

So the registry design is dead: it *indexed* fragmentation; the workspace model *eliminates* it.

## Target layout

```
~/karen-workspaces/development/          # git repo, private remote — the BRAIN
├── .karen/
│   ├── config.yaml                       # projects{}: POINTERS (dir:) to each project's code
│   ├── communications.md                 # unified workspace comms (all managers) — versioned
│   ├── inbox/<project>-<role>.jsonl       # shared inboxes, QUALIFIED names (see naming)
│   ├── memory/  shared.md + <agent>.md    # preserved per-project brains, folded in
│   ├── state/   incidents/  knowledge/    # knowledge/ = symlinks to each project's own knowledge dir
└── (workspace repo tracks the whole .karen brain)

/Users/jarvis/projects/fdecareers/        # UNCHANGED code repo — pointed at, not contained
  └── (code + its own knowledge dir, left as-is; its .agent BRAIN migrates out)
```

- `development` workspace projects (locked): agent-scaffold, fdecareers, fleet-monitoring, vebinar,
  northfacinghomes, localmind, makerpad, zap, ingest.
- `marketing` workspace projects: the CMO terminal (initially just that).

## Messaging after the change

- Intra-workspace: `msg.sh <project>-manager` → same shared hub → lands correctly, wakes via cmux. **No msg.sh
  logic change needed for the core case.**
- **Naming unification becomes REQUIRED (not optional) — at BOTH layers:** a shared multi-project hub cannot hold
  two bare `manager.jsonl`, and cmux cannot hold two bare `:dev1` / `:lead` surfaces.
  1. **Inbox filename:** always `<project>-<role>.jsonl` (fdecareers-manager.jsonl, …) — msg.sh already addresses
     this; the fix is the BOOT paths that still create bare `manager.jsonl`.
  2. **cmux spawn identity (current bug flagged by the human):** agents today spawn as bare `:lead` / `:dev1`
     (no project) — spawn.sh must pass the project so the cmux workspace/surface is `<project>:<role>`
     (e.g. `fdecareers:dev1`, not `:dev1`). Without this, two projects' `dev1`s collide in a shared workspace hub
     and the human can't tell which agent is which.
  Both are the same root cause (identity not project-qualified) and are the **one hard code requirement** of P1.
- Cross-workspace: intentionally unsupported. `msg.sh` to an agent not in the current workspace hub → the
  existing "not found" path, with a clearer message ("<id> not in this workspace; cross-workspace is out of scope").

## Migration plan (the real work — safe, staged, reversible)

Principle: **copy the brain into the workspace repo, archive the old hub, never delete until verified. Do it with
the affected agents HIBERNATED** (live cutover otherwise races the inbox).

1. **Create the workspace repo:** `~/karen-workspaces/development/`, `git init`, `.karen/` skeleton, private remote
   (same discipline as the fleet repo).
2. **Register each project as a pointer:** `karen add <project-dir>` into the development config (writes
   `projects.<key>.dir`). Knowledge dirs stay with the project, linked into the hub (`up.sh` already does this).
3. **Fold each brain in** (preserve history — this is the "not lost" requirement):
   - per-agent `memory/*.md` → workspace `memory/` (namespaced by project where names collide)
   - each project's `communications.md` history → merged chronologically into the workspace `communications.md`
     (keep per-project original as an archived file too, for provenance)
   - inbox histories `inbox/*.jsonl` → workspace `inbox/`, renamed to qualified `<project>-<role>.jsonl`
   - **knowledge dirs: left in place**, re-linked (not copied)
4. **Re-home agents:** future spawns/`karen up` target the workspace hub; old standalone `.agent` hubs are
   archived (tombstoned), not deleted.
5. **SECRET SCAN before first push (HARD gate, per hub):** the folded-in comms logs + memory files may contain
   token-shaped strings from past sessions. Grep every migrated brain for token/secret patterns BEFORE the
   workspace repo gets its private remote or first push (same discipline that cleared the fleet repo). No push
   until clean. This is a checklist item on EACH hub's fold-in, not a one-time step.
6. **Commit + push the workspace repo** — brain versioned + backed up (only after step 5 passes).

### Cutover mechanics (must be handled or the merge breaks live infra)
- **Fleet poller hub-targeting:** the poller unsets ambient env and resolves the fleet workspace hub. After fold-in
  it must be re-pointed at the merged `development` hub (its incident queue/log move with it). Update the poller's
  hub resolution + the plist template as part of P2.
- **Heartbeat singleton (per-hub):** after cutover, verify EXACTLY ONE heartbeat daemon runs for the merged
  workspace hub — the old per-hub daemons for the folded hubs must be stopped, or we re-leak. Post-migration check:
  `heartbeat status` shows 1 for the workspace, 0 for each archived hub.
- **Running sessions' stale `KAREN_HUB_DIR` (the settings-cache bug against ourselves):** live agent sessions
  export the OLD hub (e.g. the fleet manager's own session exports `fdecareers/.agent`). A running session won't
  pick up the new hub — same class as the P3 settings-cache finding. So: migrate with agents HIBERNATED; every
  session that must stay up needs its env updated or a restart; **sequence the coordinating manager LAST** (or plan
  its explicit restart) so it isn't cut off mid-migration.

### Legacy / dead layouts — DELETE or tombstone (not just fold the live ones)
Dead mailboxes caused today's mis-addressing (localmind's three plausible hubs). Migration must actively
**tombstone or remove** the dead layouts — `localmind/agent-karen/`, stale `~/.karen/hub` entries, orphaned
`.agent` dirs — not merely fold the live one. Leave a tombstone marker (`MIGRATED-TO: <workspace> on <date>`) so a
stray sender hitting an old path gets a clear redirect instead of silent misfiling.

### Per-hub migration table

| Existing hub | Type | → development workspace action |
|---|---|---|
| fdecareers `/…/fdecareers/.agent` | standalone | fold brain in; fdecareers dir becomes code+pointer |
| fleet `/…/fleet/.karen` | workspace (own repo) | fold in as a project; preserve incidents/log.jsonl |
| makerpad `~/.karen/hub` | central | fold in; disentangle from the global hub |
| localmind ×3 (agent-karen/, ~/.karen/hub, .agent) | legacy+central+standalone | fold the LIVE one; archive the 2 dead layouts |
| agent-scaffold (self) | code repo | pointer only (its code is the karen CLI itself) |

## What's actually built (delta)

- **New:** `karen workspace` command family (create/list) OR extend `karen add`/`karen init` for the workspace-repo
  scaffold + remote; `karen migrate` (the fold-in tool above, idempotent, dry-run first).
- **Changed:** boot paths that name inboxes → qualified `<project>-<role>.jsonl` (the one hard messaging fix);
  README/CLI help to present the domain-workspace model.
- **Unchanged:** `msg.sh` core routing (same-hub already works); `resolve_hub_dir`/`resolve_karen_config` ladder;
  project code repos; knowledge dirs.

## Explicitly OUT of scope
- Cross-workspace messaging / any global registry (req 5).
- Relocating project CODE (only the brain moves; code stays pointed-at).

## The CMO cross-domain bridge — DECIDED: break it (human, 2026-07-08)
`cmo` moves to the `marketing` workspace. The old `cmo → dev/manager` approval bridge is **intentionally severed**
— it is no longer needed. Workspaces are fully isolated coordination domains; there is NO cross-workspace path and
none is built. (If cmo ever needs coding-side approval again, the human is the manual bridge — but it's not a
supported channel.)

## HARD CONSTRAINT: no disruption to running agents until deliberate migration
`agent-scaffold` main IS the live `karen` command every running agent calls — a change ships to all of them on push.
Therefore:
- **P1 naming fix MUST be backward-compatible.** New spawns get qualified identity (`<project>:<role>` cmux +
  `<project>-<role>.jsonl` inbox). But `msg.sh` must **read BOTH** the old bare name and the new qualified name during
  the transition, so agents already running under the old scheme keep receiving messages. No flag-day rename.
- **The hub migration (P2) is a controlled cutover with the affected agents HIBERNATED** — never a live re-home of a
  running session. Existing agents keep running in their current hubs, untouched, until each is deliberately folded in.
- Net: building + shipping P1 does not disturb any running agent; P2 disturbs an agent only at the planned moment it
  is migrated (and it's down for that moment by design). Verify with the standing fdecareers-hub regression check
  after every P1 chunk (msg.sh/health.sh round-trip unchanged), exactly as the workspace/heartbeat features did.

## Phased build (post-approval, delegated to a dev, TDD, review-inversion → fleet manager pushes)
- **P1 — scaffold:** `karen workspace create` (own repo + remote + `.karen` skeleton), qualified-inbox naming fix,
  tests. Delivers a usable empty workspace + fixes the naming collision.
- **P2 — migrate:** `karen migrate` with dry-run, per-hub fold-in, history preservation, archive-not-delete;
  migrate the `development` workspace for real (agents hibernated), verify messaging round-trips.
- **P3 — polish:** README/CLI positioning, `karen workspace list`, `marketing` workspace bootstrap (CMO).

## Decided / open
- **Decided:** domain grouping; own-repo brain; pointer model; brain folds in (knowledge stays); cross-workspace out;
  qualified inbox names.
- **Open (my recommended defaults):** workspace repo root `~/karen-workspaces/<name>/` (confirm); comms merge =
  chronological + keep per-project archives (recommend); migrate = copy+archive, delete only after a verified
  round-trip (recommend). None block starting P1.
