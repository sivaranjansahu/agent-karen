# Fleet Monitoring & Autonomous Fix Framework — Design

**Date:** 2026-07-07
**Status:** Approved by user (brainstorm session, fdecareers manager terminal)
**Decided with user:** tiered autonomy · Sentry as telemetry standard · poll-based alert bridge · lives inside agent-karen (Option A) · initial fleet: fdecareers.ai + northfacinghomes

## Problem

Multiple Next.js web properties, all deployed to Cloudflare via wrangler, need autonomous monitoring and bug-fixing. Each property has (or will have) a dedicated Karen manager that built it and holds full codebase context. Wanted: a modular framework where adding a site is cheap, a local fleet manager detects incidents, and dedicated site managers fix and deploy within guardrails.

## Architecture — three strictly separated layers

| Layer | What | Cost | Runs |
|---|---|---|---|
| **Detection** | Sentry (errors + Crons + Uptime) per site; local poller script probes Sentry API + health URLs + GH Actions | ~free, no LLM | launchd, every 3 min |
| **Routing** | Fleet manager (Karen role): enrich, dedupe, route, spawn-if-absent, verify resolution | LLM, wakes on signal only | on incident |
| **Resolution** | Existing dedicated site managers: diagnose, fix, deploy within autonomy tier | LLM | on dispatch |

Each layer changes without touching the others: swap polling for webhooks later, add sites without framework changes, upgrade site-manager behavior per site.

## Site registry — the modularity contract

**Amendment (2026-07-08, binding, from the human):** the fleet runs as a karen
**workspace** — the first production use of the workspace feature (self-contained
`.karen/config.yaml`, own hub). This splits CODE from INSTANCE:

- **Code (reusable, ships in agent-karen/agent-scaffold):** the poller
  (`scripts/fleet-poller.sh`, plain bash, no LLM), the detection functions it
  drives (`lib/fleet.sh`), the `fleet-manager` role template
  (`roles/fleet-manager.md`), and the launchd plist template
  (`scripts/com.karen.fleet-poller.plist`, provided — not installed by the
  scaffold, the operator installs it once).
- **Instance (deployment state, its own git repo, NOT the scaffold repo):**
  `/Users/jarvis/projects/fleet/` — `.karen/config.yaml`,
  `registry/<site>.yaml` manifests, `incidents/{queue/,log.jsonl}`.

So the registry path below is now **`<fleet-workspace>/registry/<site>.yaml`**
(e.g. `/Users/jarvis/projects/fleet/registry/fdecareers.yaml`), not
`$AGENT_SCAFFOLD_ROOT/fleet/registry/` as originally specced here — one manifest
per property, adding a site to the fleet is still just one manifest file
(+ optional Sentry wiring for depth).

```yaml
name: fdecareers
production_url: https://fdecareers.ai
health_url: https://fdecareers.ai/          # poller expects HTTP 200
repo: /Users/jarvis/projects/fdecareers
manager: fdecareers-manager                  # Karen role/agent name
sentry_project: fdecareers                   # slug in the Sentry org (optional)
deploy: npm run deploy                       # from repo root (wrangler underneath)
rollback: cloudflare-pages                   # rollback strategy; ALWAYS paired with git revert
crons:                                       # expected heartbeats (Sentry Crons monitor slugs)
  - slug: daily-refresh
    grace_hours: 6                           # GH cron lags HOURS; 4-6h daily, ~1d weekly (proven)
autonomy:
  tier_overrides: []                         # e.g. protected paths: ["src/payments/**"]
```

### Detection degrades gracefully (instrumentation is per-site, not a fleet blocker)

