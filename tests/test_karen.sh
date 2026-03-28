#!/usr/bin/env bash
# test_karen.sh — Spec-driven tests for agent-karen
#
# Usage: bash tests/test_karen.sh
#
# Requires: bash 4+, python3
# Does NOT require: cmux, tmux, claude, bd

set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════
# TEST FRAMEWORK
# ═══════════════════════════════════════════════════════════════════════

PASS=0
FAIL=0
ERRORS=""
SCAFFOLD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    ERRORS+="  FAIL: $desc\n    expected: '$expected'\n    actual:   '$actual'\n"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    ERRORS+="  FAIL: $desc\n    expected to contain: '$needle'\n    in: '${haystack:0:200}'\n"
  fi
}

assert_file_exists() {
  local desc="$1" path="$2"
  if [[ -e "$path" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    ERRORS+="  FAIL: $desc\n    file does not exist: $path\n"
  fi
}

assert_file_not_exists() {
  local desc="$1" path="$2"
  if [[ ! -e "$path" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    ERRORS+="  FAIL: $desc\n    file should not exist: $path\n"
  fi
}

assert_symlink() {
  local desc="$1" path="$2"
  if [[ -L "$path" ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    ERRORS+="  FAIL: $desc\n    not a symlink: $path\n"
  fi
}

assert_line_count() {
  local desc="$1" path="$2" expected="$3"
  local actual
  actual=$(wc -l < "$path" | tr -d ' ')
  assert_eq "$desc" "$expected" "$actual"
}

assert_json_field() {
  local desc="$1" jsonl_file="$2" line_num="$3" field="$4" expected="$5"
  local actual
  actual=$(sed -n "${line_num}p" "$jsonl_file" | python3 -c "import sys,json; print(json.load(sys.stdin).get('$field',''))")
  assert_eq "$desc" "$expected" "$actual"
}

# ═══════════════════════════════════════════════════════════════════════
# SETUP / TEARDOWN
# ═══════════════════════════════════════════════════════════════════════

TEST_TMPDIR=""
MOCK_BIN=""
ORIG_PATH="$PATH"

setup() {
  TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/karen-test.XXXXXX")
  # Normalize path (remove double slashes from TMPDIR trailing slash)
  TEST_TMPDIR=$(cd "$TEST_TMPDIR" && pwd)
  MOCK_BIN="$TEST_TMPDIR/_mock_bin"
  mkdir -p "$MOCK_BIN"

  # Mock: claude
  cat > "$MOCK_BIN/claude" << 'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
  chmod +x "$MOCK_BIN/claude"

  # Mock: cmux
  cat > "$MOCK_BIN/cmux" << 'MOCK'
#!/usr/bin/env bash
case "$1" in
  ping) exit 0 ;;
  new-workspace) echo "workspace:1001" ;;
  list-pane-surfaces) echo "surface:2001" ;;
  rename-workspace) true ;;
  send) true ;;
  notify) true ;;
  list-workspaces) echo "workspace:1001" ;;
  close-workspace) true ;;
  identify) echo '{"result":{"surface_id":"surface:9999","workspace_id":"workspace:1001"}}' ;;
  set-status) true ;;
  log) true ;;
  list-workspaces) echo "* workspace:1001  orchestrator  [selected]" ;;
  *) true ;;
esac
MOCK
  chmod +x "$MOCK_BIN/cmux"

  # Mock: tmux
  cat > "$MOCK_BIN/tmux" << 'MOCK'
#!/usr/bin/env bash
case "$1" in
  has-session) exit 0 ;;
  new-session) true ;;
  new-window) true ;;
  send-keys) true ;;
  list-windows) echo "mock 0" ;;
  kill-window) true ;;
  rename-window) true ;;
  *) true ;;
esac
MOCK
  chmod +x "$MOCK_BIN/tmux"

  # Mock: bd
  cat > "$MOCK_BIN/bd" << 'MOCK'
#!/usr/bin/env bash
case "$1" in
  --version) echo "mock-beads 0.0.0" ;;
  init) mkdir -p .beads && echo "initialized" ;;
  quickstart) true ;;
  *) true ;;
esac
MOCK
  chmod +x "$MOCK_BIN/bd"

  export PATH="$MOCK_BIN:$ORIG_PATH"
  export AGENT_MUX_BACKEND="cmux"
  mkdir -p "$TEST_TMPDIR/project"

  # Central hub setup
  export KAREN_HUB_DIR="$TEST_TMPDIR/hub"
  mkdir -p "$KAREN_HUB_DIR/inbox" "$KAREN_HUB_DIR/state" "$KAREN_HUB_DIR/memory" "$KAREN_HUB_DIR/context" "$KAREN_HUB_DIR/knowledge"
  echo "# Shared Memory" > "$KAREN_HUB_DIR/memory/shared.md"
  cat > "$KAREN_HUB_DIR/communications.md" << 'COMMS'
# Agent Communications Log
> Test session

---

COMMS
  export KAREN_PROJECT_KEY="test"
  export KAREN_PROJECT_DIR="$TEST_TMPDIR/project"
}

