#!/usr/bin/env bash
# github-project-sync.sh — one-way sync of each Karen-managed project's status
# into ONE GitHub Project (draft items only — no repos, no Issues, no read-back).
#
# See docs/context: aiplaybook's .agent/context/aiplaybook/karen-github-project-sync.md
# for the original brief this implements.
#
# Usage:
#   github-project-sync.sh                # sync every discovered project
#   github-project-sync.sh aiplaybook lex  # sync only the named project(s)
#
# Discovery: any directory directly under $PROJECTS_ROOT (default
# ~/projects) containing a .agent/ dir is considered a Karen-managed
# project, keyed by its directory basename.
#
# Idempotency: the live board is queried for existing draft-issue titles
# each run and used as the source of truth (title == project key, unique by
# construction) — that catches drift even if a project's local id cache is
# stale, missing, or was never written (e.g. a crash right after creation).
# The id is still cached locally, under the PROJECT'S OWN
# .agent/state/github-project-sync.json, purely as a fast path.
#
# Fails safe and quiet: any precondition failure or GraphQL error is logged
# to stderr and this script exits 0 — it must never block or crash a
# session-end hook.

set -uo pipefail

PROJECTS_ROOT="${KAREN_PROJECTS_ROOT:-$HOME/projects}"
BOARD_OWNER="sivaranjansahu"
BOARD_NUMBER=3
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CACHE_DIR="$ROOT/.state/github-project-sync"
mkdir -p "$CACHE_DIR"

log() { echo "[github-project-sync] $*" >&2; }
fail_safe() { log "FAIL-SAFE: $*"; exit 0; }

# ── Preconditions (brief §4) ──────────────────────────────────────────────
command -v gh &>/dev/null || fail_safe "gh CLI not found"
command -v python3 &>/dev/null || fail_safe "python3 not found"

if ! gh auth status 2>&1 | grep -q "'project'"; then
  fail_safe "gh token missing 'project' scope — human needs to run: gh auth refresh -h github.com -s project"
fi

if ! gh project view "$BOARD_NUMBER" --owner "$BOARD_OWNER" &>/dev/null; then
  fail_safe "project $BOARD_NUMBER (owner $BOARD_OWNER) not reachable"
fi

gql() {
  # gql <query-string> [-f key=val ...]
  local query="$1"; shift
  gh api graphql -f query="$query" "$@" 2>&1
}

# ── Static IDs (project id, field ids, option maps) — cached ───────────────
IDS_FILE="$CACHE_DIR/ids.json"

