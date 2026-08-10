#!/usr/bin/env bash
# heartbeat.sh — monitor all agents: wake idle ones, escalate dead ones
#
# Usage:
#   heartbeat.sh [once|loop|status|stop]   # default: once
#   heartbeat.sh loop 15                    # loop every 15 seconds
#   heartbeat.sh status                     # is a daemon running for this hub?
#   heartbeat.sh stop                       # stop the running daemon for this hub
#
# Singleton: only ONE `loop` daemon may run per hub. Starting a second while one
# is alive refuses immediately (prevents the mass-tab-restore daemon leak). The
# lock is the per-hub pidfile ($HUB/state/heartbeat.pid), owned entirely by this
# script — callers (e.g. up.sh) must NOT write it themselves.
#
# What it does every tick:
# 1. Detects dead agents (workspace gone) → escalates to manager (ONCE, deduped)
#    only after re-verifying across a few retries (guards against transient
#    read failures during churn).
# 2. Detects stuck permission prompts → auto-approves with Enter
# 3. Detects idle agents at prompt with unread inbox → sends wake-up
# 4. Detects session-ended agents → escalates to manager
# 5. Manager-only, separate from 1-4 above (there's no one to escalate a dead
#    manager TO): watches for the usage-limit banner ("hit your ... limit ...
#    resets ..."), parses the reset time, and nudges the SAME workspace once
#    past it — a usage limit hangs a session, it does not kill the process,
#    so most of the time there's nothing to respawn. Only if the manager's
#    workspace is genuinely gone does this fall back to a real respawn
#    (`karen start`), guarded by a fresh liveness check immediately before
#    spawning — a duplicate manager giving conflicting instructions to
#    working devs is worse than no manager at all. If the banner is present
#    but its reset-time text doesn't match the known formats (e.g. a future
#    Claude Code release changes the wording), this fails LOUDLY — a log
#    line + a native notification — never silently. See
#    docs in aiplaybook's .agent/context/aiplaybook/manager-usage-limit-watchdog-DESIGN.md
#    for the full design rationale, including why this is zero-privilege
#    (no launchd/pmset) and its AC-power-only caveat.
#
# Tunables (env): HEARTBEAT_VERIFY_RETRIES (default 3),
#                 HEARTBEAT_VERIFY_DELAY seconds between retries (default 1).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
source "$ROOT/lib/hub.sh"

HUB_DIR=$(resolve_hub_dir) || exit 1
STATE="$HUB_DIR/state"
PID_FILE="$STATE/heartbeat.pid"
MODE="${1:-once}"
INTERVAL="${2:-15}"
VERIFY_RETRIES="${HEARTBEAT_VERIFY_RETRIES:-3}"
VERIFY_DELAY="${HEARTBEAT_VERIFY_DELAY:-1}"
SLEEP_PID=""   # pid of the current interruptible inter-tick sleep (see loop)

# ── Singleton (per-hub pidfile lock) ──────────────────────────────────────────
# Is $1 a live process that is actually one of OUR heartbeat daemons? Guards
# against a stale pidfile whose PID was reaped (zombie/defunct) or recycled to an
# unrelated process — critical because cmd_stop kills by pid, and status/acquire
# must not treat a recycled PID as a running daemon.
pid_is_live_heartbeat() {
  local pid="$1" info
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  info="$(ps -o stat=,command= -p "$pid" 2>/dev/null || true)"
  [[ -n "$info" ]] || return 1
  [[ "$info" == Z* ]] && return 1            # zombie/defunct — dead, awaiting reap
  [[ "$info" == *heartbeat.sh* ]] || return 1
  return 0
}

release_singleton() {
  local cur
  cur="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ "$cur" == "$$" ]] && rm -f "$PID_FILE"
  return 0
}

# Clean up on any exit; on a signal, clean up AND terminate. A bare `trap ... TERM`
# runs the handler then RESUMES the loop — so daemons must explicitly exit, or
# they survive TERM (the cause of pkill leaving survivors).
arm_traps() {
  trap release_singleton EXIT
  trap 'release_singleton; [[ -n "${SLEEP_PID:-}" ]] && kill "$SLEEP_PID" 2>/dev/null; exit 143' TERM
  trap 'release_singleton; [[ -n "${SLEEP_PID:-}" ]] && kill "$SLEEP_PID" 2>/dev/null; exit 130' INT
}

