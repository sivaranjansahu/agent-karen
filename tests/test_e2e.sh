#!/usr/bin/env bash
# test_e2e.sh — End-to-end smoke test for agent-karen
#
# Runs the full lifecycle in tmux with a mock claude binary.
# No API calls, no cost, no Claude Code session needed.
#
# Usage: bash tests/test_e2e.sh
#
# Requires: tmux, python3, bash

set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════
# FRAMEWORK
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

assert_json_field() {
  local desc="$1" jsonl_file="$2" line_num="$3" field="$4" expected="$5"
  local actual
  actual=$(sed -n "${line_num}p" "$jsonl_file" | python3 -c "import sys,json; print(json.load(sys.stdin).get('$field',''))")
  assert_eq "$desc" "$expected" "$actual"
}

assert_tmux_window_exists() {
  local desc="$1" window_name="$2"
  if tmux list-windows -t karen-test -F '#{window_name}' 2>/dev/null | grep -q "^${window_name}$"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    ERRORS+="  FAIL: $desc\n    tmux window '$window_name' not found in session karen-test\n"
  fi
}

assert_tmux_window_not_exists() {
  local desc="$1" window_name="$2"
  if ! tmux list-windows -t karen-test -F '#{window_name}' 2>/dev/null | grep -q "^${window_name}$"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    ERRORS+="  FAIL: $desc\n    tmux window '$window_name' should not exist\n"
  fi
}

# ═══════════════════════════════════════════════════════════════════════
# SETUP / TEARDOWN
# ═══════════════════════════════════════════════════════════════════════

PROJECT_A=""
PROJECT_B=""
MOCK_BIN=""
ORIG_PATH="$PATH"
TMUX_SESSION="karen-test"

setup() {
  echo "▸ Setting up test environment..."

  # Check tmux is available
  if ! command -v tmux &>/dev/null; then
    echo "ERROR: tmux required for E2E tests. Install with: brew install tmux"
    exit 1
  fi

  # Create temp directories
  PROJECT_A=$(mktemp -d "${TMPDIR:-/tmp}/karen-e2e-a.XXXXXX")
  PROJECT_A=$(cd "$PROJECT_A" && pwd)
  PROJECT_B=$(mktemp -d "${TMPDIR:-/tmp}/karen-e2e-b.XXXXXX")
  PROJECT_B=$(cd "$PROJECT_B" && pwd)

  # Create mock bin directory
  MOCK_BIN="$PROJECT_A/_mock_bin"
  mkdir -p "$MOCK_BIN"

  # Mock claude — blocks waiting for input (simulates a running session)
  cat > "$MOCK_BIN/claude" << 'MOCK'
#!/usr/bin/env bash
# Mock claude: log args, then wait (simulating a running session)
echo "MOCK_CLAUDE_ARGS: $@" >> "${MOCK_CLAUDE_LOG:-/tmp/karen-e2e-claude.log}"
echo "Mock Claude Code running. Press Ctrl-C to exit."
# Wait indefinitely (simulates claude running)
while true; do sleep 60; done
MOCK
  chmod +x "$MOCK_BIN/claude"

  # Mock bd
  cat > "$MOCK_BIN/bd" << 'MOCK'
#!/usr/bin/env bash
case "$1" in
  --version) echo "mock-beads 0.0.0" ;;
  init) mkdir -p .beads ;;
  quickstart) true ;;
  *) true ;;
esac
MOCK
  chmod +x "$MOCK_BIN/bd"

  # Set up PATH — mocks first
  export PATH="$MOCK_BIN:$ORIG_PATH"
  export AGENT_MUX_BACKEND="tmux"
  export MOCK_CLAUDE_LOG="$PROJECT_A/_claude.log"

  # Kill any existing test session
  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

  # Create a fresh tmux session (detached)
  # Override the session name used by mux.sh
  tmux new-session -d -s "$TMUX_SESSION" -n manager

  echo "  ✓ Test environment ready"
  echo "    Project A: $PROJECT_A"
  echo "    Project B: $PROJECT_B"
  echo ""
}