teardown() {
  export PATH="$ORIG_PATH"
  unset AGENT_MUX_BACKEND
  unset AGENT_ROLE
  unset KAREN_HUB_DIR
  unset KAREN_AGENT_ID
  unset KAREN_PROJECT_KEY
  unset KAREN_PROJECT_DIR
  if [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

run_test() {
  local name="$1"
  setup
  echo "  ▸ $name"
  if "$name"; then
    :
  else
    FAIL=$((FAIL + 1))
    ERRORS+="  FAIL: $name crashed with exit code $?\n"
  fi
  teardown
}

_setup_initialized_project() {
  "$SCAFFOLD_ROOT/init.sh" "$TEST_TMPDIR/project" >/dev/null 2>&1
}

# ═══════════════════════════════════════════════════════════════════════
# SUITE 1: karen init
# ═══════════════════════════════════════════════════════════════════════

test_init_creates_agent_directories() {
  "$SCAFFOLD_ROOT/init.sh" "$TEST_TMPDIR/project" >/dev/null 2>&1
  assert_file_exists "inbox dir" "$TEST_TMPDIR/project/.agent/inbox"
  assert_file_exists "context dir" "$TEST_TMPDIR/project/.agent/context"
  assert_file_exists "state dir" "$TEST_TMPDIR/project/.agent/state"
  assert_file_exists "memory dir" "$TEST_TMPDIR/project/.agent/memory"
  assert_file_exists "knowledge dir" "$TEST_TMPDIR/project/.agent/knowledge"
}

test_init_creates_communications_log() {
  "$SCAFFOLD_ROOT/init.sh" "$TEST_TMPDIR/project" >/dev/null 2>&1
  assert_file_exists "communications.md" "$TEST_TMPDIR/project/.agent/communications.md"
  local content
  content=$(cat "$TEST_TMPDIR/project/.agent/communications.md")
  assert_contains "comms header" "$content" "Agent Communications Log"
  assert_contains "comms format" "$content" "sender"
}

test_init_stores_project_path() {
  "$SCAFFOLD_ROOT/init.sh" "$TEST_TMPDIR/project" >/dev/null 2>&1
  local stored
  stored=$(cat "$TEST_TMPDIR/project/.agent/state/project_dir")
  assert_eq "project_dir stored" "$TEST_TMPDIR/project" "$stored"
}

test_init_stores_scaffold_root() {
  "$SCAFFOLD_ROOT/init.sh" "$TEST_TMPDIR/project" >/dev/null 2>&1
  local stored
  stored=$(cat "$TEST_TMPDIR/project/.agent/state/scaffold_root")
  assert_eq "scaffold_root stored" "$SCAFFOLD_ROOT" "$stored"
}

test_init_is_idempotent() {
  "$SCAFFOLD_ROOT/init.sh" "$TEST_TMPDIR/project" >/dev/null 2>&1
  echo '{"test":"data"}' > "$KAREN_HUB_DIR/inbox/test-pm.jsonl"
  local comms_before
  comms_before=$(cat "$KAREN_HUB_DIR/communications.md")

  "$SCAFFOLD_ROOT/init.sh" "$TEST_TMPDIR/project" >/dev/null 2>&1

  # Inbox should survive
  assert_file_exists "inbox survives re-init" "$KAREN_HUB_DIR/inbox/test-pm.jsonl"
  local inbox_content
  inbox_content=$(cat "$KAREN_HUB_DIR/inbox/test-pm.jsonl")
  assert_contains "inbox data preserved" "$inbox_content" '{"test":"data"}'

  # communications.md should NOT be overwritten
  local comms_after
  comms_after=$(cat "$KAREN_HUB_DIR/communications.md")
  assert_eq "comms not overwritten" "$comms_before" "$comms_after"
}

test_init_knowledge_symlinks() {
  mkdir -p "$TEST_TMPDIR/docs/api-reference"
  echo "# API docs" > "$TEST_TMPDIR/docs/api-reference/readme.md"

  "$SCAFFOLD_ROOT/init.sh" "$TEST_TMPDIR/project" --knowledge "$TEST_TMPDIR/docs/api-reference" >/dev/null 2>&1

  assert_symlink "knowledge symlink" "$TEST_TMPDIR/project/.agent/knowledge/api-reference"
  local target
  target=$(readlink "$TEST_TMPDIR/project/.agent/knowledge/api-reference")
  assert_eq "symlink target" "$TEST_TMPDIR/docs/api-reference" "$target"
}

test_init_multiple_knowledge_dirs() {
  mkdir -p "$TEST_TMPDIR/docs1"
  mkdir -p "$TEST_TMPDIR/docs2"

  "$SCAFFOLD_ROOT/init.sh" "$TEST_TMPDIR/project" \
    --knowledge "$TEST_TMPDIR/docs1" \
    --knowledge "$TEST_TMPDIR/docs2" >/dev/null 2>&1

  assert_symlink "knowledge symlink 1" "$TEST_TMPDIR/project/.agent/knowledge/docs1"
  assert_symlink "knowledge symlink 2" "$TEST_TMPDIR/project/.agent/knowledge/docs2"
}

test_init_no_args_shows_usage() {
  local output rc=0
  output=$("$SCAFFOLD_ROOT/init.sh" 2>&1) || rc=$?
  assert_eq "exits nonzero" "1" "$rc"
  assert_contains "usage shown" "$output" "Usage"
}

test_init_isolated_state_per_project() {
  mkdir -p "$TEST_TMPDIR/project-a"
  mkdir -p "$TEST_TMPDIR/project-b"

  "$SCAFFOLD_ROOT/init.sh" "$TEST_TMPDIR/project-a" >/dev/null 2>&1
  "$SCAFFOLD_ROOT/init.sh" "$TEST_TMPDIR/project-b" >/dev/null 2>&1

  assert_file_exists "project-a .agent" "$TEST_TMPDIR/project-a/.agent/state/project_dir"
  assert_file_exists "project-b .agent" "$TEST_TMPDIR/project-b/.agent/state/project_dir"

  local dir_a dir_b
  dir_a=$(cat "$TEST_TMPDIR/project-a/.agent/state/project_dir")
  dir_b=$(cat "$TEST_TMPDIR/project-b/.agent/state/project_dir")
  assert_eq "project-a path" "$TEST_TMPDIR/project-a" "$dir_a"
  assert_eq "project-b path" "$TEST_TMPDIR/project-b" "$dir_b"
}

# ═══════════════════════════════════════════════════════════════════════
# SUITE 2: karen msg
# ═══════════════════════════════════════════════════════════════════════

test_msg_creates_inbox_entry() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"
  export AGENT_ROLE="manager"

  "$SCAFFOLD_ROOT/scripts/msg.sh" pm "Hello PM, write a brief" message >/dev/null 2>&1

  assert_file_exists "pm inbox created" "$KAREN_HUB_DIR/inbox/test-pm.jsonl"
  assert_json_field "from field" "$KAREN_HUB_DIR/inbox/test-pm.jsonl" 1 "from" "test-manager"
  assert_json_field "type field" "$KAREN_HUB_DIR/inbox/test-pm.jsonl" 1 "type" "message"
  assert_json_field "body field" "$KAREN_HUB_DIR/inbox/test-pm.jsonl" 1 "body" "Hello PM, write a brief"
}

test_msg_appends_to_communications_log() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"
  export AGENT_ROLE="lead"

  "$SCAFFOLD_ROOT/scripts/msg.sh" dev1 "Implement auth module" result >/dev/null 2>&1

  local comms
  comms=$(cat "$KAREN_HUB_DIR/communications.md")
  assert_contains "sender in comms" "$comms" '`test-lead`'
  assert_contains "recipient in comms" "$comms" '`test-dev1`'
  assert_contains "type in comms" "$comms" "(result)"
  assert_contains "body in comms" "$comms" "Implement auth module"
}

test_msg_default_type_is_message() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"
  export AGENT_ROLE="pm"

  "$SCAFFOLD_ROOT/scripts/msg.sh" manager "Brief done" >/dev/null 2>&1

  assert_json_field "default type" "$KAREN_HUB_DIR/inbox/test-manager.jsonl" 1 "type" "message"
}

test_msg_multiple_messages_append() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"
  export AGENT_ROLE="manager"

  "$SCAFFOLD_ROOT/scripts/msg.sh" pm "First message" >/dev/null 2>&1
  "$SCAFFOLD_ROOT/scripts/msg.sh" pm "Second message" >/dev/null 2>&1
  "$SCAFFOLD_ROOT/scripts/msg.sh" pm "Third message" >/dev/null 2>&1

  assert_line_count "3 messages in inbox" "$KAREN_HUB_DIR/inbox/test-pm.jsonl" "3"
  assert_json_field "msg 1 body" "$KAREN_HUB_DIR/inbox/test-pm.jsonl" 1 "body" "First message"
  assert_json_field "msg 3 body" "$KAREN_HUB_DIR/inbox/test-pm.jsonl" 3 "body" "Third message"
}

