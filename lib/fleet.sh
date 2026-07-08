#!/usr/bin/env bash
# fleet.sh — detection functions for the karen fleet-monitoring poller
#
# Source this from scripts/fleet-poller.sh (or tests). Pure detection logic,
# NO LLM calls anywhere in this file — this is the cheap, always-on layer.
# Every check function degrades gracefully: if its prerequisite (a health_url,
# a sentry_project, a repo path, Sentry credentials) is absent, it returns
# "skip" (exit 0), never a false signal. Detection is per-site and per-signal
# independent — one missing piece of instrumentation never blocks the others.

# ── Manifest parsing ──────────────────────────────────────────────────────────
# Prints eval-able FLEET_* assignments for a registry manifest's scalar fields,
# plus FLEET_CRONS_JSON (the crons list, re-encoded as a JSON string) for
# callers that need to iterate it. Mirrors up.sh's own
# `eval "$(python3 -c ...)"` convention for YAML-to-bash-vars.
fleet_parse_manifest() {
  local manifest_path="$1"
  python3 -c "
import yaml, json

with open('$manifest_path') as f:
    m = yaml.safe_load(f) or {}

def esc(s):
    return str(s).replace('\\\\', '\\\\\\\\').replace('\"', '\\\\\"')

print(f'FLEET_NAME=\"{esc(m.get(\"name\", \"\"))}\"')
print(f'FLEET_HEALTH_URL=\"{esc(m.get(\"health_url\", \"\"))}\"')
print(f'FLEET_REPO=\"{esc(m.get(\"repo\", \"\"))}\"')
print(f'FLEET_MANAGER=\"{esc(m.get(\"manager\", \"\"))}\"')
print(f'FLEET_SENTRY_PROJECT=\"{esc(m.get(\"sentry_project\", \"\"))}\"')
print(f'FLEET_CRONS_JSON={json.dumps(json.dumps(m.get(\"crons\") or []))}')
"
}

# ── Detection: health URL probe ────────────────────────────────────────────
# Prints "skip" | "ok" | "fail:<http_code>". Returns 0 for skip/ok, 1 for fail.
fleet_check_health() {
  local url="$1"
  if [[ -z "$url" ]]; then
    echo "skip"
    return 0
  fi
  local code
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>/dev/null || echo "000")
  if [[ "$code" == "200" ]]; then
    echo "ok"
    return 0
  fi
  echo "fail:$code"
  return 1
}