# Acquire the per-hub singleton or refuse. Returns 1 (and prints) if another live
# daemon already holds it. Atomic-create via noclobber; steals a stale pidfile.
acquire_singleton() {
  mkdir -p "$STATE"
  if ( set -o noclobber; echo "$$" > "$PID_FILE" ) 2>/dev/null; then
    arm_traps; return 0
  fi
  local existing
  existing="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ "$existing" == "$$" ]]; then
    arm_traps; return 0
  fi
  if pid_is_live_heartbeat "$existing"; then
    echo "[heartbeat] already running (PID $existing) — refusing to start a second daemon for this hub"
    return 1
  fi
  # Stale pidfile (no live heartbeat owner) — steal it.
  echo "$$" > "$PID_FILE"
  arm_traps; return 0
}

cmd_status() {
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if pid_is_live_heartbeat "$pid"; then
    echo "[heartbeat] running (PID $pid)"
  else
    [[ -n "$pid" ]] && rm -f "$PID_FILE"
    echo "[heartbeat] not running"
  fi
}

cmd_stop() {
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  if pid_is_live_heartbeat "$pid"; then
    kill "$pid" 2>/dev/null || true
    # Escalate to SIGKILL if it doesn't die promptly (e.g. wedged mid-tick).
    local i
    for i in $(seq 1 10); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$pid" 2>/dev/null; then kill -9 "$pid" 2>/dev/null || true; fi
    rm -f "$PID_FILE"
    echo "[heartbeat] stopped (PID $pid)"
  else
    [[ -n "$pid" ]] && rm -f "$PID_FILE"
    echo "[heartbeat] not running"
  fi
}

# ── Liveness with verify-before-escalate ──────────────────────────────────────
# Retry the screen read a few times before concluding an agent is dead, so a
# transient read failure during churn doesn't fire a false "dead" escalation.
agent_alive() {
  local ws="$1" i
  for ((i = 1; i <= VERIFY_RETRIES; i++)); do
    if cmux read-screen --workspace "$ws" --lines 1 >/dev/null 2>&1; then
      return 0
    fi
    [[ $i -lt $VERIFY_RETRIES ]] && sleep "$VERIFY_DELAY"
  done
  return 1
}

escalate() {
  # escalate <agent_id> <marker_suffix> <body>  — deduped by a per-agent marker.
  local agent_id="$1" suffix="$2" body="$3"
  local project_key="${agent_id%%-*}"
  local manager_id="${project_key}-manager"
  local marker="$STATE/${agent_id}_${suffix}"
  [[ -f "$marker" ]] && return 1   # already escalated — dedupe
  echo "{\"from\":\"heartbeat\",\"type\":\"escalation\",\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"body\":\"$body\"}" >> "$HUB_DIR/inbox/${manager_id}.jsonl"
  : > "$marker"
  return 0
}

# Parse a usage-limit banner's "resets ..." fragment into a Unix epoch.
# Handles the two documented shapes: a bare clock time ("3:45pm" — next
# occurrence, i.e. today if still ahead, else tomorrow) and a weekday+time
# ("Mon 12:00am" — next occurrence of that weekday). Prints nothing (and
# exits nonzero) on anything it doesn't recognize — the caller treats that
# as a hard parse failure, not a guess, per the "fail loud" requirement.
_parse_reset_epoch() {
  python3 -c "
import sys, re
from datetime import datetime, timedelta

text = sys.stdin.read().strip()

m = re.search(r'([0-9]{1,2}):([0-9]{2})\s*([ap]m)', text, re.I)
if not m:
    sys.exit(1)
hour, minute, ampm = int(m.group(1)), int(m.group(2)), m.group(3).lower()
if hour == 12:
    hour = 0
if ampm == 'pm':
    hour += 12

wd = re.search(r'\b(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\b', text, re.I)
now = datetime.now()
target = now.replace(hour=hour, minute=minute, second=0, microsecond=0)

if wd:
    names = ['mon','tue','wed','thu','fri','sat','sun']
    want = names.index(wd.group(1).lower())
    days_ahead = (want - now.weekday()) % 7
    target = target + timedelta(days=days_ahead)
    if days_ahead == 0 and target <= now:
        target += timedelta(days=7)
else:
    if target <= now:
        target += timedelta(days=1)

print(int(target.timestamp()))
"
}

