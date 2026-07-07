#!/usr/bin/env bash
# status.sh — snapshot of all active agents and their inboxes
#
# Usage:
#   ./scripts/status.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

source "$ROOT/lib/hub.sh"

HUB_DIR=$(resolve_hub_dir) || exit 1

echo "╔═══════════════════════════════╗"
echo "║     Agent Status Snapshot     ║"
echo "╚═══════════════════════════════╝"
echo "  Hub: $HUB_DIR"
echo ""

# Active surfaces
echo "── Active surfaces ──────────────"
for f in "$HUB_DIR/state/"*_surface; do
  [[ -f "$f" ]] || continue
  ROLE=$(basename "$f" _surface)
  SF=$(cat "$f")
  echo "  $ROLE → surface $SF"
done
echo ""

# Inbox sizes
echo "── Inbox message counts ─────────"
for f in "$HUB_DIR/inbox/"*.jsonl; do
  [[ -f "$f" ]] || continue
  ROLE=$(basename "$f" .jsonl)
  COUNT=$(wc -l < "$f" | tr -d ' ')
  echo "  $ROLE: $COUNT messages"
done
echo ""

# Task file
if [[ -f "$HUB_DIR/state/tasks.json" ]]; then
  echo "── Tasks ────────────────────────"
  python3 -c "
import json, sys
tasks = json.load(open('$HUB_DIR/state/tasks.json'))
for t in tasks:
    icon = '✓' if t['status'] == 'done' else ('✗' if t['status'] == 'blocked' else '…')
    print(f'  {icon} [{t[\"id\"]}] {t[\"title\"]} ({t[\"assignee\"]}) — {t[\"status\"]}')
" 2>/dev/null || echo "  (could not parse tasks.json)"
  echo ""
fi

# QA report status
if [[ -f "$HUB_DIR/state/qa_report.md" ]]; then
  echo "── QA Report ────────────────────"
  grep -m1 "^## Status" "$HUB_DIR/state/qa_report.md" | sed 's/^/  /'
  echo ""
fi

# cmux sidebar log (last 10 entries)
echo "── Recent cmux log ──────────────"
cmux list-log --limit 10 2>/dev/null | sed 's/^/  /' || echo "  (cmux log unavailable)"