1. **Manifest only:** health-URL probe + GH Actions failure detection — works day one, zero instrumentation.
2. **+ Sentry Crons:** one check-in curl per workflow — catches silently-stopped crons (dead-man's switch).
3. **+ Sentry SDK:** `@sentry/nextjs` (client-side — sites are static exports, no server runtime) and `@sentry/cloudflare` for Workers (e.g. fit-worker) — stack traces, issue grouping, release tagging; the raw material for autonomous fixes.

## Incident flow

```
Sentry alert / failed health probe / missed cron heartbeat
  → poller writes incident JSON to <fleet-workspace>/incidents/queue/, wakes fleet manager
  → fleet manager: dedupe (one open incident per site+signal), enrich
    (Cloudflare logs via wrangler/API, Sentry issue details, recent deploys/commits),
    create bead, look up registry
  → site manager alive?  msg.sh incident brief  :  spawn.sh + VERIFY materialized
  → site manager diagnoses + fixes within its tier, reports result
  → fleet manager verifies INDEPENDENTLY (health probe green, Sentry issue
    resolved, error rate at baseline) before closing the bead —
    never trusts a "fixed" claim
  → outcome appended to <fleet-workspace>/incidents/log.jsonl (the fleet's run-log)
```

## Autonomy tiers

- **Tier 0 — mechanical, fully autonomous:** rollback to last good Cloudflare deploy **plus `git revert` + push** (a dashboard rollback alone gets re-clobbered by the next cron — proven incident), re-run a failed cron, revert a bad data commit. No new code.
- **Tier 1 — code fix, autonomous with gates:** fix on a branch → build-gate + tests pass → deploy → **post-deploy verification** (health probe + Sentry error rate, 15-min window). Verification fails → automatic Tier-0 rollback + escalate to user.
- **Tier 2 — human-gated:** protected paths from the manifest (auth, payments, data migrations, DNS/token scopes) or any incident after two failed fix attempts. Delivered as PR + incident report; user approves the deploy.

## Framework self-monitoring

The historically observed failure mode is the machinery dying silently, not the sites. Therefore:

- **Poller heartbeat:** the poller itself checks into a Sentry Cron monitor — poller death alerts the user directly.
- **Spawn verification mandatory:** after any `spawn.sh`, confirm the agent materialized via `health.sh` **and** a ping-ack. If spawning is broken (known cmux new-workspace bug: surfaces never materialize, sends vanish, health.sh false-alive — fix is restarting the Claude desktop app), the fleet manager stops, push-notifies the user naming that fix, and parks the incident. It never pretends dispatch succeeded.
- **Cost discipline** (per standing Karen rules): fleet manager and site managers hibernate when idle; nothing loops warm; detection is LLM-free.

## Secrets / prerequisites

- Sentry org + API auth token (poller read scope) — user-provided, stored outside repos.
- Existing per-site Cloudflare tokens unchanged; fleet manager needs log-read access (wrangler/API).
- Note from prior incidents: Pages-scope tokens do not cover Worker deploys (Workers Scripts + KV + Routes: Edit are separate scopes).

## Rollout

1. **Phase 1 (done):** build the CODE (poller, `lib/fleet.sh` detection functions,
   fleet-manager role template, launchd plist template) in agent-karen/agent-scaffold;
   create the INSTANCE (`/Users/jarvis/projects/fleet/`, its own git repo) with
   `fdecareers` registered (full manifest) and `vebinar` registered (minimal,
   sentry-only — no confirmed production URL in-repo yet). Sentry SDK instrumentation
   for fdecareers itself, and migrating its `HEALTHCHECK_URL_*` pings to Sentry Crons
   check-ins, are separate later work packages, not part of this phase.
2. **Fire-drill (phase 2, run WITH the human watching):** deliberately break
   non-critical things (kill a cron, deploy a 500 page) and watch the loop run detect
   → route → spawn → fix → verify end-to-end.
3. Onboard **northfacinghomes** when it has a deployed property — the modularity test:
   one manifest, zero framework changes.

## Out of scope (deliberate)

- Webhook/event-driven alert bridge (plug-in point exists; polling first).
- Cross-site correlation ("Cloudflare itself is down") — dedupe handles the worst noise; correlation can come later.
- Fixing the cmux spawn bug itself (tracked separately; this design routes around it safely).