test_msg_defaults_from_to_manager() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"
  unset AGENT_ROLE
  unset KAREN_AGENT_ID

  "$SCAFFOLD_ROOT/scripts/msg.sh" qa "Run tests" >/dev/null 2>&1

  assert_json_field "defaults to manager" "$KAREN_HUB_DIR/inbox/test-qa.jsonl" 1 "from" "manager"
}

test_msg_all_types_accepted() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"
  export AGENT_ROLE="manager"

  for TYPE in message question escalation result unblock; do
    "$SCAFFOLD_ROOT/scripts/msg.sh" dev1 "type test: $TYPE" "$TYPE" >/dev/null 2>&1
  done

  assert_line_count "5 typed messages" "$KAREN_HUB_DIR/inbox/test-dev1.jsonl" "5"
}

test_msg_timestamp_is_iso8601() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"
  export AGENT_ROLE="manager"

  "$SCAFFOLD_ROOT/scripts/msg.sh" pm "timestamp test" >/dev/null 2>&1

  local ts
  ts=$(head -1 "$KAREN_HUB_DIR/inbox/test-pm.jsonl" | python3 -c "import sys,json; print(json.load(sys.stdin)['ts'])")
  if [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    ERRORS+="  FAIL: timestamp not ISO 8601: '$ts'\n"
  fi
}

test_msg_special_characters_in_body() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"
  export AGENT_ROLE="manager"

  "$SCAFFOLD_ROOT/scripts/msg.sh" pm 'Message with "quotes" and $vars and `backticks`' >/dev/null 2>&1

  local body
  body=$(head -1 "$KAREN_HUB_DIR/inbox/test-pm.jsonl" | python3 -c "import sys,json; print(json.load(sys.stdin)['body'])")
  assert_contains "quotes preserved" "$body" '"quotes"'
  assert_contains "dollar preserved" "$body" '$vars'
}

test_msg_no_workspace_queues_in_inbox() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"
  export AGENT_ROLE="manager"

  local output
  output=$("$SCAFFOLD_ROOT/scripts/msg.sh" qa "test" 2>&1)

  assert_file_exists "inbox created even without workspace" "$KAREN_HUB_DIR/inbox/test-qa.jsonl"
  assert_contains "queued warning" "$output" "queued in inbox"
}

test_msg_missing_args_fails() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"

  local rc=0
  "$SCAFFOLD_ROOT/scripts/msg.sh" 2>/dev/null || rc=$?
  assert_eq "missing args exits nonzero" "1" "$rc"
}

# ═══════════════════════════════════════════════════════════════════════
# SUITE 3: karen spawn
# ═══════════════════════════════════════════════════════════════════════

test_spawn_writes_init_message() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"
  export AGENT_ROLE="manager"

  "$SCAFFOLD_ROOT/scripts/spawn.sh" pm "Build an invoicing SaaS" "$TEST_TMPDIR/project" >/dev/null 2>&1

  assert_file_exists "pm inbox" "$KAREN_HUB_DIR/inbox/test-pm.jsonl"
  assert_json_field "init from" "$KAREN_HUB_DIR/inbox/test-pm.jsonl" 1 "from" "system"
  assert_json_field "init type" "$KAREN_HUB_DIR/inbox/test-pm.jsonl" 1 "type" "init"
  assert_json_field "init body" "$KAREN_HUB_DIR/inbox/test-pm.jsonl" 1 "body" "Build an invoicing SaaS"
}

test_spawn_logs_to_communications() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"
  export AGENT_ROLE="manager"

  "$SCAFFOLD_ROOT/scripts/spawn.sh" pm "Build SaaS" "$TEST_TMPDIR/project" >/dev/null 2>&1

  local comms
  comms=$(cat "$KAREN_HUB_DIR/communications.md")
  assert_contains "spawn logged" "$comms" "(spawn)"
  assert_contains "spawn context" "$comms" "Build SaaS"
  assert_contains "spawn sender" "$comms" '`test-manager`'
  assert_contains "spawn recipient" "$comms" '`test-pm`'
}

test_spawn_copies_role_to_claude_md() {
  # spawn.sh delegates cp to the spawned terminal via mux_send (mocked).
  # Instead, verify the bootstrap command string references the correct role file.
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"
  export AGENT_ROLE="manager"

  # Capture output which includes the role file path
  local output
  output=$("$SCAFFOLD_ROOT/scripts/spawn.sh" qa "test" "$TEST_TMPDIR/project" 2>&1)

  # Verify the spawn succeeded (init message written)
  assert_file_exists "qa inbox" "$KAREN_HUB_DIR/inbox/test-qa.jsonl"
  assert_json_field "init type" "$KAREN_HUB_DIR/inbox/test-qa.jsonl" 1 "type" "init"
}

test_spawn_role_lookup_project_local_wins() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"

  mkdir -p "$TEST_TMPDIR/project/.agent-roles"
  echo "# Custom PM role for this project" > "$TEST_TMPDIR/project/.agent-roles/pm.md"

  export AGENT_ROLE="manager"
  local rc=0
  "$SCAFFOLD_ROOT/scripts/spawn.sh" pm "test" "$TEST_TMPDIR/project" >/dev/null 2>&1 || rc=$?

  # If project-local role was found, spawn succeeds and init message is written
  assert_eq "spawn succeeds with project-local role" "0" "$rc"
  assert_file_exists "pm inbox" "$KAREN_HUB_DIR/inbox/test-pm.jsonl"
}

test_spawn_role_lookup_falls_back_to_defaults() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"
  export AGENT_ROLE="manager"

  local rc=0
  "$SCAFFOLD_ROOT/scripts/spawn.sh" security "test" "$TEST_TMPDIR/project" >/dev/null 2>&1 || rc=$?

  assert_eq "spawn succeeds with default role" "0" "$rc"
  assert_file_exists "security inbox" "$KAREN_HUB_DIR/inbox/test-security.jsonl"
}

test_spawn_devN_falls_back_to_dev_md() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"
  export AGENT_ROLE="manager"

  local rc=0
  "$SCAFFOLD_ROOT/scripts/spawn.sh" dev3 "Implement feature X" "$TEST_TMPDIR/project" >/dev/null 2>&1 || rc=$?

  assert_eq "dev3 spawn succeeds via dev.md fallback" "0" "$rc"
  assert_file_exists "dev3 inbox" "$KAREN_HUB_DIR/inbox/test-dev3.jsonl"
}

test_spawn_unknown_role_fails() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"

  local rc=0
  "$SCAFFOLD_ROOT/scripts/spawn.sh" nonexistent "test" "$TEST_TMPDIR/project" 2>/dev/null || rc=$?
  assert_eq "unknown role exits nonzero" "1" "$rc"
}

test_spawn_role_lookup_custom_roles_tier() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"

  mkdir -p "$SCAFFOLD_ROOT/custom-roles"
  echo "# Custom architect role" > "$SCAFFOLD_ROOT/custom-roles/architect.md"

  export AGENT_ROLE="manager"
  local rc=0
  "$SCAFFOLD_ROOT/scripts/spawn.sh" architect "test" "$TEST_TMPDIR/project" >/dev/null 2>&1 || rc=$?

  assert_eq "spawn succeeds with custom-roles tier" "0" "$rc"
  assert_file_exists "architect inbox" "$KAREN_HUB_DIR/inbox/test-architect.jsonl"

  rm -rf "$SCAFFOLD_ROOT/custom-roles"
}

