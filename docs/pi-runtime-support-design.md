# Design note: pluggable agent runtime (Claude Code | Pi) for local karen

**Status:** APPROVED (human, 2026-07-08) — decisions locked below; ready to delegate the build.
**Author:** karen-manager · 2026-07-08 · **Build is DELEGATED to a dev (not manager-implemented).**
**Sources:** makerpad `docs/karen-claudecode-to-pi-migration.md`, `pi-messaging-spike.md`,
`pi-inter-agent-messaging-research.md`, `karen-cloud-pi-skills-spec.md`,
`karen-pi-local-testing-plan.md`, `spike/pi-agent/`; **Pi's own docs**
`toys/pi/packages/coding-agent/docs/providers.md`.

**Governing principle (from the human):** before designing ANY Pi-side mechanism, **check
Pi's own docs first — do not reinvent what the runtime already provides.** (This is why the
credential item below was removed from scope: Pi owns it.)

## Goal & binding requirement (from the human)

Let a local karen agent run on either **Claude Code** (`claude`) or **Pi**
(`@earendil-works/pi-coding-agent`, CLI `pi`). Runtime is a **spawn-time decision at
the manager level**, two tiers:

1. When the human spawns a project's **manager**, they choose that manager's runtime.
2. When a manager spawns its **agents**, it chooses each agent's runtime at spawn time.

`spawn.sh` takes `--runtime pi|claude` at **every** spawn. `config.yaml` may carry
per-project / per-role **defaults**, but the **spawn-time argument always wins**, and a
manager on one runtime **must** be able to spawn agents on the other (mixed teams).

## The seam is exactly analogous to the existing model-selection seam

`spawn.sh:95–105` already resolves an `EFFECTIVE_MODEL` (precedence: `SPAWN_MODEL` env >
role-file `<!-- model: X -->` directive > harness default) and builds a `--model` flag
consumed at the launch line (`spawn.sh:244`). Runtime selection mirrors this precisely:

```
EFFECTIVE_RUNTIME  =  --runtime arg / SPAWN_RUNTIME env      (spawn-time — always wins)
                   >  config.yaml runtime for this project/role  (default)
                   >  "claude"                                    (global default)
```

