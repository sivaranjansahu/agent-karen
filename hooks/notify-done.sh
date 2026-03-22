#!/usr/bin/env bash
# hooks/notify-done.sh — Claude Code Stop hook
#
# Intentionally silent. Notifications on every response are too noisy
# for multi-agent workflows. Spawn notifications are handled by spawn.sh.
#
# Uncomment below if you want per-response notifications:
# ROLE="${AGENT_ROLE:-agent}"
# cmux notify --title "✓ $ROLE done" --body "Check inbox or terminal for results" 2>/dev/null || true

# Just log silently (visible in cmux sidebar, not a popup)
ROLE="${AGENT_ROLE:-agent}"
cmux log --level info "$ROLE: response complete" 2>/dev/null || true
