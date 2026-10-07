#!/usr/bin/env bash
# hooks/notify-done.sh — Claude Code Stop hook
#
# Logs turn completion only. Does NOT shut down the workspace — reaping idle
# agents is auto-shutdown.sh's job (gated by AUTO_SHUTDOWN_MINS), which
# honors the "check inbox, stand by, exit after N idle minutes" policy every
# role's CLAUDE.md documents.
#
# Previously this hook force-closed the workspace ~2s after any `result`
# message, regardless of what the agent said (e.g. "standing by for
# follow-up"). That raced ahead of the documented idle policy and reaped
# agents before a coordinator could ever route them more work — every
# multi-step task ended up spawning fresh agents instead of reusing idle
# ones. See agent-scaffold issue: result-type messages triggered instant
# teardown even when AUTO_SHUTDOWN_MINS was unset (no grace period at all).

# Stop hooks receive JSON on stdin, including `stop_hook_active` (true when
# Claude Code is re-invoking this hook as part of its own already-blocked-turn
# retry). Nothing below is a good idea to repeat in that case — bail early.
HOOK_INPUT=$(cat 2>/dev/null || true)
if printf '%s' "$HOOK_INPUT" | grep -Eq '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
  exit 0
fi

main() {
  AGENT_ID="${KAREN_AGENT_ID:-${AGENT_ROLE:-}}"
  [[ -z "$AGENT_ID" ]] && return 0

  cmux log --level info "$AGENT_ID: response complete" 2>/dev/null || true
  return 0
}

# Never let an internal failure propagate as this hook's exit code — same
# always-exit-0 wrapper as auto-shutdown.sh, applied here for consistency
# even though this hook's own body was already low-risk.
main "$@" || true
exit 0