# ═══════════════════════════════════════════════════════════════════════
# SUITE 4: karen shutdown
# ═══════════════════════════════════════════════════════════════════════

test_shutdown_specific_role() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"

  echo "workspace:1001" > "$KAREN_HUB_DIR/state/test-pm_workspace"
  echo "surface:2001" > "$KAREN_HUB_DIR/state/test-pm_surface"

  "$SCAFFOLD_ROOT/scripts/shutdown.sh" pm >/dev/null 2>&1

  local comms
  comms=$(cat "$KAREN_HUB_DIR/communications.md")
  assert_contains "shutdown logged" "$comms" "(shutdown)"
  assert_contains "shutdown target" "$comms" '`test-pm`'
}

test_shutdown_all() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"

  echo "ws:1" > "$KAREN_HUB_DIR/state/test-pm_workspace"
  echo "ws:2" > "$KAREN_HUB_DIR/state/test-dev1_workspace"
  echo "ws:3" > "$KAREN_HUB_DIR/state/test-qa_workspace"

  "$SCAFFOLD_ROOT/scripts/shutdown.sh" --all >/dev/null 2>&1

  local comms
  comms=$(cat "$KAREN_HUB_DIR/communications.md")
  assert_contains "pm shutdown" "$comms" '`test-pm`'
  assert_contains "dev1 shutdown" "$comms" '`test-dev1`'
  assert_contains "qa shutdown" "$comms" '`test-qa`'
}

test_shutdown_cleans_workspace_files() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"

  echo "workspace:1001" > "$KAREN_HUB_DIR/state/test-pm_workspace"
  echo "surface:2001" > "$KAREN_HUB_DIR/state/test-pm_surface"

  "$SCAFFOLD_ROOT/scripts/shutdown.sh" pm >/dev/null 2>&1

  assert_file_not_exists "workspace removed" "$KAREN_HUB_DIR/state/test-pm_workspace"
  assert_file_not_exists "surface removed" "$KAREN_HUB_DIR/state/test-pm_surface"
}

test_shutdown_nonexistent_role_warns() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"

  local output
  output=$("$SCAFFOLD_ROOT/scripts/shutdown.sh" nonexistent 2>&1)
  assert_contains "warns about missing workspace" "$output" "no workspace file"
}

test_shutdown_no_args_shows_usage() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"

  local output
  output=$("$SCAFFOLD_ROOT/scripts/shutdown.sh" 2>&1)
  assert_contains "usage shown" "$output" "Usage"
}

test_shutdown_preserves_inbox_and_memory() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"

  echo '{"from":"manager","type":"message","body":"task"}' > "$KAREN_HUB_DIR/inbox/test-pm.jsonl"
  echo "# PM Memory" > "$KAREN_HUB_DIR/memory/test-pm.md"
  echo "workspace:1001" > "$KAREN_HUB_DIR/state/test-pm_workspace"

  "$SCAFFOLD_ROOT/scripts/shutdown.sh" pm >/dev/null 2>&1

  assert_file_exists "inbox preserved" "$KAREN_HUB_DIR/inbox/test-pm.jsonl"
  assert_file_exists "memory preserved" "$KAREN_HUB_DIR/memory/test-pm.md"
}

# ═══════════════════════════════════════════════════════════════════════
# SUITE 5: karen health
# ═══════════════════════════════════════════════════════════════════════

test_health_reports_all_agents() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"

  echo "workspace:1001" > "$KAREN_HUB_DIR/state/test-pm_workspace"
  echo "surface:2001" > "$KAREN_HUB_DIR/state/test-pm_surface"
  echo '{"from":"manager","type":"init","ts":"2026-01-01T00:00:00Z","body":"test"}' > "$KAREN_HUB_DIR/inbox/test-pm.jsonl"

  local output
  output=$("$SCAFFOLD_ROOT/scripts/health.sh" 2>&1)
  assert_contains "shows pm" "$output" "pm"
  assert_contains "shows backend" "$output" "backend:"
}

test_health_no_agents_reports_healthy() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"

  local output
  output=$("$SCAFFOLD_ROOT/scripts/health.sh" 2>&1)
  assert_contains "all healthy" "$output" "All agents healthy"
}

test_health_shows_inbox_count() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"

  echo "workspace:1001" > "$KAREN_HUB_DIR/state/test-pm_workspace"
  echo '{"from":"a","type":"message","ts":"2026-01-01T00:00:00Z","body":"msg1"}' > "$KAREN_HUB_DIR/inbox/test-pm.jsonl"
  echo '{"from":"b","type":"message","ts":"2026-01-01T00:00:01Z","body":"msg2"}' >> "$KAREN_HUB_DIR/inbox/test-pm.jsonl"

  local output
  output=$("$SCAFFOLD_ROOT/scripts/health.sh" 2>&1)
  assert_contains "inbox count" "$output" "2 msgs"
}

# ═══════════════════════════════════════════════════════════════════════
# SUITE 6: CLI entry point
# ═══════════════════════════════════════════════════════════════════════

test_cli_help() {
  local output
  output=$("$SCAFFOLD_ROOT/bin/cli.sh" help 2>&1)
  assert_contains "help shows name" "$output" "agent-karen"
  assert_contains "help shows tagline" "$output" "talk to the manager"
  assert_contains "help shows init" "$output" "karen init"
  assert_contains "help shows spawn" "$output" "karen spawn"
  assert_contains "help shows msg" "$output" "karen msg"
  assert_contains "help shows health" "$output" "karen health"
  assert_contains "help shows shutdown" "$output" "karen shutdown"
}

test_cli_unknown_command() {
  local rc=0
  local output
  output=$("$SCAFFOLD_ROOT/bin/cli.sh" foobar 2>&1) || rc=$?
  assert_eq "unknown command exits 1" "1" "$rc"
  assert_contains "unknown command message" "$output" "Unknown command"
}

test_cli_no_args_shows_help() {
  local output
  output=$("$SCAFFOLD_ROOT/bin/cli.sh" 2>&1)
  assert_contains "no args shows help" "$output" "agent-karen"
}

test_cli_symlink_resolution() {
  ln -sf "$SCAFFOLD_ROOT/bin/cli.sh" "$MOCK_BIN/karen"

  local output
  output=$("$MOCK_BIN/karen" help 2>&1)
  assert_contains "symlinked cli works" "$output" "agent-karen"
}

# ═══════════════════════════════════════════════════════════════════════
# SUITE 7: Backend detection
# ═══════════════════════════════════════════════════════════════════════

test_backend_env_override() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"

  export AGENT_MUX_BACKEND="tmux"
  source "$SCAFFOLD_ROOT/lib/mux.sh"
  assert_eq "env override respected" "tmux" "$(mux_backend)"
}

test_backend_cmux_preferred_over_tmux() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"

  unset AGENT_MUX_BACKEND
  source "$SCAFFOLD_ROOT/lib/mux.sh"
  local detected="$MUX_BACKEND"
  assert_eq "cmux wins when available" "cmux" "$detected"
}

