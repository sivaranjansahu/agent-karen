# Hub / messaging unification — design (karen-manager recommendation)

> **⚠️ SUPERSEDED (2026-07-08) by `workspace-model-design.md`.** The human reframed the problem: the
> source of truth is the WORKSPACE (a domain-grouped, pointer-based, own-repo container), not a global
> `~/.karen` registry. Cross-hub messaging is DISSOLVED by co-locating related projects in one workspace
> (shared hub → same-hub messaging), not indexed by a registry. Cross-workspace messaging is out of scope,
> so nothing global is needed. This doc is kept for the root-cause analysis (msg.sh sender-side resolution)
> which remains accurate; the registry solution is abandoned.

**Status:** SUPERSEDED — see workspace-model-design.md.
**Authors:** karen-manager (built the workspace resolution ladder) + fleet manager (evidence + seed options).
**Closes on ship:** bead `agent-scaffold-jes` (cross-hub ACK) + the localmind mis-address finding + relates to P3 `agent-scaffold-2x4`.

## Root cause (confirmed in code, not theory)

`scripts/msg.sh` resolves the **sender's own** hub, then writes the message into it:

```
HUB_DIR=$(resolve_hub_dir)                    # sender-side: ambient env/config
TARGET_ID=$(resolve_agent_id "$TARGET")
INBOX="$HUB_DIR/inbox/${TARGET_ID}.jsonl"     # written to SENDER's hub
mux_send "$TARGET_ID" "...check ${HUB_DIR}/inbox/${TARGET_ID}.jsonl..."
```

The **wake** is already correct cross-hub (`mux_send` finds the terminal by global cmux id, hub-independent).
The **message content** is misfiled: it lands in the *sender's* hub `inbox/<target>.jsonl`, which the recipient —
reading *its own* hub — never sees. That is exactly failures (1) fdecareers→fleet ACK (sent:0) and
(2) localmind (three plausible hubs, sender guessed wrong). Naming: msg.sh already addresses
`<agent-id>.jsonl` (project-qualified); the `manager.jsonl` variant is created by **boot paths** that name an
agent's *own* inbox with the bare role — a second, colliding scheme.

**One-line diagnosis:** addressing is *sender-side and ambient*. The recipient's inbox location is knowable only
by the recipient, but every sender re-derives it from its own environment, so they disagree.

## Recommendation: Option A, refined — "self-declared global agent registry"

Adopt **A (registry-as-truth)**, with two refinements that make it robust and minimal:

1. **The registry entry for an agent is written by THAT agent's own spawn/boot** — the one process that
   authoritatively knows its effective hub (even when booted with an explicit `KAREN_HUB_DIR` override).
   Resolution flips from *sender-guesses* to *recipient-self-declares-once, everyone-reads*.
2. **Keep the registry SEPARATE from the declarative `config.yaml`.** `config.yaml` stays the source of truth for
   *how to spawn* (workdir, runtime, model, defaults). A dedicated runtime registry is the source of truth for
   *where an agent's inbox physically is*. One source of truth **per question** — no overloading, no fragmentation.

Reject **B** (one physical central hub): it discards the workspace isolation we just shipped and is a large, risky
relocation. Take the *spirit* of **C** (global index) — that index *is* the registry below.

### The registry

`~/.karen/registry.jsonl` — **append-only, flock-guarded, last-entry-wins per `agent_id`** (converged: JSONL beats
YAML rewrite-in-place for crash safety; occasional `--gc` compaction). One entry per registration event:

```json
{"agent_id":"fleet-manager","hub_dir":"/Users/jarvis/projects/fleet/.karen","inbox":"fleet-manager.jsonl","cmux_ws":"workspace:48","surface":"surface:102","status":"up","updated":"2026-07-08T16:34:00Z"}
```

- **Written by:** the agent's own bootstrap at spawn (`bootstrap.sh`) and refreshed on `karen up` / re-spawn.
  `shutdown.sh` appends a **tombstone** (`"status":"down"`) — preserves history, keeps the append-only invariant,
  and lets `health` distinguish never-existed from shut-down.
- **Read by:** `msg.sh` (recipient hub **and** wake target), `where.sh`/`health.sh` (reporting), `wake.sh`.
- **Carries `cmux_ws`+`surface`** so the **wake** resolves the target's workspace from the registry too — msg.sh no
  longer reads the per-hub `state/<id>_workspace` file, so neither the message NOR the wake depends on ambient state.
- **The single source of truth for "where is agent X's inbox + terminal."** No sender ever computes another agent's location.

## Exact delta (files touched — smallest that gets us there)

Tiered so the **CORE** kills the messaging bug alone; **COMPLETENESS** finishes "once and for all."

### CORE (fixes failures 1 & 2 by themselves)
- `lib/hub.sh` — add `register_agent(agent_id, hub_dir, inbox, cmux_ws)` (flock-guarded upsert to
  `~/.karen/registry.jsonl`), `resolve_recipient(agent_id) -> hub_dir + inbox` (registry lookup, exit-nonzero if
  absent), `unregister_agent(agent_id)`.