# ── Detection: Sentry unresolved issues ────────────────────────────────────
# Prints "skip" | "clean" | "unresolved:<count>" | "error". Returns 1 only for
# unresolved:<count>. Skips when project/org/token isn't configured, or the
# manifest declares sentry_project: none-yet (instrumentation not live yet —
# see docs/superpowers/specs/2026-07-07-fleet-monitoring-design.md's
# "degrades gracefully" tiers).
fleet_check_sentry_issues() {
  local org="$1" project="$2" token="$3"
  if [[ -z "$org" || -z "$project" || "$project" == "none-yet" || -z "$token" ]]; then
    echo "skip"
    return 0
  fi

  local response
  if ! response=$(curl -fsS -H "Authorization: Bearer $token" \
    "https://sentry.io/api/0/projects/$org/$project/issues/?query=is%3Aunresolved&statsPeriod=24h" 2>/dev/null); then
    echo "error"
    return 0
  fi

  local count
  count=$(echo "$response" | python3 -c "
import json, sys
data = sys.stdin.read().strip()
try:
    d = json.loads(data) if data else []
except Exception:
    d = []
print(len(d) if isinstance(d, list) else 0)
" 2>/dev/null)
  count="${count:-0}"

  if [[ "$count" =~ ^[0-9]+$ ]] && [[ "$count" -gt 0 ]]; then
    echo "unresolved:$count"
    return 1
  fi
  echo "clean"
  return 0
}

# ── Detection: GitHub Actions latest run ───────────────────────────────────
# Prints "skip" | "ok" | "failed:<run_name>" | "error". Returns 1 only for
# failed:*. Runs `gh run list` FROM WITHIN the manifest's repo path (gh
# auto-detects the remote from the local git checkout — no owner/repo slug
# needed in the manifest).
fleet_check_gh_actions() {
  local repo_path="$1"
  if [[ -z "$repo_path" || ! -d "$repo_path" ]]; then
    echo "skip"
    return 0
  fi

  local response
  if ! response=$(cd "$repo_path" && gh run list --limit 1 --json conclusion,status,name,createdAt 2>/dev/null); then
    echo "error"
    return 0
  fi

  local verdict
  verdict=$(echo "$response" | python3 -c "
import json, sys
data = sys.stdin.read().strip()
try:
    runs = json.loads(data) if data else []
except Exception:
    runs = []
if not runs:
    print('ok')
else:
    run = runs[0]
    if run.get('conclusion') == 'failure':
        print('failed:' + str(run.get('name', 'unknown')))
    else:
        print('ok')
" 2>/dev/null)
  verdict="${verdict:-ok}"

  echo "$verdict"
  if [[ "$verdict" == failed:* ]]; then
    return 1
  fi
  return 0
}

# ── Detection: Sentry Crons missed-heartbeat ───────────────────────────────
# Prints "skip" | "ok" | "missed:<slug1>,<slug2>,...". Returns 1 only for
# missed:*. Skips entirely when the manifest has no sentry_project (or
# "none-yet") or no crons declared, or credentials are absent — this is the
# tier-2 "+ Sentry Crons" detection layer from the spec; fdecareers's manifest
# declares crons for future use but has no Sentry project yet, so this
# correctly no-ops for it today.
fleet_check_crons() {
  local manifest_path="$1" org="$2" token="$3"

  local sentry_project
  sentry_project=$(python3 -c "
import yaml
m = yaml.safe_load(open('$manifest_path')) or {}
print(m.get('sentry_project') or '')
" 2>/dev/null)

  if [[ -z "$sentry_project" || "$sentry_project" == "none-yet" || -z "$token" || -z "$org" ]]; then
    echo "skip"
    return 0
  fi

  local crons_json
  crons_json=$(python3 -c "
import yaml, json
m = yaml.safe_load(open('$manifest_path')) or {}
print(json.dumps(m.get('crons') or []))
" 2>/dev/null)

  if [[ -z "$crons_json" || "$crons_json" == "[]" ]]; then
    echo "skip"
    return 0
  fi

  local missed=""
  local slug grace_hours
  while IFS=$'\t' read -r slug grace_hours; do
    [[ -z "$slug" ]] && continue
    local response
    if ! response=$(curl -fsS -H "Authorization: Bearer $token" \
      "https://sentry.io/api/0/organizations/$org/monitors/$slug/checkins/?per_page=1" 2>/dev/null); then
      continue
    fi
    local verdict
    verdict=$(echo "$response" | python3 -c "
import json, sys, datetime
data = sys.stdin.read().strip()
try:
    checkins = json.loads(data) if data else []
except Exception:
    checkins = []
if not checkins:
    print('stale')
else:
    latest = checkins[0].get('dateCreated', '')
    try:
        ts = datetime.datetime.strptime(latest, '%Y-%m-%dT%H:%M:%SZ')
        age_hours = (datetime.datetime.utcnow() - ts).total_seconds() / 3600
        print('stale' if age_hours > $grace_hours else 'fresh')
    except Exception:
        print('stale')
" 2>/dev/null)
    if [[ "$verdict" == "stale" ]]; then
      missed="${missed:+$missed,}$slug"
    fi
  done < <(echo "$crons_json" | python3 -c "
import json, sys
for c in json.loads(sys.stdin.read()):
    print(f\"{c.get('slug','')}\t{c.get('grace_hours', 24)}\")
")

  if [[ -n "$missed" ]]; then
    echo "missed:$missed"
    return 1
  fi
  echo "ok"
  return 0
}

# ── Incident writing + dedupe ───────────────────────────────────────────────
# Writes an incident JSON to $fleet_dir/incidents/queue/ and prints its path.
# Dedupes: one open (queued) incident per site+signal — if one already exists,
# prints its path instead of writing a duplicate. Always returns 0; the poller
# treats "already queued" the same as "just queued" (either way, an incident
# for this site+signal is sitting in the queue for the fleet manager).
fleet_write_incident() {
  local fleet_dir="$1" site="$2" signal="$3" detail_json="${4:-{}}"
  local queue_dir="$fleet_dir/incidents/queue"
  mkdir -p "$queue_dir"

  local existing
  existing=$(python3 -c "
import json, os
queue_dir = '$queue_dir'
site = '$site'
signal = '$signal'
for fname in sorted(os.listdir(queue_dir)):
    if not fname.endswith('.json'):
        continue
    path = os.path.join(queue_dir, fname)
    try:
        with open(path) as f:
            d = json.load(f)
    except Exception:
        continue
    if d.get('site') == site and d.get('signal') == signal:
        print(path)
        break
" 2>/dev/null)

  if [[ -n "$existing" ]]; then
    echo "$existing"
    return 0
  fi

  local ts uid filepath
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  uid=$(python3 -c "import uuid; print(uuid.uuid4().hex[:8])")
  filepath="$queue_dir/$(date -u +"%Y%m%dT%H%M%SZ")-${site}-${uid}.json"

  echo "$detail_json" | python3 -c "
import json, sys
raw = sys.stdin.read().strip()
try:
    detail = json.loads(raw) if raw else {}
except Exception:
    detail = {'raw': raw}
d = {
    'id': '$uid',
    'ts': '$ts',
    'site': '$site',
    'signal': '$signal',
    'detail': detail,
    'status': 'queued',
}
with open('$filepath', 'w') as f:
    json.dump(d, f, indent=2)
"
  echo "$filepath"
  return 0
}
