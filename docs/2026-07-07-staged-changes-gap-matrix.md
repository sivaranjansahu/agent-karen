# Staged-changes recovery — gap matrix

Reconciles the 19-file change set staged (but never committed) on 2026-06-23,
described in `/Users/jarvis/projects/STAGED-CHANGES-SUMMARY.md`, against `main`
as of this recovery (base: `d3d4cb5` "before opencode" + the uncommitted WIP
sitting in the working tree at the time). The codebase moved on since June —
notably the central-hub + declarative-YAML-config architecture
(`e8ed2d2` and follow-ups) — so several staged behaviors were superseded by a
different design rather than simply missing.

Legend: **HEAD** = already satisfied on main before this recovery (possibly via
a different implementation) · **WIP** = was sitting uncommitted, kept ·
**BUILT** = implemented in this recovery · **SUPERSEDED** = deliberately not
rebuilt, with reason · **BUG FOUND** = a defect discovered while validating,
fixed as part of this recovery.

| # | File / behavior | Verdict | Notes |
|---|---|---|---|
| 1 | `bin/cli.sh`: `karen where` / `karen paths` | **BUILT** | New `scripts/where.sh` + wired into `bin/cli.sh`. Prints cwd, scaffold root, config file, `$KAREN_CONFIG`/`$KAREN_HUB_DIR`, and the resolved hub's inbox/state/memory/context/knowledge/beads dirs + communications log. Exits 1 with a clear message when no hub resolves. Tests: `test_cli_where_resolves_hub`, `test_cli_where_fails_without_hub`. |
| 2 | `lib/hub.sh`: `extract_project_key()` regex over role names | **HEAD** (different impl) | Current `extract_project_key` (added in `1c53f91`/`e8ed2d2` era) does a generic `${AGENT_ID%%-*}` split instead of enumerating role-name suffixes (manager/pm/lead/devN/qa/...). It's simpler and covers arbitrary custom roles the enumerated regex wouldn't. No rebuild needed — the enumerated-regex approach would be a regression. |
| 3 | `roles/*.md`: inbox path `.../inbox/<role>.jsonl` → `.../inbox/$KAREN_AGENT_ID.jsonl` | **BUG FOUND + BUILT** | Real doc/runtime mismatch: `spawn.sh` writes to `$HUB_DIR/inbox/${AGENT_ID}.jsonl` (full project-prefixed ID) but all 8 role docs told the agent to check a *static* role-name inbox (`inbox/pm.jsonl`, `dev.md` used `$AGENT_ROLE` — still not the full ID). Fixed all 8 files (cmo, dev, lead, manager, pm, qa, security, ux) to reference `$KAREN_AGENT_ID`. |
| 4 | `roles/manager.md`: mandatory structured handoff template | **BUILT** | Added a "Mandatory handoff template" section requiring objective, discovered context, files to modify, acceptance criteria, validation commands, and out-of-scope — same shape as the brief that drove this recovery. |
| 5 | `scripts/add-project.sh`: flexible `<name> <path>` / `<path>` / reversed-arg tolerance | **SUPERSEDED** | File never existed in this repo's history. Superseded by `scripts/add.sh` (flag-based: `--name`/`--knowledge`/positional path), which already existed as WIP-uncommitted work. The two-positional reversed-arg UX doesn't apply to a flag-based interface — rejected as moot, not a regression. |
| 5a | `add.sh`: `~` expansion for input path | **BUG FOUND + BUILT** | `cd "$PROJECT_DIR"` doesn't tilde-expand an already-quoted variable, so `karen add ~/foo` would fail with `cd: no such file`. Fixed for both the positional path arg and `--knowledge`. |
| 5b | `add-project.sh`/`spawn.sh`: per-project beads dir + `BEADS_ROOT` export + defensive `bd quickstart` | **BUILT** | Considered a hub-side `$HUB_DIR/beads/$PROJECT_KEY` per the summary's literal text, but rejected it after tracing that `bootstrap.sh`/`init.sh` already use project-local `.beads/` — a separate hub-side store would fragment the task DB between the manager and the agents it spawns. Instead: `BEADS_ROOT` is exported as `$WORKDIR` (the shared project dir) in both `spawn.sh`'s bootstrap and `bootstrap.sh` itself, plus opportunistic `bd init` + defensive `bd quickstart` in both. Test: `test_spawn_bootstrap_includes_env_vars` extended with a `BEADS_ROOT` assertion. |
| 6 | `scripts/config-add-knowledge.sh` (new command + hot-reload symlink + 3-tier config precedence) | **BUILT** (precedence only) *(re-marked 2026-07-08 — human overruled the SUPERSEDED verdict below; see addendum)* | The 3-tier config precedence is now real: `resolve_karen_config()` in `lib/hub.sh` implements `$KAREN_CONFIG` > nearest workspace `.karen/config.yaml` (upward search) > global `~/.karen/config.yaml`, wired into `config.sh`/`up.sh`/`spawn.sh`. A dedicated `config-add-knowledge` command and hot-reload symlink were still not built — knowledge-dir management remains via `add.sh --knowledge` + `up.sh`'s symlinking, which doesn't need a hot-reload mechanism since it re-links on every `karen up`. |
| 7 | `scripts/init-project.sh` (`KAREN_CONFIG` + `resolve_hub_dir` support) | **BUILT** (via the new workspace ladder, not `init.sh` itself) *(re-marked 2026-07-08)* | `init.sh` itself is untouched — its project-local `$PROJECT_DIR/.agent` model still stands, and forcing `resolve_hub_dir()` into it isn't required for functional parity. Instead, a directory tree gets the equivalent project-scoped, no-hand-wiring config/hub resolution the summary wanted by dropping a `.karen/config.yaml` at its root: `resolve_hub_dir()` picks it up via the new workspace tier (below explicit `KAREN_HUB_DIR`/`KAREN_PROJECT_AGENT_DIR`, above standalone `.agent` search) and derives the hub from the config's `hub:` key or its own directory if absent. |
| 8 | `scripts/up.sh`: upward search for nearest `.karen/config.yaml` + hub-default-to-config-dir fallback | **BUILT** *(re-marked 2026-07-08)* | `up.sh` now resolves its config via `resolve_karen_config()` (an explicit `--config` flag still overrides, unchanged) and defaults the hub to that config's own directory when it declares no `hub:` key — exactly the described behavior, plus the same ladder now shared with `config.sh`/`spawn.sh`/`where.sh` instead of being `up.sh`-only. |
| 9 | `scripts/status.sh`: migrate to resolved hub dir + workspace-not-found error | **BUG FOUND + BUILT** | Was still hardcoded to `$ROOT/.agent/...` — under the central-hub model this is simply the wrong path for any project using a hub other than `$SCAFFOLD_ROOT/.agent` (i.e., almost always). Rewrote to `source lib/hub.sh` + `resolve_hub_dir()`, added `set -euo pipefail` and hard-exit when no hub resolves. Tests: `test_status_uses_resolved_hub_dir`, `test_status_fails_without_hub`. |
| 10 | `tests/test_karen.sh`: `.agent` → `.karen` path convention rename | **BUILT** (as an added workspace layer, not a rename) *(re-marked 2026-07-08)* | `.karen` naming didn't replace `.agent` — it's now the workspace-mode convention layered above it: a `.karen/config.yaml` at a directory tree's root makes it self-contained (own hub under `.karen/` by default), while `.agent`-based standalone projects and the existing central-hub model keep working unchanged. 15 new tests cover the ladder, `where.sh` reporting, `up.sh`/`config.sh` wiring, and a live two-sibling-workspace demo (below) — this is the "test realignment" the summary wanted, achieved without actually renaming the legacy convention (which would have been a regression for existing standalone users). |
| 10a | `tests/test_karen.sh`: agent-ID inbox naming (vs. `test-<role>.jsonl`) | **HEAD** (already correct) | Runtime already uses full project-prefixed agent IDs (`test-pm.jsonl` = `test` project + `pm` role, via `KAREN_PROJECT_KEY=test` in test setup) — this *is* the agent-ID convention, just with a `test` project prefix from the test harness itself. Nothing to change. |
| 10b | `tests/test_karen.sh`: pre-existing failures | **BUG FOUND + FIXED** | Before any of the above, the suite was at 111/147 passing. Root cause: WIP's model-selection feature in `spawn.sh` (`ROLE_MODEL=$(grep ... | head -1 | sed ...)`) had no `|| true` — under `set -euo pipefail`, `grep` returning no match (the common case: most roles have no `<!-- model: ... -->` directive) failed the whole pipeline and killed `spawn.sh` immediately, silently, for almost every spawn. This alone caused ~32 of the 36 failures across the spawn/reuse/symlink suites. Fixed with `|| true`. The remaining 4 failures were a stale, non-stateful mock `cmux` (didn't reflect `rename-workspace` in subsequent `list-workspaces` output, so WIP's stricter alive-check could never match) — made the mock stateful (tracks the renamed display name, clears it on `close-workspace`). Suite is now 163/163 (147 original + 16 new, see below). |
| 10c | `tests/test_karen.sh`: config-mapped project spawn test | **BUILT** | `test_spawn_workdir_from_config` — proves a project-prefixed spawn with no explicit workdir resolves from `config.yaml`, outranking `$KAREN_PROJECT_DIR`. |
| 10d | `tests/test_karen.sh`: missing-mapping / workdir-must-exist tests | **BUILT** | `test_spawn_missing_project_mapping_fails`, `test_spawn_workdir_must_exist_fails` — see item 11 below for the corresponding `spawn.sh` behavior. |
| 11 | `scripts/spawn.sh`: configured-project-path WORKDIR tier + strict error on missing mapping + WORKDIR-exists validation | **BUILT** | WORKDIR resolution is now: explicit arg > project dir looked up from `config.yaml` by `$PROJECT_KEY` > `$KAREN_PROJECT_DIR` > `pwd`. A project-prefixed agent ID that resolves to no directory via any tier now hard-fails with an actionable message instead of silently falling back to `pwd`. Resolved WORKDIR is validated to exist before proceeding. |
| 12 | `scripts/spawn.sh`: stale-tab / dead-session recovery | **HEAD/WIP** (different, arguably stronger impl) | Summary describes a `has_live_claude_process` check. Current code (accumulated across `b09adf4`, `607ebc2`, and this session's WIP) instead verifies workspace ID **and** display name together, then does a live wake-probe (`mux_send ... ping`) and kills+respawns on failure — catches zombies a pure process-existence check would miss (e.g. process alive but the pane wedged). No rebuild needed. |
| 13 | `scripts/compact-comms.sh` executable bit | **HEAD** | Already `100755` in current tree; nothing to do. |

## Reconciliation with unrelated WIP (not in the June 23 staged set)

These files had uncommitted WIP changes with no overlap in the summary — reviewed for
correctness/consistency, not for gap-filling, and left as-is per the brief ("do not
discard it, it's a later evolution"):

- `lib/mux.sh`, `scripts/msg.sh`, `scripts/wake.sh`, `scripts/heartbeat.sh` — central-hub
  plumbing, all exercised by the (now 163/163 green) test suite.
- `scripts/slack-daemon.sh`, `scripts/telegram-daemon.sh` (+ `-poll`/`-send` siblings) —
  replace the deleted `scripts/chat.sh` / `scripts/mm-watch.sh` (Mattermost). `bootstrap.sh`
  was updated in the same WIP pass to start the heartbeat daemon instead of the old
  Mattermost watcher — consistent, kept.
- `bootstrap.sh`, `init.sh`, `README.md`, `.gitignore`, `.claude/settings.json`,
  `karen-bugs.md` — unrelated hardening/doc updates, kept.
- `scripts/spawn.sh.bak-1783261501` (untracked) — a stale pre-fix snapshot of `spawn.sh`
  from an earlier edit attempt; pure cruft (the real history is in `wip-backup-2026-07-07`
  regardless). Deleted.

## Safety

All original uncommitted WIP was committed verbatim to branch `wip-backup-2026-07-07`
(commit `4acce83`) before any other git operation, then restored onto `main`'s working
tree unstaged — so this recovery is strictly additive on top of that snapshot; nothing
from the original working tree was lost.

## Validation (2026-07-07 recovery)

- `bash tests/test_karen.sh` — 163/163 passing (was 111/147 before this recovery; two
  real bugs found and fixed, see item 10b).
- `bash -n` over every `*.sh` file in the repo — clean.
- `./bin/cli.sh where` (and `karen paths` alias) — smoke-tested against a live hub.
- `./scripts/status.sh` — smoke-tested against a live hub, correctly resolves a non-default
  `$KAREN_HUB_DIR`.

## Addendum (2026-07-08): workspace support overrule

The human overruled the SUPERSEDED verdicts on items 6/7/8/10 above — workspace support
(a self-contained `.karen/config.yaml` per directory tree, upward-searched, nearest
wins) became the primary product goal, on top of this recovery. Implemented in
`lib/hub.sh` (`resolve_karen_config()` + a new tier in `resolve_hub_dir()`), wired into
`spawn.sh`/`config.sh`/`up.sh`/`where.sh`, with the central-hub and standalone-`.agent`
tiers preserved exactly (explicit `KAREN_HUB_DIR`/`KAREN_PROJECT_AGENT_DIR` always win;
the fdecareers hub the manager monitors through never touches the new tier at all).
`add.sh`/`init.sh` were deliberately left unwired — see items 5/7 above for why.

Two real bugs surfaced during this work, beyond the four gap-matrix items:
- An infinite loop in the upward-search pattern (both the new one and the pre-existing
  standalone-`.agent` one it's modeled on) when the process's cwd is stale/deleted —
  `pwd` fails, and `dirname("")`/`dirname(".")` never reach `/`. Root-caused to the test
  harness's own `teardown()` deleting `TEST_TMPDIR` without `cd`-ing away first.
- `where.sh`'s "workspace root" reported `.karen/` itself instead of the workspace's
  actual top directory; and since `$HOME` is always an ancestor, plain global-config
  usage (no workspace opted into) was mislabeled as a discovered workspace instead of
  the global fallback. Both fixed with tests before shipping.

### Validation (2026-07-08 workspace work)

- `bash tests/test_karen.sh` — 187/187 passing (24 new tests: the resolution ladder,
  `spawn.sh`/`config.sh`/`up.sh` wiring, `where.sh` reporting, the `$HOME`-boundary
  precision fix, and CLI help positioning).
- `bash -n` over every `*.sh` file in the repo — clean.
- Live two-sibling-workspace demo under `~/Documents/temp/karen-workspace-demo/`:
  `workspace-alpha` (self-contained, no `hub:` key) and `workspace-beta` (explicit
  `hub:` key) each resolve correctly and independently from nested subdirectories.
- fdecareers-hub regression re-verified unchanged after **every** commit in this stage
  (not just at the end, per the manager's explicit ask): `KAREN_HUB_DIR=.../fdecareers/.agent`
  against `status.sh`, `health.sh`, and a `msg.sh` round-trip.
