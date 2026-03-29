# Karen Bugs

Tracked bugs in the agent-karen scaffold. Fix these before next release.

---

## BUG-1: `msg.sh` writes to wrong inbox directory

**Severity:** Critical — messages between agents get lost
**File:** `scripts/msg.sh`
**Symptom:** Manager sends messages to lead, but lead never sees them. Health.sh shows the message exists (reads from scaffold inbox) but the agent reads from the project's `.agent/inbox/` which is a different directory.
**Root cause:** `msg.sh` resolves `AGENT_DIR` from its own script location (agent-scaffold root). `spawn.sh` correctly resolves to the project's `.agent/` dir. The two scripts disagree on where inbox files live.
**Partial fix applied:** Lines 22-29 now check `$(pwd)/.agent` first, but `state/` references (surface files, workspace files) still point to scaffold root. The state/inbox split across two directories causes the wake-up (`mux_send`) to fail silently while the message is written to the project inbox. Also: `communications.md` now writes to project dir but Mattermost relay and `mux_send` still use `$ROOT` for state lookups.
**Correct fix:** All scripts should use one consistent resolution strategy. Best option: env var `$KAREN_PROJECT_DIR` set by `spawn.sh` that all scripts read. This avoids `$(pwd)` fragility (agents can `cd` during work). `spawn.sh` already sets `AGENT_SCAFFOLD_ROOT` — add a parallel `KAREN_PROJECT_AGENT_DIR` that points to `$WORKDIR/.agent`.

---

## BUG-2: `cmux send` missing `\n` — text lands in input but doesn't submit

**Severity:** Medium — agents appear to message each other but recipient never processes
**File:** Role docs, any agent calling `cmux send` directly
**Symptom:** `cmux send "message" --workspace workspace:N` types the text into the terminal input but doesn't press Enter. The recipient sees the text sitting in their input field.
**Root cause:** `cmux send` requires explicit `\n` to send Enter. The scaffold's internal scripts (`lib/mux.sh`, `mm-watch.sh`) already append `$'\n'`, but agents calling `cmux send` directly don't know this.
**Fix applied:** Added `\n` requirement to lead role doc. Should be added to all role docs or (better) `mux_send` in `lib/mux.sh` should always append `\n` so callers can't forget.

---

## BUG-3: Lead role instructs blocking `while true; sleep 30` loop

**Severity:** High — makes the lead agent completely unresponsive
**File:** `roles/lead.md` (was lines 117-130)
**Symptom:** Lead runs a monitoring loop that blocks the terminal for minutes. Can't receive user input or manager messages during sleep.
**Root cause:** Role doc included a `while true; sleep 30; done` monitoring loop as a recommended pattern.
**Fix applied:** Replaced with "wait at the prompt, check on demand" in commit `a15145e`.

---

## BUG-4: `health.sh` reads inbox from scaffold dir, not project dir

**Severity:** Medium — health check shows stale/wrong message counts
**File:** `scripts/health.sh`
**Symptom:** Health.sh reports different message counts than what agents see in their inbox. Shows "45 msgs" when the project inbox file has 12 lines.
**Root cause:** Same as BUG-1. `health.sh` uses `AGENT_DIR="$ROOT"` (scaffold dir). If msg.sh was recently patched to write to project dir, health.sh still reads from the old location.
**Fix:** Apply same resolution strategy as BUG-1 fix.

---

## BUG-5: Duplicate inbox files — scaffold vs project `.agent/inbox/`

**Severity:** Critical — consequence of BUG-1
**Files:** `agent-scaffold/inbox/*.jsonl` vs `<project>/.agent/inbox/*.jsonl`
**Symptom:** Two sets of inbox files exist with different messages. Some scripts write to one, some to the other. No sync between them.
**Root cause:** `spawn.sh` creates `.agent/inbox/` in the project and writes init messages there. `msg.sh` (before partial fix) wrote to scaffold inbox. Over time the two diverge completely.
**Fix:** After BUG-1 is fixed, delete `agent-scaffold/inbox/` contents and ensure all scripts resolve to project `.agent/`. The scaffold should not have an `inbox/` directory — it should be project-only.

---

## BUG-6: `msg.sh` wake prompt tells agent to check `.agent/inbox/` but doesn't resolve full path

**Severity:** Low — cosmetic, but misleading
**File:** `scripts/msg.sh` line 69
**Symptom:** Wake prompt says "Check .agent/inbox/lead.jsonl" — agent may not know which `.agent/` to look at if they've changed directories.
**Fix:** Include the resolved absolute path in the wake prompt.

---

## BUG-11: Multi-manager namespaced roles not supported (makerpad-4my)

**Severity:** P1 — blocks running karen.local and karen.cloud managers simultaneously
**File:** Role resolution in `spawn.sh`, role files
**Symptom:** Running two Karen instances (local + cloud) causes role/inbox collisions. Both managers write to the same `manager.jsonl` inbox, same `manager_workspace` state file.
**Root cause:** Roles are flat names (`manager`, `dev1`) with no namespace. No way to distinguish `karen.local.manager` from `karen.cloud.manager`.
**Fix:** Namespace roles — e.g., `local.manager` / `cloud.manager`. Role resolution, inbox paths, state files, and health checks all need to support dotted namespaces. Spawn.sh role lookup needs prefix-aware resolution.