- `scripts/msg.sh` — replace `HUB_DIR=$(resolve_hub_dir)` + `INBOX="$HUB_DIR/inbox/${TARGET_ID}.jsonl"` with a
  **registry lookup of the RECIPIENT**: `read HUB_DIR INBOX_FILE CMUX_WS < <(resolve_recipient "$TARGET_ID")` —
  used for BOTH the inbox write and the wake target (drop the `state/<id>_workspace` read). On registry-miss, fail
  LOUDLY with **actionable copy**, not a bare error: e.g. `"<id> not in registry — agent never booted post-migration?
  run 'karen migrate'. Legacy hubs searched: <list>."` (a hard error that doesn't say what to do is just new confusion).
- `scripts/bootstrap.sh` — at boot, after the effective hub is known, call `register_agent` with the agent's REAL
  hub (this is the fix for the localmind case: a standalone `KAREN_HUB_DIR=…/.agent` boot self-registers that path).

### COMPLETENESS
- `scripts/up.sh` — register each autostart agent it brings up (it already knows the hub).
- `scripts/shutdown.sh` — `unregister_agent` (tombstone) so stale entries don't accumulate.
- `scripts/add.sh` — when a workspace is added, record its hub so its agents resolve.
- `cli.sh` + new `scripts/migrate.sh` — `karen migrate` (see below).
- `scripts/where.sh` — show the registry (and flag legacy hubs not yet registered).
- `scripts/health.sh` — source liveness from the registry instead of scanning one hub.

**Not touched / not moved:** existing hub *contents* stay physically where they are. This is a
resolution-layer change, not a data migration. That is what keeps the delta small and safe for running agents.

## Migration story (register-in-place — do NOT relocate)

`karen migrate` scans the known legacy/parallel layouts and **registers where things already are** (no file moves):

| Existing hub | Layout | migrate action |
|---|---|---|
| fdecareers `/…/fdecareers/.agent` | standalone `.agent` | register its agents at that path |
| fleet `/…/fleet/.karen` | workspace | register (already self-registers on `karen up` after CORE) |
| makerpad central `~/.karen/hub` | central | register its agents at that path |
| localmind ×3 (`agent-karen/`, `~/.karen/hub`, `.agent`) | legacy + central + standalone | register the LIVE one; tombstone the two dead layouts |

For each discovered agent, migrate also **normalizes the inbox filename** to `<agent-id>.jsonl` and leaves a
**symlink from the legacy name** (`manager.jsonl -> localmind-manager.jsonl`) so any in-flight/legacy sender still
lands correctly during the transition. One idempotent command; re-runnable.

## Naming unification

**One scheme everywhere: `<project>-<role>.jsonl`** (fully-qualified agent id) — which `msg.sh` already assumes.
- Fix the **boot path(s)** that create a bare `manager.jsonl` for an agent's own inbox → use the qualified id.
- `resolve_agent_id` stays the short-name convenience (`dev1` → `<project>-dev1`) but the on-disk inbox is always
  the qualified id. No more `manager.jsonl` vs `project-manager.jsonl` ambiguity.

## Addressing after the change

`msg.sh <agent-id|short-name> "<msg>" <type>`:
1. `TARGET_ID = resolve_agent_id(target)` (short-name → qualified, unchanged).
2. `HUB_DIR, INBOX = resolve_recipient(TARGET_ID)` — **registry lookup, sender's ambient env irrelevant**.
3. write `<HUB_DIR>/inbox/<TARGET_ID>.jsonl`; wake via `mux_send TARGET_ID` (unchanged).
4. recipient absent from registry → **hard error listing candidates**, never a silent misfile.

Cross-hub "just works": the sender never needs to know, guess, or share the recipient's hub. `KAREN_HUB_DIR` reverts
to what it should be — a *local override for tests / explicit standalone boot* — and even then the agent
self-registers that override, so others can still reach it.

## Resolved (converged karen-manager + fleet manager, 2026-07-08)
1. **Format: JSONL**, append-only + flock, last-entry-wins per `agent_id`, occasional `--gc` compaction
   (crash-safe vs YAML rewrite-in-place).
2. **Shutdown: tombstone** (`status:down` appended) — preserves history, keeps append-only, lets `health`
   tell never-existed from shut-down.
3. **Both migration paths:** explicit `karen migrate` = one-time register-in-place for hubs whose agents aren't
   running; boot-time self-registration = the perpetual auto path. **Relocation is NEVER automatic.**
4. **Registry-miss error carries actionable copy** (run `karen migrate`, legacy hub list) — see msg.sh delta.
5. **Registry entry carries `cmux_ws`+`surface`** so wake resolves from the registry, not ambient state.

**Status:** joint proposal, converged. → human approval gate. HOLD all implementation until the human approves;
then delegate to a dev (TDD, CORE tier first, review-inversion → fleet manager pushes).