resolve_ids() {
  [[ -f "$IDS_FILE" ]] && return 0
  local RESP
  RESP=$(gql '
    query($owner: String!, $number: Int!) {
      user(login: $owner) {
        projectV2(number: $number) {
          id
          fields(first: 30) {
            nodes {
              ... on ProjectV2Field { id name dataType }
              ... on ProjectV2SingleSelectField { id name dataType options { id name color description } }
            }
          }
        }
      }
    }' -F owner="$BOARD_OWNER" -F number="$BOARD_NUMBER")
  echo "$RESP" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null || {
    log "could not resolve project/field ids: $RESP"; return 1
  }
  echo "$RESP" > "$IDS_FILE"
}

field_id() { python3 -c "
import json
d=json.load(open('$IDS_FILE'))['data']['user']['projectV2']
for f in d['fields']['nodes']:
    if f['name']=='$1': print(f['id']); break
"; }

project_node_id() { python3 -c "
import json
print(json.load(open('$IDS_FILE'))['data']['user']['projectV2']['id'])
"; }

option_id() { # option_id <field-name> <option-name-case-insensitive>
  python3 -c "
import json
d=json.load(open('$IDS_FILE'))['data']['user']['projectV2']
for f in d['fields']['nodes']:
    if f['name']=='$1':
        for o in f.get('options', []):
            if o['name'].lower()=='$2'.lower():
                print(o['id']); break
"
}

# Ensure the 'Last synced' DATE field exists (brief wants an 'Updated' date
# field, but 'Updated' is already a built-in read-only auto-timestamp field —
# see karen-github-project-sync.md report for this naming deviation).
ensure_last_synced_field() {
  local fid; fid=$(field_id "Last synced")
  [[ -n "$fid" ]] && return 0
  log "creating missing 'Last synced' (DATE) field"
  local pid; pid=$(project_node_id)
  gql '
    mutation($projectId: ID!) {
      createProjectV2Field(input: {projectId: $projectId, dataType: DATE, name: "Last synced"}) {
        projectV2Field { ... on ProjectV2Field { id } }
      }
    }' -F projectId="$pid" >/dev/null
  rm -f "$IDS_FILE"; resolve_ids
}

# Ensure a Project-select option exists for $1 (project key); adds it
# without disturbing any existing option (full-list replace, existing
# ids/colors/descriptions preserved verbatim).
ensure_project_option() {
  local key="$1"
  [[ -n "$(option_id "Project" "$key")" ]] && return 0
  log "adding missing Project option: $key"
  local fid; fid=$(field_id "Project")
  local existing; existing=$(python3 -c "
import json
d=json.load(open('$IDS_FILE'))['data']['user']['projectV2']
for f in d['fields']['nodes']:
    if f['name']=='Project':
        print(json.dumps(f['options']))
")
  local new_list; new_list=$(python3 -c "
import json
opts=json.loads('''$existing''')
opts.append({'name': '$key', 'color': 'GRAY', 'description': ''})
print(json.dumps(opts))
")
  # Build the GraphQL list literal (id preserved when present, name/color/description always required)
  local gql_opts; gql_opts=$(python3 -c "
import json
opts=json.loads('''$new_list''')
parts=[]
for o in opts:
    idpart = f'id: \"{o[\"id\"]}\", ' if o.get('id') else ''
    parts.append('{' + idpart + f'name: \"{o[\"name\"]}\", color: {o[\"color\"]}, description: \"{o.get(\"description\",\"\")}\"' + '}')
print('[' + ','.join(parts) + ']')
")
  gql "
    mutation {
      updateProjectV2Field(input: {fieldId: \"$fid\", singleSelectOptions: $gql_opts}) {
        projectV2Field { ... on ProjectV2SingleSelectField { id } }
      }
    }" >/dev/null
  rm -f "$IDS_FILE"; resolve_ids
}

# ── Live item reconciliation (idempotency source of truth) ────────────────
live_items_json() {
  gql '
    query($owner: String!, $number: Int!) {
      user(login: $owner) {
        projectV2(number: $number) {
          items(first: 100) {
            nodes { id content { ... on DraftIssue { title } } }
          }
        }
      }
    }' -F owner="$BOARD_OWNER" -F number="$BOARD_NUMBER"
}

item_id_for_title() { # $1 = live items json, $2 = title
  python3 -c "
import json
d=json.loads('''$1''')['data']['user']['projectV2']['items']['nodes']
for it in d:
    c=it.get('content') or {}
    if c.get('title')=='$2':
        print(it['id']); break
"
}

# ── Per-project state gathering ────────────────────────────────────────────
gather_bd_summary() {
  local dir="$1" out
  [[ -d "$dir/.beads" ]] || { echo "(no beads db)"; return; }
  out=$(cd "$dir" && bd list 2>/dev/null | grep -v '^Info:' | head -12)
  [[ -z "$out" ]] && echo "(no open issues)" || echo "$out"
}

gather_next_action() {
  local dir="$1" out
  [[ -d "$dir/.beads" ]] || { echo "none identified"; return; }
  out=$(cd "$dir" && bd ready 2>/dev/null | grep -v '^Info:' | grep -v '^Total' | grep -v '^$' | head -1)
  [[ -z "$out" ]] && echo "none identified" || echo "$out"
}

gather_status() { # heuristic — see report for caveats
  local dir="$1" key="$2" blocked=0 open_n=0 days_since_commit bd_out
  # NOTE: '●' also appears mid-line as the priority-bullet glyph (e.g. "○ id ● P1 title") —
  # anchor to line-start so only the STATUS column (leading glyph) counts as blocked/open.
  if [[ -d "$dir/.beads" ]]; then
    bd_out=$(cd "$dir" && bd list 2>/dev/null)
    blocked=$(grep -c '^●' <<<"$bd_out")
    open_n=$(grep -c '^○\|^◐' <<<"$bd_out")
  fi
  if [[ "$blocked" -gt 0 ]]; then echo "Blocked"; return; fi
  days_since_commit=9999
  if git -C "$dir" rev-parse HEAD &>/dev/null; then
    local last_ts now
    last_ts=$(git -C "$dir" log -1 --format=%ct 2>/dev/null || echo 0)
    now=$(date +%s)
    days_since_commit=$(( (now - last_ts) / 86400 ))
  fi
  if [[ "$days_since_commit" -le 3 ]]; then echo "Active"
  elif [[ "$open_n" -eq 0 ]]; then echo "Done"
  elif [[ "$days_since_commit" -ge 14 ]]; then echo "Parked"
  else echo "Active"
  fi
}

gather_phase() {
  local dir="$1" mem_dir latest
  mem_dir="$dir/.agent/memory"
  [[ -d "$mem_dir" ]] || { echo "(no memory file)"; return; }
  latest=$(ls -t "$mem_dir"/*.md 2>/dev/null | head -1)
  [[ -z "$latest" ]] && { echo "(no memory file)"; return; }
  grep -m1 '^## ' "$latest" | sed 's/^## //'
}

gather_decisions_tail() {
  local dir="$1" key="$2" f
  f="$dir/.agent/context/$key/decisions.md"
  [[ -f "$f" ]] || { echo "(no decisions.md)"; return; }
  tail -n 25 "$f"
}

gather_git_log() {
  git -C "$1" log --oneline -8 2>/dev/null || echo "(not a git repo)"
}

build_body() {
  local dir="$1" key="$2" status="$3" phase="$4" next="$5"
  cat <<BODY
**Status:** $status
**Phase:** ${phase:-(unknown)}
**Next action:** $next

## Open issues (bd)
\`\`\`
$(gather_bd_summary "$dir")
\`\`\`

## Recent decisions
\`\`\`
$(gather_decisions_tail "$dir" "$key")
\`\`\`

## Recent commits
\`\`\`
$(gather_git_log "$dir")
\`\`\`

_synced $(date -u +%Y-%m-%dT%H:%M:%SZ)_
BODY
}

# ── Sync one project ────────────────────────────────────────────────────────
sync_project() {
  local key="$1" dir="$2" live_json="$3"
  local status phase next body item_id state_file pid
  status=$(gather_status "$dir" "$key")
  phase=$(gather_phase "$dir")
  next=$(gather_next_action "$dir")
  body=$(build_body "$dir" "$key" "$status" "$phase" "$next")
  pid=$(project_node_id)
  state_file="$dir/.agent/state/github-project-sync.json"

  item_id=$(item_id_for_title "$live_json" "$key")
  if [[ -z "$item_id" && -f "$state_file" ]]; then
    item_id=$(python3 -c "import json; print(json.load(open('$state_file')).get('itemId',''))" 2>/dev/null)
  fi

  if [[ -z "$item_id" ]]; then
    log "$key: creating new draft item"
    local resp
    resp=$(gql '
      mutation($projectId: ID!, $title: String!, $body: String!) {
        addProjectV2DraftIssue(input: {projectId: $projectId, title: $title, body: $body}) {
          projectItem { id }
        }
      }' -F projectId="$pid" -F title="$key" -F body="$body")
    item_id=$(echo "$resp" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['addProjectV2DraftIssue']['projectItem']['id'])" 2>/dev/null)
    [[ -z "$item_id" ]] && { log "$key: FAILED to create draft item: $resp"; return 1; }
  else
    log "$key: updating existing draft item ($item_id)"
    local draft_content_id
    draft_content_id=$(gql "
      query { node(id: \"$item_id\") { ... on ProjectV2Item { content { ... on DraftIssue { id } } } } }
    " | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['node']['content']['id'])" 2>/dev/null)
    gql '
      mutation($id: ID!, $title: String!, $body: String!) {
        updateProjectV2DraftIssue(input: {draftIssueId: $id, title: $title, body: $body}) { draftIssue { id } }
      }' -F id="$draft_content_id" -F title="$key" -F body="$body" >/dev/null
  fi

  mkdir -p "$(dirname "$state_file")"
  python3 -c "import json; json.dump({'itemId': '$item_id'}, open('$state_file','w'))"

  ensure_project_option "$key"
  local proj_opt status_opt
  proj_opt=$(option_id "Project" "$key")
  status_opt=$(option_id "Status" "$status")
  local proj_fid status_fid phase_fid next_fid synced_fid
  proj_fid=$(field_id "Project"); status_fid=$(field_id "Status")
  phase_fid=$(field_id "Phase"); next_fid=$(field_id "Next action")
  synced_fid=$(field_id "Last synced")
  local today; today=$(date -u +%Y-%m-%d)

  [[ -n "$proj_opt" ]] && gql "mutation { updateProjectV2ItemFieldValue(input: {projectId: \"$pid\", itemId: \"$item_id\", fieldId: \"$proj_fid\", value: {singleSelectOptionId: \"$proj_opt\"}}) { projectV2Item { id } } }" >/dev/null
  [[ -n "$status_opt" ]] && gql "mutation { updateProjectV2ItemFieldValue(input: {projectId: \"$pid\", itemId: \"$item_id\", fieldId: \"$status_fid\", value: {singleSelectOptionId: \"$status_opt\"}}) { projectV2Item { id } } }" >/dev/null
  gql '
    mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $val: String!) {
      updateProjectV2ItemFieldValue(input: {projectId: $projectId, itemId: $itemId, fieldId: $fieldId, value: {text: $val}}) { projectV2Item { id } }
    }' -F projectId="$pid" -F itemId="$item_id" -F fieldId="$phase_fid" -F val="${phase:-unknown}" >/dev/null
  gql '
    mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $val: String!) {
      updateProjectV2ItemFieldValue(input: {projectId: $projectId, itemId: $itemId, fieldId: $fieldId, value: {text: $val}}) { projectV2Item { id } }
    }' -F projectId="$pid" -F itemId="$item_id" -F fieldId="$next_fid" -F val="$next" >/dev/null
  gql "
    mutation { updateProjectV2ItemFieldValue(input: {projectId: \"$pid\", itemId: \"$item_id\", fieldId: \"$synced_fid\", value: {date: \"$today\"}}) { projectV2Item { id } } }
  " >/dev/null

  log "$key: synced (status=$status)"
}

# ── Main ─────────────────────────────────────────────────────────────────
resolve_ids || fail_safe "resolve_ids failed"
ensure_last_synced_field

TARGETS=("$@")
if [[ ${#TARGETS[@]} -eq 0 ]]; then
  for d in "$PROJECTS_ROOT"/*/; do
    [[ -d "${d}.agent" ]] && TARGETS+=("$(basename "$d")")
  done
fi

LIVE_JSON=$(live_items_json)

for key in "${TARGETS[@]}"; do
  dir="$PROJECTS_ROOT/$key"
  [[ -d "$dir" ]] || { log "$key: no such directory under $PROJECTS_ROOT, skipping"; continue; }
  sync_project "$key" "$dir" "$LIVE_JSON" || log "$key: sync failed, continuing"
done

log "done"