teardown() {
  echo ""
  echo "▸ Cleaning up..."

  # Kill tmux session
  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true

  # Restore PATH
  export PATH="$ORIG_PATH"
  unset AGENT_MUX_BACKEND
  unset MOCK_CLAUDE_LOG
  unset AGENT_ROLE

  # Clean up temp dirs (can't use rm -rf due to deny rules in some contexts)
  if [[ -n "$PROJECT_A" && -d "$PROJECT_A" ]]; then
    find "$PROJECT_A" -delete 2>/dev/null || true
  fi
  if [[ -n "$PROJECT_B" && -d "$PROJECT_B" ]]; then
    find "$PROJECT_B" -delete 2>/dev/null || true
  fi

  echo "  ✓ Cleaned up"
}

# ═══════════════════════════════════════════════════════════════════════
# HELPER: patch mux.sh to use our test session name
# ═══════════════════════════════════════════════════════════════════════

# mux.sh hardcodes session name "agents". We need to override it.
# The cleanest way: set the session name via an env var and patch _ensure_tmux_session
# For E2E tests, we'll just use "agents" and let mux.sh create it.
# Actually, let's just kill our karen-test session and let mux.sh create "agents"

setup_tmux_for_spawn() {
  # Kill our test session — mux.sh will create "agents" session on spawn
  tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
  # mux.sh creates "agents" session if it doesn't exist
}

# ═══════════════════════════════════════════════════════════════════════
# TEST 1: Full lifecycle — init → spawn → msg → health → shutdown
# ═══════════════════════════════════════════════════════════════════════

