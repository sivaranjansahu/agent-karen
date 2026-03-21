#!/usr/bin/env bash
# hooks/notify-done.sh — Claude Code hook: fires when Claude finishes a task
#
# Wire this up in your Claude Code config as a PostToolUse or Stop hook.
# See: https://cmux.com/docs/notifications#claude-code-hooks
#
# Example .claude/settings.json hook entry:
# {
#   "hooks": {
#     "Stop": [{ "type": "command", "command": "./hooks/notify-done.sh" }]
#   }
# }

ROLE="${AGENT_ROLE:-agent}"
cmux notify \
  --title "✓ $ROLE done" \
  --body  "Check inbox or terminal for results"

cmux log --level success "$ROLE: task complete"