# Manager-only watchdog — see the header comment (point 5) for why this is
# separate from the generic per-dev checks in check_agents() below.
check_manager() {
  local AGENT_ID="$1" ws_file="$2" WS_ID
  WS_ID=$(cat "$ws_file" 2>/dev/null || true)
  [[ -z "$WS_ID" ]] && return

  local RESET_FILE="$STATE/${AGENT_ID}_limit_reset_epoch"
  local PARSE_FAIL_LOG="$STATE/${AGENT_ID}_parse_failures.log"
  local RESPAWN_LOG="$STATE/${AGENT_ID}_respawn.log"

  # Case B: genuinely gone (not hung — actually gone). Guarded respawn only.
  if ! agent_alive "$WS_ID"; then
    echo "[heartbeat] ✗✗ manager ($AGENT_ID) workspace gone — verifying before respawn"
    # Re-check via the full workspace list right before acting — the
    # highest-value guard here: never let a duplicate manager exist.
    if mux_list 2>/dev/null | grep -qE "$WS_ID|$AGENT_ID"; then
      echo "[heartbeat] manager reappeared during the dead-check — not respawning"
      return
    fi
    mux_notify "Karen: manager is down" "$AGENT_ID workspace gone. Auto-respawning via karen start." 2>/dev/null || true
    local WORKDIR PROJECT_KEY
    WORKDIR="$(cd "$HUB_DIR/.." && pwd)"
    PROJECT_KEY="$(basename "$WORKDIR")"
    echo "[heartbeat] respawning manager: karen start $PROJECT_KEY (in $WORKDIR)"
    if ( cd "$WORKDIR" && mux_spawn "manager" "karen start $PROJECT_KEY" "$WORKDIR" ) >>"$RESPAWN_LOG" 2>&1; then
      echo "[heartbeat] ✓ manager respawn issued — see $RESPAWN_LOG"
    else
      echo "[heartbeat] ✗✗ manager respawn FAILED — see $RESPAWN_LOG — manual intervention needed"
      mux_notify "Karen: manager respawn FAILED" "See $RESPAWN_LOG — needs a human." 2>/dev/null || true
    fi
    rm -f "$RESET_FILE"
    return
  fi

  # Already tracking a pending reset — has it passed yet?
  if [[ -f "$RESET_FILE" ]]; then
    local RESET_EPOCH NOW
    RESET_EPOCH=$(cat "$RESET_FILE" 2>/dev/null || echo "")
    NOW=$(date +%s)
    if [[ "$RESET_EPOCH" =~ ^[0-9]+$ ]] && [[ "$NOW" -ge "$RESET_EPOCH" ]]; then
      echo "[heartbeat] ⏰ manager's usage window should have reset — nudging the same session"
      cmux send --workspace "$WS_ID" "Your usage window has reset. Resume: check your inbox and continue orchestrating." 2>/dev/null || true
      sleep 0.3
      cmux send-key --workspace "$WS_ID" "Enter" 2>/dev/null || true
      rm -f "$RESET_FILE"
    fi
    return
  fi

  # Not currently tracking anything — is the manager showing a usage-limit banner right now?
  local SCREEN
  SCREEN=$(cmux read-screen --workspace "$WS_ID" --lines 15 2>/dev/null || true)
  echo "$SCREEN" | grep -qiE "hit your .*limit" || return

  local RESET_TXT RESET_EPOCH
  RESET_TXT=$(echo "$SCREEN" | grep -oiE "resets[^·|]*" | head -1)
  RESET_EPOCH=$(printf '%s' "$RESET_TXT" | _parse_reset_epoch 2>/dev/null || true)

  if [[ -z "$RESET_EPOCH" || ! "$RESET_EPOCH" =~ ^[0-9]+$ ]]; then
    # FAIL LOUD: the banner text didn't match a known shape (format may have
    # changed) — never silently do nothing forever.
    echo "[heartbeat] ✗✗ manager shows a usage-limit banner but the reset time didn't parse: '$RESET_TXT' — logged to $PARSE_FAIL_LOG"
    { echo "$(date -u +%FT%TZ) unparsed reset text: '$RESET_TXT'"; echo "$SCREEN"; echo "---"; } >> "$PARSE_FAIL_LOG"
    mux_notify "Karen: manager usage-limit banner unparseable" "Format may have changed — see $PARSE_FAIL_LOG" 2>/dev/null || true
    return
  fi

  echo "$RESET_EPOCH" > "$RESET_FILE"
  echo "[heartbeat] manager hit a usage limit ($RESET_TXT) — will nudge the same session at epoch $RESET_EPOCH"
}