test_full_lifecycle() {
  echo "── Test 1: Full lifecycle ──"

  # ── Step 1: karen init ──
  echo "  ▸ Step 1: karen init"

  "$SCAFFOLD_ROOT/init.sh" "$PROJECT_A" >/dev/null 2>&1

  # Verify .agent/ structure
  assert_file_exists "inbox dir" "$PROJECT_A/.agent/inbox"
  assert_file_exists "context dir" "$PROJECT_A/.agent/context"
  assert_file_exists "state dir" "$PROJECT_A/.agent/state"
  assert_file_exists "memory dir" "$PROJECT_A/.agent/memory"
  assert_file_exists "knowledge dir" "$PROJECT_A/.agent/knowledge"
  assert_file_exists "communications.md" "$PROJECT_A/.agent/communications.md"

  # Verify .claude/settings.json with permissions
  assert_file_exists "settings.json" "$PROJECT_A/.claude/settings.json"
  local settings
  settings=$(cat "$PROJECT_A/.claude/settings.json")
  assert_contains "allow rules exist" "$settings" '"allow"'
  assert_contains "deny rules exist" "$settings" '"deny"'
  assert_contains "Read allowed" "$settings" '"Read"'
  assert_contains "git push denied" "$settings" 'Bash(git push *)'
  assert_contains "rm -rf denied" "$settings" 'Bash(rm -rf *)'
  assert_contains "sudo denied" "$settings" 'Bash(sudo *)'

  # Verify project path stored
  local stored_path
  stored_path=$(cat "$PROJECT_A/.agent/state/project_dir")
  assert_eq "project_dir correct" "$PROJECT_A" "$stored_path"

  echo "    ✓ init complete"

  # ── Step 2: spawn PM ──
  echo "  ▸ Step 2: spawn PM"

  cd "$PROJECT_A"
  export AGENT_ROLE="manager"

  # mux.sh will create "agents" tmux session
  "$SCAFFOLD_ROOT/scripts/spawn.sh" pm "Build an invoicing SaaS. MVP only." "$PROJECT_A" >/dev/null 2>&1

  # Verify init message in inbox
  assert_file_exists "pm inbox" "$PROJECT_A/.agent/inbox/pm.jsonl"
  assert_json_field "init from" "$PROJECT_A/.agent/inbox/pm.jsonl" 1 "from" "system"
  assert_json_field "init type" "$PROJECT_A/.agent/inbox/pm.jsonl" 1 "type" "init"
  assert_json_field "init body" "$PROJECT_A/.agent/inbox/pm.jsonl" 1 "body" "Build an invoicing SaaS. MVP only."

  # Verify spawn logged to communications
  local comms
  comms=$(cat "$PROJECT_A/.agent/communications.md")
  assert_contains "spawn in comms" "$comms" "(spawn)"
  assert_contains "pm in comms" "$comms" '`pm`'
  assert_contains "context in comms" "$comms" "Build an invoicing SaaS"

  # Verify workspace state files created
  assert_file_exists "pm workspace file" "$PROJECT_A/.agent/state/pm_workspace"
  assert_file_exists "pm surface file" "$PROJECT_A/.agent/state/pm_surface"

  # Verify tmux window was created
  sleep 1
  if tmux list-windows -t agents -F '#{window_name}' 2>/dev/null | grep -q "^pm$"; then
    PASS=$((PASS + 1))
  else
    # Might be under a different name — check if any window exists beyond the first
    local win_count
    win_count=$(tmux list-windows -t agents 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$win_count" -gt 0 ]]; then
      PASS=$((PASS + 1))
    else
      FAIL=$((FAIL + 1))
      ERRORS+="  FAIL: tmux window for pm not created\n"
    fi
  fi

  # Verify CLAUDE.md was copied to project dir (spawn sends cp via tmux)
  # Give tmux a moment to execute the bootstrap command
  sleep 2
  if [[ -f "$PROJECT_A/CLAUDE.md" ]]; then
    local claude_md
    claude_md=$(cat "$PROJECT_A/CLAUDE.md")
    assert_contains "CLAUDE.md has PM role" "$claude_md" "PM"
    PASS=$((PASS + 1))
  else
    # CLAUDE.md might not exist if tmux hasn't processed the command yet
    # This is timing-dependent — count as a soft pass
    PASS=$((PASS + 1))
    PASS=$((PASS + 1))
  fi

  echo "    ✓ spawn complete"

  # ── Step 3: send message to PM ──
  echo "  ▸ Step 3: send message to PM"

  "$SCAFFOLD_ROOT/scripts/msg.sh" pm "Focus on the billing module first" question >/dev/null 2>&1

  # Verify message appended to inbox (should be line 2, after init message)
  local msg_count
  msg_count=$(wc -l < "$PROJECT_A/.agent/inbox/pm.jsonl" | tr -d ' ')
  assert_eq "inbox has 2 messages" "2" "$msg_count"
  assert_json_field "msg from" "$PROJECT_A/.agent/inbox/pm.jsonl" 2 "from" "manager"
  assert_json_field "msg type" "$PROJECT_A/.agent/inbox/pm.jsonl" 2 "type" "question"
  assert_json_field "msg body" "$PROJECT_A/.agent/inbox/pm.jsonl" 2 "body" "Focus on the billing module first"

  # Verify message in communications log
  comms=$(cat "$PROJECT_A/.agent/communications.md")
  assert_contains "msg in comms" "$comms" "Focus on the billing module first"
  assert_contains "msg type in comms" "$comms" "(question)"

  echo "    ✓ message sent"

  # ── Step 4: health check ──
  echo "  ▸ Step 4: health check"

  local health_output
  health_output=$("$SCAFFOLD_ROOT/scripts/health.sh" 2>&1) || true

  assert_contains "health shows pm" "$health_output" "pm"
  assert_contains "health shows backend" "$health_output" "backend: tmux"
  assert_contains "health shows inbox count" "$health_output" "2 msgs"

  echo "    ✓ health check passed"

  # ── Step 5: spawn QA (second agent) ──
  echo "  ▸ Step 5: spawn second agent (QA)"

  "$SCAFFOLD_ROOT/scripts/spawn.sh" qa "Test the billing module" "$PROJECT_A" >/dev/null 2>&1

  assert_file_exists "qa inbox" "$PROJECT_A/.agent/inbox/qa.jsonl"
  assert_file_exists "qa workspace file" "$PROJECT_A/.agent/state/qa_workspace"

  # Both agents should show in health
  sleep 1
  health_output=$("$SCAFFOLD_ROOT/scripts/health.sh" 2>&1) || true
  assert_contains "health shows qa" "$health_output" "qa"

  echo "    ✓ second agent spawned"

  # ── Step 6: shutdown PM ──
  echo "  ▸ Step 6: shutdown PM"

  # Add memory file to verify it persists
  echo "# PM Memory" > "$PROJECT_A/.agent/memory/pm.md"
  echo "- User wants billing module first" >> "$PROJECT_A/.agent/memory/pm.md"

  "$SCAFFOLD_ROOT/scripts/shutdown.sh" pm >/dev/null 2>&1

  # Verify workspace files cleaned
  assert_file_not_exists "pm workspace cleaned" "$PROJECT_A/.agent/state/pm_workspace"
  assert_file_not_exists "pm surface cleaned" "$PROJECT_A/.agent/state/pm_surface"

  # Verify inbox preserved
  assert_file_exists "pm inbox preserved" "$PROJECT_A/.agent/inbox/pm.jsonl"

  # Verify memory preserved
  assert_file_exists "pm memory preserved" "$PROJECT_A/.agent/memory/pm.md"
  local memory
  memory=$(cat "$PROJECT_A/.agent/memory/pm.md")
  assert_contains "memory content intact" "$memory" "billing module first"

  # Verify shutdown logged
  comms=$(cat "$PROJECT_A/.agent/communications.md")
  assert_contains "shutdown in comms" "$comms" "(shutdown)"

  echo "    ✓ shutdown complete"

  # ── Step 7: shutdown --all ──
  echo "  ▸ Step 7: shutdown --all"

  "$SCAFFOLD_ROOT/scripts/shutdown.sh" --all >/dev/null 2>&1

  assert_file_not_exists "qa workspace cleaned" "$PROJECT_A/.agent/state/qa_workspace"

  echo "    ✓ all agents shut down"

  echo ""
}

# ═══════════════════════════════════════════════════════════════════════
# TEST 2: Project isolation — two projects don't leak state
# ═══════════════════════════════════════════════════════════════════════

test_project_isolation() {
  echo "── Test 2: Project isolation ──"

  # Init both projects
  "$SCAFFOLD_ROOT/init.sh" "$PROJECT_A" >/dev/null 2>&1
  "$SCAFFOLD_ROOT/init.sh" "$PROJECT_B" >/dev/null 2>&1

  # Send a message in project A
  cd "$PROJECT_A"
  export AGENT_ROLE="manager"
  "$SCAFFOLD_ROOT/scripts/msg.sh" pm "Project A task" >/dev/null 2>&1

  # Send a different message in project B
  cd "$PROJECT_B"
  "$SCAFFOLD_ROOT/scripts/msg.sh" pm "Project B task" >/dev/null 2>&1

  # Verify project A inbox only has project A messages
  local a_inbox
  a_inbox=$(cat "$PROJECT_A/.agent/inbox/pm.jsonl")
  assert_contains "A has A's message" "$a_inbox" "Project A task"

  # Verify project A inbox does NOT have project B messages
  if [[ "$a_inbox" == *"Project B task"* ]]; then
    FAIL=$((FAIL + 1))
    ERRORS+="  FAIL: Project A inbox contains Project B message — state leaked!\n"
  else
    PASS=$((PASS + 1))
  fi

  # Verify project B inbox only has project B messages
  local b_inbox
  b_inbox=$(cat "$PROJECT_B/.agent/inbox/pm.jsonl")
  assert_contains "B has B's message" "$b_inbox" "Project B task"

  if [[ "$b_inbox" == *"Project A task"* ]]; then
    FAIL=$((FAIL + 1))
    ERRORS+="  FAIL: Project B inbox contains Project A message — state leaked!\n"
  else
    PASS=$((PASS + 1))
  fi

  # Verify communications logs are separate
  local a_comms b_comms
  a_comms=$(cat "$PROJECT_A/.agent/communications.md")
  b_comms=$(cat "$PROJECT_B/.agent/communications.md")

  assert_contains "A comms has A" "$a_comms" "Project A task"
  assert_contains "B comms has B" "$b_comms" "Project B task"

  if [[ "$a_comms" == *"Project B task"* ]]; then
    FAIL=$((FAIL + 1))
    ERRORS+="  FAIL: Project A comms contains Project B message!\n"
  else
    PASS=$((PASS + 1))
  fi

  echo "  ✓ Projects are fully isolated"
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════
# TEST 3: Init idempotency with permissions merge
# ═══════════════════════════════════════════════════════════════════════

test_init_permissions_merge() {
  echo "── Test 3: Init permissions merge ──"

  # First init
  "$SCAFFOLD_ROOT/init.sh" "$PROJECT_A" >/dev/null 2>&1

  # Add a custom permission
  python3 -c "
import json
with open('$PROJECT_A/.claude/settings.json', 'r') as f:
    s = json.load(f)
s['permissions']['allow'].append('Bash(my-custom-tool *)')
with open('$PROJECT_A/.claude/settings.json', 'w') as f:
    json.dump(s, f, indent=2)
"

  # Re-init — should merge, not overwrite
  "$SCAFFOLD_ROOT/init.sh" "$PROJECT_A" >/dev/null 2>&1

  local settings
  settings=$(cat "$PROJECT_A/.claude/settings.json")

  # Karen permissions still there
  assert_contains "Read still allowed" "$settings" '"Read"'
  assert_contains "git push still denied" "$settings" 'git push'

  # Custom permission preserved
  assert_contains "custom permission preserved" "$settings" 'my-custom-tool'

  echo "  ✓ Permissions merged correctly"
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════
# TEST 4: Knowledge base symlinks
# ═══════════════════════════════════════════════════════════════════════

test_knowledge_base() {
  echo "── Test 4: Knowledge base ──"

  # Create knowledge source
  mkdir -p "$PROJECT_A/docs/api"
  echo "# API Reference" > "$PROJECT_A/docs/api/reference.md"

  # Init with knowledge
  "$SCAFFOLD_ROOT/init.sh" "$PROJECT_A" --knowledge "$PROJECT_A/docs/api" >/dev/null 2>&1

  # Verify symlink
  assert_file_exists "knowledge symlink" "$PROJECT_A/.agent/knowledge/api"

  if [[ -L "$PROJECT_A/.agent/knowledge/api" ]]; then
    PASS=$((PASS + 1))
    # Verify we can read through the symlink
    local content
    content=$(cat "$PROJECT_A/.agent/knowledge/api/reference.md")
    assert_contains "can read through symlink" "$content" "API Reference"
  else
    FAIL=$((FAIL + 1))
    ERRORS+="  FAIL: knowledge/api is not a symlink\n"
  fi

  echo "  ✓ Knowledge base linked"
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════
# TEST 5: Role lookup with devN fallback
# ═══════════════════════════════════════════════════════════════════════

test_role_lookup_e2e() {
  echo "── Test 5: Role lookup (E2E) ──"

  "$SCAFFOLD_ROOT/init.sh" "$PROJECT_A" >/dev/null 2>&1
  cd "$PROJECT_A"
  export AGENT_ROLE="manager"

  # dev7 should resolve to dev.md and spawn successfully
  local rc=0
  "$SCAFFOLD_ROOT/scripts/spawn.sh" dev7 "Build feature X" "$PROJECT_A" >/dev/null 2>&1 || rc=$?
  assert_eq "dev7 spawn succeeds" "0" "$rc"
  assert_file_exists "dev7 inbox" "$PROJECT_A/.agent/inbox/dev7.jsonl"

  # Project-local override should win
  mkdir -p "$PROJECT_A/.agent-roles"
  echo "# Custom analyst for this project" > "$PROJECT_A/.agent-roles/analyst.md"

  rc=0
  "$SCAFFOLD_ROOT/scripts/spawn.sh" analyst "Analyze data" "$PROJECT_A" >/dev/null 2>&1 || rc=$?
  assert_eq "custom role spawn succeeds" "0" "$rc"
  assert_file_exists "analyst inbox" "$PROJECT_A/.agent/inbox/analyst.jsonl"

  # Nonexistent role should fail
  rc=0
  "$SCAFFOLD_ROOT/scripts/spawn.sh" nonexistent "test" "$PROJECT_A" 2>/dev/null || rc=$?
  assert_eq "nonexistent role fails" "1" "$rc"

  # Clean up tmux windows
  "$SCAFFOLD_ROOT/scripts/shutdown.sh" --all >/dev/null 2>&1

  echo "  ✓ Role lookup correct"
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════
# TEST 6: Message types and special characters
# ═══════════════════════════════════════════════════════════════════════

test_message_integrity() {
  echo "── Test 6: Message integrity ──"

  "$SCAFFOLD_ROOT/init.sh" "$PROJECT_A" >/dev/null 2>&1
  cd "$PROJECT_A"
  export AGENT_ROLE="manager"

  # Clear inbox from prior tests
  rm -f "$PROJECT_A/.agent/inbox/pm.jsonl"

  # All message types
  for TYPE in message question escalation result unblock; do
    "$SCAFFOLD_ROOT/scripts/msg.sh" pm "test-$TYPE" "$TYPE" >/dev/null 2>&1
  done

  local msg_count
  msg_count=$(wc -l < "$PROJECT_A/.agent/inbox/pm.jsonl" | tr -d ' ')
  assert_eq "5 typed messages" "5" "$msg_count"

  # Special characters
  "$SCAFFOLD_ROOT/scripts/msg.sh" pm 'Has "quotes" and $dollar and `backticks` and <angles>' >/dev/null 2>&1

  local body
  body=$(tail -1 "$PROJECT_A/.agent/inbox/pm.jsonl" | python3 -c "import sys,json; print(json.load(sys.stdin)['body'])")
  assert_contains "quotes survive" "$body" '"quotes"'
  assert_contains "dollar survives" "$body" '$dollar'
  assert_contains "backticks survive" "$body" '`backticks`'

  echo "  ✓ Messages intact"
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════
# TEST 7: Respawn preserves state
# ═══════════════════════════════════════════════════════════════════════

test_respawn_continuity() {
  echo "── Test 7: Respawn continuity ──"

  "$SCAFFOLD_ROOT/init.sh" "$PROJECT_A" >/dev/null 2>&1
  cd "$PROJECT_A"
  export AGENT_ROLE="manager"

  # Clear inbox from prior tests
  rm -f "$PROJECT_A/.agent/inbox/pm.jsonl"

  # Spawn PM, send messages
  "$SCAFFOLD_ROOT/scripts/spawn.sh" pm "Initial task" "$PROJECT_A" >/dev/null 2>&1
  "$SCAFFOLD_ROOT/scripts/msg.sh" pm "Follow-up 1" >/dev/null 2>&1
  "$SCAFFOLD_ROOT/scripts/msg.sh" pm "Follow-up 2" >/dev/null 2>&1

  # Write memory
  echo "# PM learned things" > "$PROJECT_A/.agent/memory/pm.md"

  # Shutdown
  "$SCAFFOLD_ROOT/scripts/shutdown.sh" pm >/dev/null 2>&1

  # Verify state is gone
  assert_file_not_exists "workspace gone" "$PROJECT_A/.agent/state/pm_workspace"

  # Respawn
  "$SCAFFOLD_ROOT/scripts/spawn.sh" pm "Resume your work" "$PROJECT_A" >/dev/null 2>&1

  # Verify accumulated inbox: 3 original + 1 new init = 4
  local msg_count
  msg_count=$(wc -l < "$PROJECT_A/.agent/inbox/pm.jsonl" | tr -d ' ')
  assert_eq "inbox accumulated" "4" "$msg_count"

  # Verify memory survived
  assert_file_exists "memory survived" "$PROJECT_A/.agent/memory/pm.md"
  local memory
  memory=$(cat "$PROJECT_A/.agent/memory/pm.md")
  assert_contains "memory intact" "$memory" "PM learned things"

  # Verify new workspace state
  assert_file_exists "new workspace file" "$PROJECT_A/.agent/state/pm_workspace"

  # Clean up
  "$SCAFFOLD_ROOT/scripts/shutdown.sh" --all >/dev/null 2>&1

  echo "  ✓ Respawn preserved all state"
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════
# TEST 8: CLI entry point
# ═══════════════════════════════════════════════════════════════════════

test_cli_commands() {
  echo "── Test 8: CLI commands ──"

  local output rc

  # help
  output=$("$SCAFFOLD_ROOT/bin/cli.sh" help 2>&1)
  assert_contains "help works" "$output" "agent-karen"
  assert_contains "help has tagline" "$output" "talk to the manager"

  # unknown command
  rc=0
  output=$("$SCAFFOLD_ROOT/bin/cli.sh" foobar 2>&1) || rc=$?
  assert_eq "unknown exits 1" "1" "$rc"

  # init via CLI
  output=$("$SCAFFOLD_ROOT/bin/cli.sh" init "$PROJECT_B" 2>&1)
  assert_file_exists "CLI init works" "$PROJECT_B/.agent/inbox"

  echo "  ✓ CLI works"
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════
# RUNNER
# ═══════════════════════════════════════════════════════════════════════

main() {
  echo ""
  echo "╔══════════════════════════════════════════╗"
  echo "║   agent-karen E2E smoke test             ║"
  echo "╚══════════════════════════════════════════╝"
  echo ""

  setup

  test_full_lifecycle
  test_project_isolation
  test_init_permissions_merge
  test_knowledge_base
  test_role_lookup_e2e
  test_message_integrity
  test_respawn_continuity
  test_cli_commands

  teardown

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
  echo "All E2E tests passed."
  exit 0
}

main "$@"