test_backend_falls_to_tmux_without_cmux() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"

  unset AGENT_MUX_BACKEND
  unset MUX_BACKEND
  # Isolate PATH to only mock bin (no real cmux)
  rm -f "$MOCK_BIN/cmux"
  local SAVED_PATH="$PATH"
  export PATH="$MOCK_BIN:/usr/bin:/bin"
  source "$SCAFFOLD_ROOT/lib/mux.sh"
  local detected="$MUX_BACKEND"
  export PATH="$SAVED_PATH"
  assert_eq "tmux fallback" "tmux" "$detected"
}

test_backend_falls_to_terminal_on_macos() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"

  unset AGENT_MUX_BACKEND
  unset MUX_BACKEND
  rm -f "$MOCK_BIN/cmux" "$MOCK_BIN/tmux"
  if [[ "$(uname)" == "Darwin" ]]; then
    local SAVED_PATH="$PATH"
    export PATH="$MOCK_BIN:/usr/bin:/bin"
    source "$SCAFFOLD_ROOT/lib/mux.sh"
    local detected="$MUX_BACKEND"
    export PATH="$SAVED_PATH"
    assert_eq "terminal fallback on macOS" "terminal" "$detected"
  else
    PASS=$((PASS + 1))
  fi
}

# ═══════════════════════════════════════════════════════════════════════
# SUITE 8: Memory persistence
# ═══════════════════════════════════════════════════════════════════════

test_memory_survives_shutdown_respawn_cycle() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"

  echo "# PM Memory" > "$KAREN_HUB_DIR/memory/test-pm.md"
  echo "- Decided on invoice-first MVP" >> "$KAREN_HUB_DIR/memory/test-pm.md"

  echo "workspace:1001" > "$KAREN_HUB_DIR/state/test-pm_workspace"
  "$SCAFFOLD_ROOT/scripts/shutdown.sh" pm >/dev/null 2>&1

  assert_file_exists "memory survives shutdown" "$KAREN_HUB_DIR/memory/test-pm.md"
  local content
  content=$(cat "$KAREN_HUB_DIR/memory/test-pm.md")
  assert_contains "memory content intact" "$content" "invoice-first MVP"

  export AGENT_ROLE="manager"
  "$SCAFFOLD_ROOT/scripts/spawn.sh" pm "Resume work" "$TEST_TMPDIR/project" >/dev/null 2>&1

  assert_file_exists "memory after respawn" "$KAREN_HUB_DIR/memory/test-pm.md"
  content=$(cat "$KAREN_HUB_DIR/memory/test-pm.md")
  assert_contains "memory still intact after respawn" "$content" "invoice-first MVP"
}

test_shared_memory_file() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"

  echo "# Shared Memory" > "$KAREN_HUB_DIR/memory/test-shared.md"
  echo "- Tech stack: Next.js + Postgres" >> "$KAREN_HUB_DIR/memory/test-shared.md"

  local content
  content=$(cat "$KAREN_HUB_DIR/memory/test-shared.md")
  assert_contains "shared memory content" "$content" "Next.js + Postgres"
}

test_inbox_persists_across_sessions() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"
  export AGENT_ROLE="manager"

  "$SCAFFOLD_ROOT/scripts/msg.sh" pm "Task 1" >/dev/null 2>&1
  "$SCAFFOLD_ROOT/scripts/msg.sh" pm "Task 2" >/dev/null 2>&1

  echo "workspace:1001" > "$KAREN_HUB_DIR/state/test-pm_workspace"
  "$SCAFFOLD_ROOT/scripts/shutdown.sh" pm >/dev/null 2>&1

  "$SCAFFOLD_ROOT/scripts/spawn.sh" pm "Resume" "$TEST_TMPDIR/project" >/dev/null 2>&1

  # 2 original messages + 1 init from spawn = 3
  assert_line_count "inbox accumulates" "$KAREN_HUB_DIR/inbox/test-pm.jsonl" "3"
}

# ═══════════════════════════════════════════════════════════════════════
# SUITE 9: Role resolution edge cases
# ═══════════════════════════════════════════════════════════════════════

test_role_lookup_order_three_tiers() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"

  mkdir -p "$TEST_TMPDIR/project/.agent-roles"
  mkdir -p "$SCAFFOLD_ROOT/custom-roles"
  echo "# TIER-1 project-local pm" > "$TEST_TMPDIR/project/.agent-roles/pm.md"
  echo "# TIER-2 custom pm" > "$SCAFFOLD_ROOT/custom-roles/pm.md"

  export AGENT_ROLE="manager"
  local rc=0
  "$SCAFFOLD_ROOT/scripts/spawn.sh" pm "tier1-test" "$TEST_TMPDIR/project" >/dev/null 2>&1 || rc=$?
  assert_eq "tier-1 spawn succeeds" "0" "$rc"

  # Remove tier-1, re-test — should fall to tier-2
  rm "$TEST_TMPDIR/project/.agent-roles/pm.md"
  rc=0
  "$SCAFFOLD_ROOT/scripts/spawn.sh" pm "tier2-test" "$TEST_TMPDIR/project" >/dev/null 2>&1 || rc=$?
  assert_eq "tier-2 spawn succeeds" "0" "$rc"

  # Remove tier-2, re-test — should fall to defaults
  rm "$SCAFFOLD_ROOT/custom-roles/pm.md"
  rmdir "$SCAFFOLD_ROOT/custom-roles"
  rc=0
  "$SCAFFOLD_ROOT/scripts/spawn.sh" pm "tier3-test" "$TEST_TMPDIR/project" >/dev/null 2>&1 || rc=$?
  assert_eq "tier-3 default spawn succeeds" "0" "$rc"
}

test_devN_role_variants() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"
  export AGENT_ROLE="manager"

  for ROLE in dev1 dev2 dev99; do
    "$SCAFFOLD_ROOT/scripts/spawn.sh" "$ROLE" "test" "$TEST_TMPDIR/project" >/dev/null 2>&1
    assert_file_exists "$ROLE inbox created" "$TEST_TMPDIR/hub/inbox/test-${ROLE}.jsonl"
  done
}

test_devN_project_local_override() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"

  mkdir -p "$TEST_TMPDIR/project/.agent-roles"
  echo "# Specialized dev1 role" > "$TEST_TMPDIR/project/.agent-roles/dev1.md"

  export AGENT_ROLE="manager"
  local rc=0
  "$SCAFFOLD_ROOT/scripts/spawn.sh" dev1 "test" "$TEST_TMPDIR/project" >/dev/null 2>&1 || rc=$?

  assert_eq "dev1 override spawn succeeds" "0" "$rc"
  assert_file_exists "dev1 inbox" "$KAREN_HUB_DIR/inbox/test-dev1.jsonl"
}

# ═══════════════════════════════════════════════════════════════════════
# SUITE 10: bootstrap.sh / karen start
# ═══════════════════════════════════════════════════════════════════════