Then the launch line **dispatches** on `EFFECTIVE_RUNTIME` instead of hardcoding `claude`.
Two launch sites change: `spawn.sh:244` (agents) and `bootstrap.sh:214`
(`exec claude …` — the manager's own boot, i.e. tier 1).

### config.yaml (defaults only)

```yaml
projects:
  myapp:
    dir: /path/to/myapp
    runtime: claude            # project default
    roles:
      dev1: { runtime: pi }    # per-role default override (optional)
```

Resolution ladder for a spawn of `myapp-dev1`: `--runtime` arg → `roles.dev1.runtime`
→ `projects.myapp.runtime` → `claude`.

## Launch dispatch — what actually differs per runtime

| Concern | Claude Code (today) | Pi |
|---|---|---|
| CLI | `claude --dangerously-skip-permissions [--remote-control ID] [--model M] "<prompt>"` | `pi -p "<prompt>" --provider P --model M --tools <allowlist> -e <ext.ts>` |
| Autonomy/permissions | `--dangerously-skip-permissions` (allow all) | **`--tools` allowlist** — MUST include `bash` (so the agent can call `msg.sh`), plus `read,write,edit` and any registered tool |
| Role file | `CLAUDE.md` | `AGENTS.md` (Pi also reads `CLAUDE.md` for compat — so role files can stay, but canonical is AGENTS.md) |
| Model/provider | `--model` (Anthropic) | `--provider`/`--model` **optional**; defaults to Pi's OWN configured default. Credentials are **Pi's own** (`/login` OAuth + `~/.pi/agent/auth.json` + env) — NOT karen's concern |
| Hooks | `.claude/settings.json` (see below) | `.pi/extensions/*.ts` (event-based) |
| Skills | Claude Code skills | Pi skills (`.agents/skills/SKILL.md`) — different format |

## Cross-cutting integration surface (the real work — beyond the launch line)

The scaffold's coordination is **file-based and runtime-agnostic where it counts**:
agents send via `msg.sh` (bash), state lives in `.agent/inbox/*.jsonl` + `communications.md`.
The pi-messaging-spike confirms a Pi agent will happily call a CLI like `msg.sh` via `bash`
(as long as `bash` is in `--tools`) — **so inter-agent messaging works for mixed teams with
no router**. The genuinely runtime-specific pieces:

1. **Hooks parity (biggest gap).** `.claude/settings.json` wires:
   - `UserPromptSubmit → hooks/check-inbox.sh` — this is the "📬 N new messages" wake
     injection that drives the whole inbox loop.
   - `Stop → hooks/notify-done.sh, hooks/auto-shutdown.sh`.
   Pi has no `UserPromptSubmit`; it has `session_shutdown` (≈ Stop) and a `tool_call` event.
   **Plan:** ship a `.pi/extensions/karen-hooks.ts` (analogous to the cloud's
   `karen-callbacks.ts`) that mirrors notify-done/auto-shutdown on `session_shutdown`. The
   inbox-check-on-prompt has no direct Pi event — options: (a) rely on the heartbeat's
   wake-send (already how idle agents get poked) + an AGENTS.md instruction to re-read the
   inbox each turn; (b) a Pi extension hook on turn-start if one exists in Pi 0.80+. **Open
   decision — flag for the human.**
2. **Heartbeat screen-detection is claude-UI-specific.** `heartbeat.sh` greps the pane for
   `^❯`, "Do you want to proceed", "bypass permissions", "API Error", "Cooked for" etc.
   Pi's TUI has different idle/permission/error strings. Without Pi patterns, the heartbeat
   can't detect a Pi agent's idle/stuck/dead-session states (dead-workspace detection still
   works — it's runtime-agnostic). **Plan:** add a per-runtime pattern set in heartbeat.sh
   (a small `case "$RUNTIME"` table). Needs the Pi TUI strings captured from a live run.
3. **`--tools` allowlist** must at minimum be `bash,read,write,edit` for a Pi karen agent
   (bash = msg.sh/health.sh/bd/cmux access). Role-specific tightening later.
4. **Credentials & provider/model — OUT OF KAREN'S SCOPE.** Pi already owns credential
   management (Pi docs `packages/coding-agent/docs/providers.md`): subscription OAuth via
   `/login` (ChatGPT/Codex, **Claude Pro/Max**, GitHub Copilot; tokens in
   `~/.pi/agent/auth.json`, auto-refresh), plus API keys via the standard provider env vars
   or the `0600` auth file, with a documented resolution order (auth file > env). **Karen must
   NOT build, store, or proxy any Pi credential.** At most, config.yaml/spawn flags may select
   `--provider`/`--model`; even that **defaults to Pi's own configured default** — karen omits
   those flags entirely unless explicitly set. (Removed from scope per the human, 2026-07-08.)
5. **Dependencies.** Pi needs `bash git ripgrep` + `npm i -g @earendil-works/pi-coding-agent`.
   A `karen doctor`-style check should verify the selected runtime's CLI is installed.
6. **`--remote-control`** is claude-only; the Pi branch omits it (and any RC-dependent
   features degrade gracefully for Pi agents).

## Phased rollout (recommended)

1. **Seam only, claude-only behavior unchanged.** Add `--runtime`/config resolution +
   dispatch; `claude` path byte-for-byte identical; `pi` path behind the seam. Tests green.
2. **Pi launch happy-path.** `pi` invocation + `--tools` + AGENTS.md + `karen-hooks.ts`
   (session_shutdown parity). Prove a single Pi agent boots, reads its inbox, runs a task,
   and reports via `msg.sh` in a live workspace.
3. **Mixed-team round-trip.** claude-manager spawns a pi-dev (and vice-versa); confirm the
   msg.sh round-trip closes both ways.
4. **Heartbeat Pi patterns.** Capture Pi TUI strings; add the per-runtime pattern table so
   idle/stuck/dead detection works for Pi agents.
5. **Provider/model UX + docs.** README + `karen doctor` runtime check.

Default stays `claude`; Pi is strictly opt-in until step 3 is proven — zero risk to the
running fleet.

## Decisions — LOCKED (human, 2026-07-08)

- **Design: APPROVED.**
- **Inbox-wake for Pi (concern 1):** use the existing **runtime-agnostic** path — `msg.sh`
  instant nudge + heartbeat wake backstop + instruction-level inbox discipline in the role
  file. A Pi hook extension (Stop-mirror via `session_shutdown`) is a **fast-follow**, not v1.
- **Credentials/keys (concern 4): VOID** — Pi owns them. Karen builds nothing here.
- **AGENTS.md (concern, launch table):** rely on Pi's `CLAUDE.md` **compat read** for v1;
  authoring per-role `AGENTS.md` is a **fast-follow**.
- **v1 scope:** **mixed-team round-trip PROVEN** — a **claude** manager spawns a **pi** agent,
  messages round-trip **both ways** via `msg.sh`, and a **real task completes**. Heartbeat Pi
  screen-patterns (concern 2) + AGENTS.md authoring are explicitly **fast-follow (post-v1)**.

## Delegation plan (APPROVED — delegate now)

Delegate to a dev via `spawn.sh` with a handoff brief. **v1 = steps 1–3** (seam + Pi
happy-path + mixed-team round-trip), under TDD — extend `tests/test_karen.sh`, mirroring the
model-seam precedent (`test_spawn_workdir_from_config` / the `EFFECTIVE_MODEL` resolution)
for `EFFECTIVE_RUNTIME`. Hard constraints for the dev:

- **Check Pi's own docs first** for any Pi-side mechanism — don't reinvent what Pi provides.
- **Build NOTHING for credentials** — Pi owns them; don't pass keys, don't store keys. Provider/
  model flags optional, default to Pi's own configured default.
- **Wake stays the existing runtime-agnostic path** (msg.sh + heartbeat + role-file inbox
  discipline). No Pi hook extension in v1.
- **`claude` path must remain byte-for-byte unchanged**; Pi is strictly opt-in.
- TDD, commit in chunks, **no push until manager review**.
- **Fast-follow (post-v1, separate):** heartbeat Pi screen-patterns (concern 2), per-role
  AGENTS.md authoring, optional Pi Stop-mirror extension.

Direct implementation is NOT in scope for the manager (the direct-impl exception was
heartbeat-only).
