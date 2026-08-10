#!/usr/bin/env bash
# hooks/github-project-sync.sh — SessionEnd hook: push project status to the
# GitHub Project board (see scripts/github-project-sync.sh for the real work).
#
# Fires once per session end (not per turn, unlike Stop) — the right
# cadence for a status board, not a chat log. Runs the real sync
# fully in the background and always exits 0 immediately: a GitHub
# outage or a slow API call must never delay session teardown. A simple
# lockfile avoids many concurrent session-ends piling up simultaneous
# GraphQL calls against the same board.

ROOT="${AGENT_SCAFFOLD_ROOT:-}"
[[ -z "$ROOT" ]] && exit 0
[[ -x "$ROOT/scripts/github-project-sync.sh" ]] || exit 0

STATE_DIR="$ROOT/.state/github-project-sync"
LOCK_PID="$STATE_DIR/.lock.pid"
LOG="$STATE_DIR/last-run.log"
mkdir -p "$STATE_DIR"

(
  # Non-blocking, portable lock (no flock on macOS): atomic create via
  # noclobber, same convention as scripts/heartbeat.sh's singleton. If
  # another sync is already running, skip rather than queue.
  if ( set -o noclobber; echo "$$" > "$LOCK_PID" ) 2>/dev/null; then
    :
  else
    EXISTING="$(cat "$LOCK_PID" 2>/dev/null || true)"
    if [[ -n "$EXISTING" ]] && kill -0 "$EXISTING" 2>/dev/null; then
      exit 0   # a sync is genuinely still running — skip this one
    fi
    echo "$$" > "$LOCK_PID"   # stale lock (owner gone) — steal it
  fi
  trap 'rm -f "$LOCK_PID"' EXIT
  "$ROOT/scripts/github-project-sync.sh" >"$LOG" 2>&1
) &
disown 2>/dev/null || true

exit 0