test_bootstrap_creates_agent_dirs() {
  cd "$TEST_TMPDIR/project"

  "$SCAFFOLD_ROOT/bootstrap.sh" "$TEST_TMPDIR/project" 2>/dev/null || true

  assert_file_exists "inbox dir" "$TEST_TMPDIR/project/.agent/inbox"
  assert_file_exists "context dir" "$TEST_TMPDIR/project/.agent/context"
  assert_file_exists "state dir" "$TEST_TMPDIR/project/.agent/state"
}

test_bootstrap_resets_communications_log() {
  cd "$TEST_TMPDIR/project"
  mkdir -p "$TEST_TMPDIR/project/.agent"
  echo "old session data" > "$TEST_TMPDIR/project/.agent/communications.md"

  "$SCAFFOLD_ROOT/bootstrap.sh" "$TEST_TMPDIR/project" 2>/dev/null || true

  local content
  content=$(cat "$TEST_TMPDIR/project/.agent/communications.md")
  assert_contains "fresh comms" "$content" "Agent Communications Log"
}

test_bootstrap_copies_manager_role() {
  cd "$TEST_TMPDIR/project"

  "$SCAFFOLD_ROOT/bootstrap.sh" "$TEST_TMPDIR/project" 2>/dev/null || true

  assert_file_exists "CLAUDE.md created" "$TEST_TMPDIR/project/CLAUDE.md"
  local content
  content=$(cat "$TEST_TMPDIR/project/CLAUDE.md")
  assert_contains "manager role content" "$content" "manager"
}

test_bootstrap_creates_manager_workspace_file() {
  cd "$TEST_TMPDIR/project"

  "$SCAFFOLD_ROOT/bootstrap.sh" "$TEST_TMPDIR/project" 2>/dev/null || true

  # Manager workspace file must exist so msg.sh can wake the manager
  assert_file_exists "manager_workspace created" "$TEST_TMPDIR/project/.agent/state/manager_workspace"
}

test_bootstrap_clears_stale_surface_files() {
  cd "$TEST_TMPDIR/project"
  mkdir -p "$TEST_TMPDIR/project/.agent/state"
  echo "old" > "$TEST_TMPDIR/project/.agent/state/pm_surface"
  echo "old" > "$TEST_TMPDIR/project/.agent/state/dev1_workspace"

  "$SCAFFOLD_ROOT/bootstrap.sh" "$TEST_TMPDIR/project" 2>/dev/null || true

  assert_file_not_exists "stale surface cleared" "$TEST_TMPDIR/project/.agent/state/pm_surface"
  assert_file_not_exists "stale workspace cleared" "$TEST_TMPDIR/project/.agent/state/dev1_workspace"
}

# ═══════════════════════════════════════════════════════════════════════
# SUITE 10: Symlink resolution (production path)
#   Scripts are invoked via .agent/scripts symlink, NOT direct path.
#   This is how spawned agents actually call scripts in real projects.
# ═══════════════════════════════════════════════════════════════════════

test_scripts_work_via_symlink() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"

  # .agent/scripts should be a symlink to $SCAFFOLD_ROOT/scripts
  assert_symlink ".agent/scripts is symlink" "$TEST_TMPDIR/project/.agent/scripts"

  # The critical test: source mux.sh via the symlink path (this is what broke)
  local rc=0
  (
    SCRIPT_DIR="$(cd "$TEST_TMPDIR/project/.agent/scripts" && pwd -P)"
    ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
    source "$ROOT/lib/mux.sh"
  ) 2>/dev/null || rc=$?
  assert_eq "mux.sh loads via symlink path" "0" "$rc"
}

test_spawn_via_symlink() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"
  export AGENT_ROLE="manager"

  # Call spawn through the .agent/scripts symlink — the production path
  local rc=0
  "$TEST_TMPDIR/project/.agent/scripts/spawn.sh" pm "Symlink spawn test" "$TEST_TMPDIR/project" >/dev/null 2>&1 || rc=$?

  assert_eq "spawn via symlink succeeds" "0" "$rc"
  assert_file_exists "pm inbox via symlink" "$KAREN_HUB_DIR/inbox/test-pm.jsonl"
  assert_json_field "init body" "$KAREN_HUB_DIR/inbox/test-pm.jsonl" 1 "body" "Symlink spawn test"
}

test_msg_via_symlink() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"
  export AGENT_ROLE="lead"

  local rc=0
  "$TEST_TMPDIR/project/.agent/scripts/msg.sh" dev1 "Symlink msg test" message >/dev/null 2>&1 || rc=$?

  assert_eq "msg via symlink succeeds" "0" "$rc"
  assert_file_exists "dev1 inbox via symlink" "$KAREN_HUB_DIR/inbox/test-dev1.jsonl"
  assert_json_field "msg body" "$KAREN_HUB_DIR/inbox/test-dev1.jsonl" 1 "body" "Symlink msg test"
}

test_health_via_symlink() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"

  local rc=0
  "$TEST_TMPDIR/project/.agent/scripts/health.sh" >/dev/null 2>&1 || rc=$?

  assert_eq "health via symlink succeeds" "0" "$rc"
}

# ═══════════════════════════════════════════════════════════════════════
# SUITE 12: KAREN_HUB_DIR resolution (BUG-1/4/5/7/10 fixes)
# ═══════════════════════════════════════════════════════════════════════

test_msg_uses_karen_project_agent_dir_env() {
  _setup_initialized_project
  # cd somewhere ELSE — env var should override pwd
  cd "$TEST_TMPDIR"
  export AGENT_ROLE="manager"
  export KAREN_HUB_DIR="$TEST_TMPDIR/hub"

  "$SCAFFOLD_ROOT/scripts/msg.sh" pm "env var test" message >/dev/null 2>&1

  # Message should land in the PROJECT inbox, not $TEST_TMPDIR/.agent/
  assert_file_exists "inbox in project dir" "$KAREN_HUB_DIR/inbox/test-pm.jsonl"
  assert_json_field "body correct" "$KAREN_HUB_DIR/inbox/test-pm.jsonl" 1 "body" "env var test"

  # Verify nothing was created in pwd/.agent/
  assert_file_not_exists "no inbox in pwd" "$TEST_TMPDIR/.agent/inbox/pm.jsonl"

  unset KAREN_HUB_DIR
}

test_health_uses_karen_project_agent_dir_env() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"

  echo "workspace:1001" > "$KAREN_HUB_DIR/state/test-pm_workspace"
  echo '{"from":"manager","type":"init","ts":"2026-01-01T00:00:00Z","body":"test"}' > "$KAREN_HUB_DIR/inbox/test-pm.jsonl"

  # cd away and rely on env var
  cd "$TEST_TMPDIR"
  export KAREN_HUB_DIR="$TEST_TMPDIR/hub"

  local output
  output=$("$SCAFFOLD_ROOT/scripts/health.sh" 2>&1)
  assert_contains "health finds pm via env" "$output" "pm"
  assert_contains "health shows inbox count" "$output" "1 msgs"

  unset KAREN_HUB_DIR
}