---

## BUG-7: `spawn.sh` sets `AGENT_SCAFFOLD_ROOT` but not a project agent dir env var

**Severity:** High — root cause of BUG-1/4/5
**File:** `scripts/spawn.sh`
**Symptom:** Spawned agents know where scaffold scripts live (`AGENT_SCAFFOLD_ROOT`) but not where the project's `.agent/` dir is. Every script that needs inbox/state/comms has to independently resolve it — and they disagree.
**Root cause:** `spawn.sh` bootstrap exports `AGENT_SCAFFOLD_ROOT` but no equivalent for the project agent directory. Scripts fall back to heuristics (`$(pwd)/.agent`, `$SCRIPT_DIR/..`).
**Fix:** Add `export KAREN_PROJECT_AGENT_DIR="$WORKDIR/.agent"` to the bootstrap command in spawn.sh. Update msg.sh, health.sh, and all other scripts to use this instead of resolving their own paths.

---

## BUG-8: Agents exit after completing first task — no inbox poll loop

**Severity:** High — agents do one task and die
**File:** All role docs, spawn.sh bootstrap
**Symptom:** Agent completes assigned work, sends result via msg.sh, then exits (Claude Code session ends). It never checks inbox for follow-up tasks. Lead has to respawn instead of reuse.
**Root cause:** The bootstrap prompt says "Begin working immediately" but doesn't say "after completing work, check inbox for new tasks before exiting." Agents have no reason to stay alive.
**Fix:** Add to bootstrap prompt: "After completing your current task, check your inbox for new messages. If inbox is empty, wait at the prompt for 60 seconds before exiting. Report to your coordinator that you're idle and available." Also consider adding a PostToolUse hook or session-end hook that checks inbox.

---

## BUG-9: `spawn.sh` copies role file over project CLAUDE.md destructively

**Severity:** Medium — project CLAUDE.md gets overwritten on every spawn
**File:** `scripts/spawn.sh` line 87
**Symptom:** `cp "$ROLE_FILE" CLAUDE.md` overwrites whatever CLAUDE.md was in the project directory. If the manager's CLAUDE.md had project-specific instructions, they're replaced by the role template.
**Root cause:** `spawn.sh` assumes CLAUDE.md is disposable and belongs to the role. But for the manager workspace (workspace:1), CLAUDE.md may have been customized.
**Fix:** Only copy role file if the agent is spawning in a NEW workspace. For the manager workspace (or any workspace being reused), append role instructions or use a separate `.claude/CLAUDE.md` instead.

---

## BUG-10: `health.sh` reports "No workspace" but agent is actually alive

**Severity:** Medium — false death reports cause unnecessary respawns
**File:** `scripts/health.sh`, `scripts/msg.sh` line 74
**Symptom:** `msg.sh` reports "⚠ No workspace for lead — message queued in inbox" but health.sh immediately after shows lead as alive in workspace:10. The "No workspace" warning is a false alarm.
**Root cause:** `msg.sh` checks `$AGENT_DIR/state/${ROLE}_workspace` file to find the workspace ID for wake-up. If state files are in scaffold dir but inbox was just redirected to project dir (BUG-1 partial fix), the workspace file isn't found even though the agent is running.
**Fix:** Resolves with BUG-7 fix — consistent dir resolution. Also: `msg.sh` should fall back to `cmux find-window` or `cmux list-workspaces | grep $ROLE` instead of relying solely on state files.

## BUG: spawn.sh resolves all dev roles to lead workspace (2026-03-28)
When spawning dev1/dev2/dev3, spawn.sh keeps resolving to workspace:19 (lead's workspace) instead of creating new workspaces. Removing state files doesn't help — the script still finds the lead workspace. This breaks multi-agent development since all tasks land in the lead's terminal. Possibly related to BUG-1 (inbox split) — the agent ID resolution is mapping dev roles to the wrong workspace.

## BUG: spawn.sh reuses wrong workspace due to loose grep match

**File:** scripts/spawn.sh line 90
**Problem:** Fallback agent detection uses `grep -qE "$AGENT_ID|$DISPLAY_NAME|$SHORT_ROLE"` against workspace list output. `$SHORT_ROLE` (e.g., "dev1") can match inside other workspace entries (e.g., a lead workspace that mentions "dev1" in its title or log). This causes spawn.sh to think the agent is alive in the wrong workspace, reusing instead of spawning fresh.
**Impact:** Agents get spawned into the wrong workspace. When that workspace dies, both agents die together.
**Fix:** Use word-boundary matching or match against workspace title only, not full output. E.g., `grep -qw "$SHORT_ROLE"` or better, match against a structured field instead of freetext grep.
**Discovered:** 2026-03-28 — lead and dev1 both ended up in workspace:19
