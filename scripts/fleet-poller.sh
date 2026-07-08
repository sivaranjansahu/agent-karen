#!/usr/bin/env bash
# fleet-poller.sh — NO-LLM detection poller for a karen fleet workspace
#
# Usage:
#   scripts/fleet-poller.sh <fleet_workspace_dir>
#
# Run periodically (via launchd — see scripts/com.karen.fleet-poller.plist,
# provided but NOT installed by this script). For each registry/<site>.yaml
# manifest in the fleet workspace: probes health_url, Sentry unresolved
# issues, GH Actions latest run, and Sentry Crons staleness — whichever the
# manifest configures. Each check independently skips if unconfigured
# (see lib/fleet.sh); detection degrades per-site, per-signal, never
# fleet-wide. On any signal: writes a deduped incident to incidents/queue/
# and wakes the fleet manager via msg.sh IF it's alive; otherwise the
# incident just sits queued. This script NEVER spawns an agent itself.
#
# Sentry credentials (SENTRY_API_TOKEN, SENTRY_ORG) come from
# ~/.karen/fleet.env (mode 600) if present — sourced, never echoed or
# logged. Their absence just means the Sentry-dependent checks skip;
# health_url and GH Actions checks still run.

set -euo pipefail

FLEET_DIR="${1:?Usage: fleet-poller.sh <fleet_workspace_dir>}"
FLEET_DIR="$(cd "$FLEET_DIR" && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"

source "$ROOT/lib/fleet.sh"

# Sentry credentials — optional, sourced from a 600-mode file outside any repo.
FLEET_ENV_FILE="${FLEET_ENV_FILE:-$HOME/.karen/fleet.env}"
SENTRY_API_TOKEN="${SENTRY_API_TOKEN:-}"
SENTRY_ORG="${SENTRY_ORG:-}"
if [[ -f "$FLEET_ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$FLEET_ENV_FILE"
fi

FLEET_MANAGER_AGENT_ID="${FLEET_MANAGER_AGENT_ID:-fleet-manager}"
REGISTRY_DIR="$FLEET_DIR/registry"
SIGNALED=0

_incident_detail_json() {
  # $1=key1 $2=val1 [$3=key2 $4=val2 ...] — small helper to build a flat JSON
  # object without re-deriving python-escaping rules at every call site.
  python3 -c "
import json, sys
args = sys.argv[1:]
d = dict(zip(args[0::2], args[1::2]))
print(json.dumps(d))
" "$@"
}

if [[ -d "$REGISTRY_DIR" ]]; then
  shopt -s nullglob
  for manifest in "$REGISTRY_DIR"/*.yaml; do
    eval "$(fleet_parse_manifest "$manifest")"
    SITE="${FLEET_NAME:-$(basename "$manifest" .yaml)}"

    HEALTH_RESULT=$(fleet_check_health "${FLEET_HEALTH_URL:-}") || true
    if [[ "$HEALTH_RESULT" == fail:* ]]; then
      DETAIL=$(_incident_detail_json health_url "${FLEET_HEALTH_URL:-}" result "$HEALTH_RESULT")
      INCIDENT=$(fleet_write_incident "$FLEET_DIR" "$SITE" "health_probe_failed" "$DETAIL")
      echo "▸ $SITE: health probe failed ($HEALTH_RESULT) — $INCIDENT"
      SIGNALED=$((SIGNALED + 1))
    fi

    SENTRY_RESULT=$(fleet_check_sentry_issues "$SENTRY_ORG" "${FLEET_SENTRY_PROJECT:-}" "$SENTRY_API_TOKEN") || true
    if [[ "$SENTRY_RESULT" == unresolved:* ]]; then
      DETAIL=$(_incident_detail_json sentry_project "${FLEET_SENTRY_PROJECT:-}" result "$SENTRY_RESULT")
      INCIDENT=$(fleet_write_incident "$FLEET_DIR" "$SITE" "sentry_unresolved_issues" "$DETAIL")
      echo "▸ $SITE: Sentry unresolved issues ($SENTRY_RESULT) — $INCIDENT"
      SIGNALED=$((SIGNALED + 1))
    fi

    GH_RESULT=$(fleet_check_gh_actions "${FLEET_REPO:-}") || true
    if [[ "$GH_RESULT" == failed:* ]]; then
      DETAIL=$(_incident_detail_json repo "${FLEET_REPO:-}" result "$GH_RESULT")
      INCIDENT=$(fleet_write_incident "$FLEET_DIR" "$SITE" "gh_actions_failed" "$DETAIL")
      echo "▸ $SITE: GH Actions failed ($GH_RESULT) — $INCIDENT"
      SIGNALED=$((SIGNALED + 1))
    fi

    CRONS_RESULT=$(fleet_check_crons "$manifest" "$SENTRY_ORG" "$SENTRY_API_TOKEN") || true
    if [[ "$CRONS_RESULT" == missed:* ]]; then
      DETAIL=$(_incident_detail_json result "$CRONS_RESULT")
      INCIDENT=$(fleet_write_incident "$FLEET_DIR" "$SITE" "cron_missed" "$DETAIL")
      echo "▸ $SITE: cron(s) missed ($CRONS_RESULT) — $INCIDENT"
      SIGNALED=$((SIGNALED + 1))
    fi
  done
fi

# Wake the fleet manager if anything signaled — msg.sh queues silently if
# the agent isn't alive, so this is safe to call unconditionally; it never
# spawns anything itself.
#
# Explicitly unset any ambient KAREN_HUB_DIR/KAREN_CONFIG/KAREN_PROJECT_AGENT_DIR
# before calling msg.sh: this script takes $FLEET_DIR as an explicit argument
# specifically so its behavior doesn't depend on the caller's environment —
# but resolve_hub_dir()'s explicit-override tier always wins over cwd-based
# workspace resolution, so an inherited KAREN_HUB_DIR (e.g. a human testing
# this by hand from an already-karen-contextualized shell) would silently
# redirect the wake to the CALLER's hub instead of this fleet workspace's own
# hub. Found via a live smoke run, not hypothetical.
if [[ "$SIGNALED" -gt 0 ]]; then
  (
    unset KAREN_HUB_DIR KAREN_CONFIG KAREN_PROJECT_AGENT_DIR
    cd "$FLEET_DIR" && \
    export KAREN_AGENT_ID="fleet-poller" && \
    "$ROOT/scripts/msg.sh" "$FLEET_MANAGER_AGENT_ID" \
      "Fleet poller: $SIGNALED new signal(s) queued. Check incidents/queue/." message
  ) >/dev/null 2>&1 || true
fi

# Poller's own heartbeat check-in (dead-man's switch) — optional, no-op if unset.
if [[ -n "${FLEET_POLLER_HEARTBEAT_URL:-}" ]]; then
  curl -fsS --max-time 10 "$FLEET_POLLER_HEARTBEAT_URL" >/dev/null 2>&1 || true
fi

echo "✓ Fleet poller run complete. $SIGNALED signal(s)."