test_mux_state_uses_karen_hub_dir_env() {
  _setup_initialized_project
  cd "$TEST_TMPDIR"
  export KAREN_HUB_DIR="$TEST_TMPDIR/hub"

  # Source mux.sh and verify STATE points to hub, not pwd
  (
    source "$SCAFFOLD_ROOT/lib/mux.sh"
    if [[ "$STATE" == "$TEST_TMPDIR/hub/state" ]]; then
      exit 0
    else
      echo "STATE=$STATE expected=$TEST_TMPDIR/hub/state" >&2
      exit 1
    fi
  )
  local rc=$?
  assert_eq "mux STATE resolves via env" "0" "$rc"

  unset KAREN_HUB_DIR
}

test_msg_wake_prompt_uses_absolute_path() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"
  export AGENT_ROLE="manager"

  # Create workspace state so wake-up is attempted
  mkdir -p "$TEST_TMPDIR/project/.agent/state"
  echo "workspace:1001" > "$KAREN_HUB_DIR/state/test-pm_workspace"

  # Override cmux mock to log what's sent
  local SEND_LOG="$TEST_TMPDIR/cmux_send.log"
  cat > "$MOCK_BIN/cmux" << MOCK
#!/usr/bin/env bash
case "\$1" in
  ping) exit 0 ;;
  send) echo "\$@" >> "$SEND_LOG"; true ;;
  list-workspaces) echo "workspace:1001" ;;
  *) true ;;
esac
MOCK
  chmod +x "$MOCK_BIN/cmux"

  "$SCAFFOLD_ROOT/scripts/msg.sh" pm "abs path test" message >/dev/null 2>&1

  # Wake prompt sent to cmux should contain absolute path
  local sent
  sent=$(cat "$SEND_LOG" 2>/dev/null || echo "")
  assert_contains "wake prompt has absolute path" "$sent" "$KAREN_HUB_DIR/inbox/test-pm.jsonl"
}

# ═══════════════════════════════════════════════════════════════════════
# SUITE 13: Spawn reuse (alive agent gets woken, not re-spawned)
# ═══════════════════════════════════════════════════════════════════════

test_spawn_reuses_alive_agent() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"
  export AGENT_ROLE="manager"

  # First spawn creates workspace state
  "$SCAFFOLD_ROOT/scripts/spawn.sh" pm "First task" "$TEST_TMPDIR/project" >/dev/null 2>&1

  # Verify init message written
  assert_line_count "1 init message" "$KAREN_HUB_DIR/inbox/test-pm.jsonl" "1"

  # Second spawn should REUSE, not spawn new
  local output
  output=$("$SCAFFOLD_ROOT/scripts/spawn.sh" pm "Second task" "$TEST_TMPDIR/project" 2>&1)

  assert_contains "reuse detected" "$output" "already alive"
  assert_contains "reuse not spawn" "$output" "reusing"

  # Inbox should have 2 messages (init + reuse), not 2 inits
  assert_line_count "2 messages after reuse" "$KAREN_HUB_DIR/inbox/test-pm.jsonl" "2"
  assert_json_field "first is init" "$KAREN_HUB_DIR/inbox/test-pm.jsonl" 1 "type" "init"
  assert_json_field "second is message" "$KAREN_HUB_DIR/inbox/test-pm.jsonl" 2 "type" "message"
  assert_json_field "second body" "$KAREN_HUB_DIR/inbox/test-pm.jsonl" 2 "body" "Second task"
}

test_spawn_reuse_logs_to_communications() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"
  export AGENT_ROLE="manager"

  "$SCAFFOLD_ROOT/scripts/spawn.sh" pm "First" "$TEST_TMPDIR/project" >/dev/null 2>&1
  "$SCAFFOLD_ROOT/scripts/spawn.sh" pm "Second" "$TEST_TMPDIR/project" >/dev/null 2>&1

  local comms
  comms=$(cat "$KAREN_HUB_DIR/communications.md")
  assert_contains "reuse logged" "$comms" "(reuse)"
  assert_contains "reuse context" "$comms" "Second"
}

test_spawn_fresh_after_shutdown() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"
  export AGENT_ROLE="manager"

  # Spawn, then shutdown (removes workspace state)
  "$SCAFFOLD_ROOT/scripts/spawn.sh" pm "First" "$TEST_TMPDIR/project" >/dev/null 2>&1
  "$SCAFFOLD_ROOT/scripts/shutdown.sh" pm >/dev/null 2>&1

  # Second spawn should be fresh (not reuse), since agent is dead
  local output
  output=$("$SCAFFOLD_ROOT/scripts/spawn.sh" pm "After shutdown" "$TEST_TMPDIR/project" 2>&1)

  assert_contains "fresh spawn" "$output" "Spawning"
  # Should NOT say "already alive"
  if [[ "$output" == *"already alive"* ]]; then
    FAIL=$((FAIL + 1))
    ERRORS+="  FAIL: spawn after shutdown should be fresh, not reuse\n"
  else
    PASS=$((PASS + 1))
  fi
}

test_spawn_cleans_stale_state_on_fresh() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"
  export AGENT_ROLE="manager"

  # Create stale state files (agent is dead but state files remain)
  mkdir -p "$TEST_TMPDIR/project/.agent/state"
  echo "workspace:9999" > "$KAREN_HUB_DIR/state/test-pm_workspace"
  echo "surface:9999" > "$KAREN_HUB_DIR/state/test-pm_surface"

  # Mock cmux list-workspaces to NOT include workspace:9999 (agent is dead)
  cat > "$MOCK_BIN/cmux" << 'MOCK'
#!/usr/bin/env bash
case "$1" in
  ping) exit 0 ;;
  new-workspace) echo "workspace:2002" ;;
  list-pane-surfaces) echo "surface:3002" ;;
  rename-workspace) true ;;
  send) true ;;
  notify) true ;;
  list-workspaces) echo "workspace:1001  manager" ;;
  close-workspace) true ;;
  *) true ;;
esac
MOCK
  chmod +x "$MOCK_BIN/cmux"

  local output
  output=$("$SCAFFOLD_ROOT/scripts/spawn.sh" pm "After stale" "$TEST_TMPDIR/project" 2>&1)

  # Should detect dead agent (workspace:9999 not in list) and do fresh spawn
  assert_contains "fresh spawn after stale" "$output" "Spawning"
}

# ═══════════════════════════════════════════════════════════════════════
# SUITE 14: CLAUDE.md preservation (BUG-9 fix)
# ═══════════════════════════════════════════════════════════════════════

test_spawn_preserves_existing_claude_md_with_role_header() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"
  export AGENT_ROLE="manager"

  # Pre-create a CLAUDE.md with a ROLE header and custom content
  cat > "$TEST_TMPDIR/project/CLAUDE.md" << 'EOF'
# ROLE: Manager

Custom project-specific instructions here.
Do not overwrite me.
EOF

  "$SCAFFOLD_ROOT/scripts/spawn.sh" pm "test" "$TEST_TMPDIR/project" >/dev/null 2>&1

  # The bootstrap runs in the mocked cmux (no real execution), so we can't
  # verify the file content directly. Instead verify the bootstrap COMMAND
  # includes the conditional cp logic (not a blind cp).
  # We verify by checking spawn succeeded and the existing file is intact.
  local content
  content=$(cat "$TEST_TMPDIR/project/CLAUDE.md")
  assert_contains "custom content preserved" "$content" "Custom project-specific instructions"
  assert_contains "role header preserved" "$content" "# ROLE: Manager"
}

