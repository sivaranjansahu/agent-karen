#!/usr/bin/env bash
# msg.sh — send a message to another agent's inbox, wake its terminal,
#           and record the communication in communications.md
#
# Usage:
#   ./scripts/msg.sh <target> "<message>" [type]
#
# target: agent ID (e.g., "prepare-dev1") or short name (e.g., "dev1" — auto-prefixed with project key)
# type (optional): message | question | escalation | result | unblock
#
# Examples:
#   ./scripts/msg.sh manager "Brief complete. See context/brief.md"
#   ./scripts/msg.sh lead "QA FAIL — 2 blockers" result
#   ./scripts/msg.sh tagger-dev1 "Cross-project: need your API spec" question

set -euo pipefail

TARGET="${1:?Usage: msg.sh <target> \"<message>\" [type]}"
MSG="${2:?Usage: msg.sh <target> \"<message>\" [type]}"
TYPE="${3:-message}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

# Load hub resolution helpers
source "$ROOT/lib/hub.sh"

HUB_DIR=$(resolve_hub_dir) || exit 1
TARGET_ID=$(resolve_agent_id "$TARGET")
# Backward-compat (naming transition): resolve to whichever identity is
# ACTUALLY RUNNING right now — a hub can hold both a bare and a qualified
# inbox for the same logical agent mid-transition, and only one of them is
# live. See lib/hub.sh:resolve_live_target_id for the full rationale.
BARE_TARGET_ID=$(extract_role "$TARGET_ID")
LIVE_TARGET_ID=$(resolve_live_target_id "$TARGET_ID" "$BARE_TARGET_ID" "$HUB_DIR")
FROM=$(get_sender_id)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
TS_HUMAN=$(date "+%Y-%m-%d %H:%M:%S UTC")

INBOX="$HUB_DIR/inbox/${LIVE_TARGET_ID}.jsonl"
COMMS="$HUB_DIR/communications.md"

# Ensure inbox directory exists
mkdir -p "$HUB_DIR/inbox"

# 1. Write to inbox
MSG_JSON=$(python3 -c "import json, sys; print(json.dumps(sys.argv[1]))" "$MSG")
echo "{\"from\":\"$FROM\",\"type\":\"$TYPE\",\"ts\":\"$TIMESTAMP\",\"body\":$MSG_JSON}" >> "$INBOX"

# 2. Append to communications.md
{
  echo "## [$TS_HUMAN] \`$FROM\` → \`$LIVE_TARGET_ID\` ($TYPE)"
  echo ""
  echo "$MSG"
  echo ""
  echo "---"
  echo ""
} >> "$COMMS"

echo "▸ Logged: $FROM → $LIVE_TARGET_ID ($TYPE)"

# 3. Push-trigger: wake the target terminal
export KAREN_HUB_DIR="$HUB_DIR"
source "$ROOT/lib/mux.sh"
WS_FILE="$HUB_DIR/state/${LIVE_TARGET_ID}_workspace"
if [[ -f "$WS_FILE" ]]; then
  PROMPT="📬 New $TYPE from $FROM. Check ${HUB_DIR}/inbox/${LIVE_TARGET_ID}.jsonl and respond."
  mux_send "$LIVE_TARGET_ID" "$PROMPT" 2>/dev/null && \
    echo "✓ Woke $LIVE_TARGET_ID" || \
    echo "⚠ Send failed — message queued in inbox"
else
  # Fallback: try to find workspace via mux_list before giving up
  if mux_list 2>/dev/null | grep -q "$LIVE_TARGET_ID"; then
    echo "⚠ State file missing but $LIVE_TARGET_ID appears alive — message queued in inbox"
  else
    echo "⚠ No workspace for $LIVE_TARGET_ID — message queued in inbox"
  fi
fi

# 4. Pre-report sanity check (2026-09-02 — lawsonrep, three separate agents
#    independently reported work as shipped while it sat uncommitted in a
#    shared monorepo checkout: the actual repo root holds a dozen unrelated
#    projects and thousands of untracked files, so an uncommitted change in
#    ONE project is invisible in `git status` noise from all the others —
#    not carelessness, an unreadable instrument. The only prior "check" was
#    a paragraph in a memory file telling agents to remember; it failed
#    even for the agent who wrote it). This block only ever WARNS — see
#    the two hard rules below, both load-bearing, not to be "improved":
#
#    RULE 1 — WARN, NEVER REFUSE. Every message before this point is
#    already written to the inbox and communications.md and the wake has
#    already been attempted — this step runs last and touches none of
#    that. A guard that could block a message can strand an agent mid-
#    report with no way to escalate, which is worse than the failure this
#    prevents. Nothing below this comment may affect whether the message
#    was sent; it can only print.
#
#    RULE 2 — FAIL SAFE AND SILENT. This file is shared infra for every
#    Karen project, not lawsonrep-specific. If git is missing, the cwd
#    isn't a repo, a command errors, or anything unexpected happens at
#    all, this must produce no output and no failure — it must be
#    structurally impossible for a git surprise here to be the reason a
#    message fails to send, for ANY project on the machine. Everything
#    below runs inside one command substitution with its own relaxed
#    shell options and fully suppressed stderr, and the assignment itself
#    is guarded with `|| true` so a failing substitution can never trip
#    this script's own `set -euo pipefail`.
#
#    Scope is deliberately narrow (constraint from the ruling that asked
#    for this — "nothing cleverer"): only type=result, only when the body
#    has no commit-hash-shaped token already, only TRACKED changes (not
#    untracked — genuinely simpler, not a gap) outside .agent/, read from
#    the sender's own current directory downward (`-- .`), not the shared
#    repo root — the whole point is showing the sender their own project's
#    changes, not repeating the same unreadable, all-projects noise this
#    exists to fix. This never judges whether a hash is real or relevant;
#    it only puts the fact in front of the sender at the moment they're
#    about to claim something shipped.
if [[ "$TYPE" == "result" ]]; then
  WARN_TEXT=""
  WARN_TEXT=$(
    set +e +u
    set +o pipefail 2>/dev/null
    if ! printf '%s' "$MSG" | grep -Eq '\b[0-9a-f]{7,40}\b' 2>/dev/null; then
      if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        CHANGED=$( { git diff --name-only -- . ; git diff --name-only --cached -- . ; } 2>/dev/null )
        printf '%s\n' "$CHANGED" | grep -v '^\.agent/' | grep -v '^$'
      fi
    fi
    true
  ) 2>/dev/null || true

  if [[ -n "${WARN_TEXT:-}" ]]; then
    echo "" >&2
    echo "⚠️  WARNING: this is a 'result' message with tracked, uncommitted changes in $(pwd) and no commit hash in the body:" >&2
    echo "$WARN_TEXT" | sed 's/^/   /' >&2
    echo "   Sending anyway — this only warns, it never blocks. Standing rule: no hash, not shipped." >&2
    echo "" >&2
  fi
fi