check_agents() {
  local DEAD=0
  local IDLE=0
  local WOKEN=0

  for ws_file in "$STATE"/*_workspace; do
    [[ -f "$ws_file" ]] || continue
    AGENT_ID=$(basename "$ws_file" _workspace)
    # The manager gets its own, narrower watchdog (usage-limit hang +
    # genuinely-dead respawn) — none of the generic per-dev checks below
    # (auto-approving prompts, waking on unread inbox) apply to the human's
    # own terminal.
    if [[ "$AGENT_ID" == *manager* ]]; then
      check_manager "$AGENT_ID" "$ws_file"
      continue
    fi
    # Skip agents that have been marked done
    [[ -f "$STATE/${AGENT_ID}_done" ]] && continue
    WS_ID=$(cat "$ws_file")

    # 1. Dead? (workspace gone) — verify across retries before escalating, once.
    if ! agent_alive "$WS_ID"; then
      DEAD=$((DEAD + 1))
      if escalate "$AGENT_ID" "dead_escalated" "Agent $AGENT_ID is dead (workspace $WS_ID gone). Needs respawn."; then
        echo "[heartbeat] ✗ $AGENT_ID — workspace gone (escalated)"
      else
        echo "[heartbeat] ✗ $AGENT_ID — still gone (already escalated)"
      fi
      continue
    fi
    # Recovered → clear stale escalation markers so a future death re-escalates.
    rm -f "$STATE/${AGENT_ID}_dead_escalated" "$STATE/${AGENT_ID}_session_escalated"

    # Read screen for status detection
    SCREEN=$(cmux read-screen --workspace "$WS_ID" --lines 15 2>/dev/null || true)

    # 2. Stuck on permission prompt → auto-approve
    # NOTE: match ONLY the real prompt text. Do NOT match "bypass permissions" —
    # agents running in bypass mode render a PERMANENT status footer reading
    # "⏵⏵ bypass permissions on (shift+tab to cycle)", which matched on every
    # tick for every agent, so this branch's `continue` made check 3 (idle at
    # prompt with unread inbox → wake) unreachable dead code. Observed
    # 2026-07-25: a lead sat idle 6h with 3 unread dev completion reports while
    # the daemon logged "Idle: 0, Woken: 0" every tick.
    if echo "$SCREEN" | grep -q "Do you want to proceed"; then
      echo "[heartbeat] ⚠ $AGENT_ID — stuck on permission prompt → sending Enter"
      cmux send-key --workspace "$WS_ID" "Enter" 2>/dev/null || true
      continue
    fi

    # 3. Idle at prompt with unread inbox → WAKE UP
    if echo "$SCREEN" | grep -qE "^❯\s*$|^>\s*$|waiting for input|Needs Input"; then
      INBOX="$HUB_DIR/inbox/${AGENT_ID}.jsonl"
      CURSOR_FILE="$STATE/${AGENT_ID}_inbox_cursor"

      if [[ -f "$INBOX" ]]; then
        TOTAL=$(wc -l < "$INBOX" | tr -d ' ')
        CURSOR=0
        [[ -f "$CURSOR_FILE" ]] && CURSOR=$(cat "$CURSOR_FILE")

        if [[ $TOTAL -gt $CURSOR ]]; then
          UNREAD=$((TOTAL - CURSOR))
          echo "[heartbeat] 📬 $AGENT_ID — idle at prompt with $UNREAD unread message(s) → waking"
          PROMPT="📬 You have $UNREAD unread message(s). Check $INBOX and respond."
          cmux send --workspace "$WS_ID" "$PROMPT" 2>/dev/null || true
          sleep 0.3
          cmux send-key --workspace "$WS_ID" "Enter" 2>/dev/null || true
          WOKEN=$((WOKEN + 1))
          continue
        fi
      fi

      IDLE=$((IDLE + 1))
    fi

    # 4. Session ended (API error or completed) → escalate (once, deduped)
    if echo "$SCREEN" | grep -qE "API Error|Internal server error|Sautéed for|Cooked for|Brewed for"; then
      if echo "$SCREEN" | grep -qE "^❯\s*$"; then
        IDLE=$((IDLE + 1))
        if escalate "$AGENT_ID" "session_escalated" "Agent $AGENT_ID session ended — idle at prompt. May need respawn or new task."; then
          echo "[heartbeat] ⚠ $AGENT_ID — session ended, idle at prompt (escalated)"
        fi
      fi
    fi
  done

  echo "[heartbeat] $(date -u +%H:%M:%S) — Dead: $DEAD, Idle: $IDLE, Woken: $WOKEN"
}

case "$MODE" in
  status) cmd_status ;;
  stop)   cmd_stop ;;
  loop)
    acquire_singleton || exit 1
    echo "[heartbeat] Monitoring every ${INTERVAL}s... (Ctrl+C to stop)"
    while true; do
      check_agents
      # Interruptible sleep: run it as a child and `wait`, so a TERM/INT arriving
      # mid-tick fires the trap immediately (a bare `sleep` would defer it for the
      # whole interval) and the trap reaps this child instead of orphaning it.
      sleep "$INTERVAL" &
      SLEEP_PID=$!
      wait "$SLEEP_PID" 2>/dev/null || true
    done
    ;;
  once|*) check_agents ;;
esac