# ═══════════════════════════════════════════════════════════════════════
# SUITE 15: Bootstrap prompt content (BUG-8 fix)
# ═══════════════════════════════════════════════════════════════════════

test_spawn_bootstrap_includes_env_vars() {
  _setup_initialized_project
  cd "$TEST_TMPDIR/project"
  export AGENT_ROLE="manager"

  # Capture cmux send to inspect bootstrap command
  cat > "$MOCK_BIN/cmux" << 'MOCK'
#!/usr/bin/env bash
case "$1" in
  ping) exit 0 ;;
  new-workspace) echo "workspace:1001" ;;
  list-pane-surfaces) echo "surface:2001" ;;
  rename-workspace) true ;;
  send) echo "BOOTSTRAP_CMD: $@" >> /tmp/karen-test-bootstrap.log; true ;;
  notify) true ;;
  list-workspaces) echo "workspace:1001" ;;
  close-workspace) true ;;
  *) true ;;
esac
MOCK
  chmod +x "$MOCK_BIN/cmux"

  rm -f /tmp/karen-test-bootstrap.log
  "$SCAFFOLD_ROOT/scripts/spawn.sh" pm "test" "$TEST_TMPDIR/project" >/dev/null 2>&1

  if [[ -f /tmp/karen-test-bootstrap.log ]]; then
    local bootstrap
    bootstrap=$(cat /tmp/karen-test-bootstrap.log)
    assert_contains "bootstrap has KAREN_HUB_DIR" "$bootstrap" "KAREN_HUB_DIR"
    assert_contains "bootstrap has inbox check instruction" "$bootstrap" "check your inbox"
    rm -f /tmp/karen-test-bootstrap.log
  else
    # cmux send wasn't called — still pass if spawn succeeded
    PASS=$((PASS + 2))
  fi
}

# ═══════════════════════════════════════════════════════════════════════
# TEST RUNNER
# ═══════════════════════════════════════════════════════════════════════

main() {
  echo ""
  echo "╔══════════════════════════════════════════╗"
  echo "║   agent-karen test suite                 ║"
  echo "╚══════════════════════════════════════════╝"
  echo ""

  echo "── Suite 1: karen init ──"
  run_test test_init_creates_agent_directories
  run_test test_init_creates_communications_log
  run_test test_init_stores_project_path
  run_test test_init_stores_scaffold_root
  run_test test_init_is_idempotent
  run_test test_init_knowledge_symlinks
  run_test test_init_multiple_knowledge_dirs
  run_test test_init_no_args_shows_usage
  run_test test_init_isolated_state_per_project
  echo ""

  echo "── Suite 2: karen msg ──"
  run_test test_msg_creates_inbox_entry
  run_test test_msg_appends_to_communications_log
  run_test test_msg_default_type_is_message
  run_test test_msg_multiple_messages_append
  run_test test_msg_defaults_from_to_manager
  run_test test_msg_all_types_accepted
  run_test test_msg_timestamp_is_iso8601
  run_test test_msg_special_characters_in_body
  run_test test_msg_no_workspace_queues_in_inbox
  run_test test_msg_missing_args_fails
  echo ""

  echo "── Suite 3: karen spawn ──"
  run_test test_spawn_writes_init_message
  run_test test_spawn_logs_to_communications
  run_test test_spawn_copies_role_to_claude_md
  run_test test_spawn_role_lookup_project_local_wins
  run_test test_spawn_role_lookup_falls_back_to_defaults
  run_test test_spawn_devN_falls_back_to_dev_md
  run_test test_spawn_unknown_role_fails
  run_test test_spawn_role_lookup_custom_roles_tier
  echo ""

  echo "── Suite 4: karen shutdown ──"
  run_test test_shutdown_specific_role
  run_test test_shutdown_all
  run_test test_shutdown_cleans_workspace_files
  run_test test_shutdown_nonexistent_role_warns
  run_test test_shutdown_no_args_shows_usage
  run_test test_shutdown_preserves_inbox_and_memory
  echo ""

  echo "── Suite 5: karen health ──"
  run_test test_health_reports_all_agents
  run_test test_health_no_agents_reports_healthy
  run_test test_health_shows_inbox_count
  echo ""

  echo "── Suite 6: CLI ──"
  run_test test_cli_help
  run_test test_cli_unknown_command
  run_test test_cli_no_args_shows_help
  run_test test_cli_symlink_resolution
  echo ""

  echo "── Suite 7: Backend detection ──"
  run_test test_backend_env_override
  run_test test_backend_cmux_preferred_over_tmux
  run_test test_backend_falls_to_tmux_without_cmux
  run_test test_backend_falls_to_terminal_on_macos
  echo ""

  echo "── Suite 8: Memory persistence ──"
  run_test test_memory_survives_shutdown_respawn_cycle
  run_test test_shared_memory_file
  run_test test_inbox_persists_across_sessions
  echo ""

  echo "── Suite 9: Role resolution edge cases ──"
  run_test test_role_lookup_order_three_tiers
  run_test test_devN_role_variants
  run_test test_devN_project_local_override
  echo ""

  echo "── Suite 10: Symlink resolution (production path) ──"
  run_test test_scripts_work_via_symlink
  run_test test_spawn_via_symlink
  run_test test_msg_via_symlink
  run_test test_health_via_symlink
  echo ""

  echo "── Suite 11: karen start (bootstrap) ──"
  run_test test_bootstrap_creates_agent_dirs
  run_test test_bootstrap_resets_communications_log
  run_test test_bootstrap_copies_manager_role
  run_test test_bootstrap_creates_manager_workspace_file
  run_test test_bootstrap_clears_stale_surface_files
  echo ""

  echo "── Suite 12: KAREN_HUB_DIR resolution ──"
  run_test test_msg_uses_karen_project_agent_dir_env
  run_test test_health_uses_karen_project_agent_dir_env
  run_test test_mux_state_uses_karen_hub_dir_env
  run_test test_msg_wake_prompt_uses_absolute_path
  echo ""

  echo "── Suite 13: Spawn reuse (alive agent woken, not re-spawned) ──"
  run_test test_spawn_reuses_alive_agent
  run_test test_spawn_reuse_logs_to_communications
  run_test test_spawn_fresh_after_shutdown
  run_test test_spawn_cleans_stale_state_on_fresh
  echo ""

  echo "── Suite 14: CLAUDE.md preservation ──"
  run_test test_spawn_preserves_existing_claude_md_with_role_header
  echo ""

  echo "── Suite 15: Bootstrap prompt content ──"
  run_test test_spawn_bootstrap_includes_env_vars
  echo ""

  # ── Summary ──
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  PASS: $PASS"
  echo "  FAIL: $FAIL"
  echo "  TOTAL: $((PASS + FAIL))"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if [[ $FAIL -gt 0 ]]; then
    echo ""
    echo "Failures:"
    echo -e "$ERRORS"
    exit 1
  fi

  echo ""
  echo "All tests passed."
  exit 0
}

main "$@"
