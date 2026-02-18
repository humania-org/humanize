#!/bin/bash
#
# Tests for session_id feature in RLCR loop
#
# Tests cover:
# - session_id field in state.md
# - PostToolUse hook (loop-post-bash-hook.sh) recording session_id
# - find_active_loop session_id filtering
# - Validator session_id extraction and filtering
# - Cancel script works regardless of session_id
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

# Source shared loop library
HOOKS_LIB_DIR="$(cd "$SCRIPT_DIR/../hooks/lib" && pwd)"
source "$HOOKS_LIB_DIR/loop-common.sh"

echo "=========================================="
echo "Session ID Feature Tests"
echo "=========================================="
echo ""

# Mock setup script path used as command signature in signal files
MOCK_SETUP_PATH="/mock/plugin/scripts/setup-rlcr-loop.sh"

# ========================================
# Test: setup creates state.md with session_id field
# ========================================

setup_test_dir
init_test_git_repo "$TEST_DIR/project"

# Create a valid plan file (gitignored)
mkdir -p "$TEST_DIR/project/temp"
cat > "$TEST_DIR/project/temp/plan.md" << 'EOF'
# Test Plan

This is a test plan with enough content.
Line 3 with meaningful content.
Line 4 with more content.
Line 5 final content line.
EOF

# Add .gitignore for temp/
echo "temp/" > "$TEST_DIR/project/.gitignore"
cd "$TEST_DIR/project"
git add .gitignore
git commit -q -m "Add gitignore"

# Run setup script
SETUP_SCRIPT="$SCRIPT_DIR/../scripts/setup-rlcr-loop.sh"
cd "$TEST_DIR/project"
CLAUDE_PROJECT_DIR="$TEST_DIR/project" bash "$SETUP_SCRIPT" temp/plan.md > /dev/null 2>&1 || true

# Find the state file
STATE_FILE=$(find "$TEST_DIR/project/.humanize/rlcr" -name "state.md" -type f 2>/dev/null | head -1)

if [[ -n "$STATE_FILE" ]] && grep -q "^session_id:" "$STATE_FILE"; then
    pass "setup creates state.md with session_id field"
else
    fail "setup creates state.md with session_id field" "session_id field in state.md" "not found"
fi

# ========================================
# Test: session_id field is initially empty
# ========================================

if [[ -n "$STATE_FILE" ]]; then
    SESSION_ID_VALUE=$(grep "^session_id:" "$STATE_FILE" | sed 's/session_id: *//')
    if [[ -z "$SESSION_ID_VALUE" ]]; then
        pass "session_id is initially empty in state.md"
    else
        fail "session_id is initially empty in state.md" "empty" "$SESSION_ID_VALUE"
    fi
else
    skip "session_id is initially empty in state.md" "state file not found"
fi

# ========================================
# Test: setup creates .pending-session-id signal file
# ========================================

SIGNAL_FILE="$TEST_DIR/project/.humanize/.pending-session-id"
if [[ -f "$SIGNAL_FILE" ]]; then
    pass "setup creates .pending-session-id signal file"
else
    fail "setup creates .pending-session-id signal file" "signal file exists" "not found"
fi

# ========================================
# Test: signal file contains path to state.md
# ========================================

if [[ -f "$SIGNAL_FILE" ]]; then
    SIGNAL_CONTENT=$(cat "$SIGNAL_FILE")
    if [[ -n "$SIGNAL_CONTENT" ]] && [[ "$SIGNAL_CONTENT" == *"state.md"* ]]; then
        pass "signal file contains path to state.md"
    else
        fail "signal file contains path to state.md" "path containing state.md" "$SIGNAL_CONTENT"
    fi
else
    skip "signal file contains path to state.md" "signal file not found"
fi

# ========================================
# Test: PostToolUse hook records session_id
# ========================================

setup_test_dir
init_test_git_repo "$TEST_DIR/project"
mkdir -p "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00"
mkdir -p "$TEST_DIR/project/.humanize"

# Create state.md with empty session_id
cat > "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 10
codex_model: gpt-5.3-codex
codex_effort: xhigh
codex_timeout: 5400
push_every_round: false
full_review_round: 5
plan_file: temp/plan.md
plan_tracked: false
start_branch: main
base_branch: main
base_commit: abc123
review_started: false
ask_codex_question: true
session_id:
---
EOF

# Create signal file pointing to state.md (with full script path as command signature)
printf '%s\n%s\n' "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" "$MOCK_SETUP_PATH" > "$TEST_DIR/project/.humanize/.pending-session-id"

# Run PostToolUse hook with mock JSON input containing session_id
POST_HOOK="$SCRIPT_DIR/../hooks/loop-post-bash-hook.sh"
if [[ -f "$POST_HOOK" ]]; then
    MOCK_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"\\\"${MOCK_SETUP_PATH}\\\" plan.md\"},\"session_id\":\"test-session-abc-123\",\"transcript_path\":\"/tmp/test\",\"cwd\":\"/tmp\",\"permission_mode\":\"default\",\"hook_event_name\":\"PostToolUse\"}"
    echo "$MOCK_JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR/project" bash "$POST_HOOK" > /dev/null 2>&1 || true

    # Check if session_id was recorded
    RECORDED_ID=$(grep "^session_id:" "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" | sed 's/session_id: *//')
    if [[ "$RECORDED_ID" == "test-session-abc-123" ]]; then
        pass "PostToolUse hook records session_id in state.md"
    else
        fail "PostToolUse hook records session_id in state.md" "test-session-abc-123" "$RECORDED_ID"
    fi

    # Check signal file was removed
    if [[ ! -f "$TEST_DIR/project/.humanize/.pending-session-id" ]]; then
        pass "PostToolUse hook removes signal file after recording"
    else
        fail "PostToolUse hook removes signal file after recording" "signal file removed" "still exists"
    fi
else
    skip "PostToolUse hook records session_id in state.md" "hook file not yet created"
    skip "PostToolUse hook removes signal file after recording" "hook file not yet created"
fi

# ========================================
# Test: PostToolUse hook is no-op without signal file
# ========================================

setup_test_dir
init_test_git_repo "$TEST_DIR/project"
mkdir -p "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00"

cat > "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 10
session_id: existing-session-id
review_started: false
base_branch: main
plan_tracked: false
start_branch: main
---
EOF

if [[ -f "$POST_HOOK" ]]; then
    MOCK_JSON='{"tool_name":"Bash","tool_input":{"command":"echo hello"},"session_id":"different-session","transcript_path":"/tmp/test","cwd":"/tmp","permission_mode":"default","hook_event_name":"PostToolUse"}'
    echo "$MOCK_JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR/project" bash "$POST_HOOK" > /dev/null 2>&1 || true

    # session_id should NOT be changed
    RECORDED_ID=$(grep "^session_id:" "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" | sed 's/session_id: *//')
    if [[ "$RECORDED_ID" == "existing-session-id" ]]; then
        pass "PostToolUse hook is no-op without signal file"
    else
        fail "PostToolUse hook is no-op without signal file" "existing-session-id" "$RECORDED_ID"
    fi
else
    skip "PostToolUse hook is no-op without signal file" "hook file not yet created"
fi

# ========================================
# Test: find_active_loop with matching session_id
# ========================================

setup_test_dir
mkdir -p "$TEST_DIR/loop/2026-01-01_00-00-00"
cat > "$TEST_DIR/loop/2026-01-01_00-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 10
session_id: my-session-123
review_started: false
base_branch: main
plan_tracked: false
start_branch: main
---
EOF

RESULT=$(find_active_loop "$TEST_DIR/loop" "my-session-123")
if [[ -n "$RESULT" ]]; then
    pass "find_active_loop returns dir for matching session_id"
else
    fail "find_active_loop returns dir for matching session_id" "non-empty" "empty"
fi

# ========================================
# Test: find_active_loop with non-matching session_id
# ========================================

RESULT=$(find_active_loop "$TEST_DIR/loop" "other-session-456")
if [[ -z "$RESULT" ]]; then
    pass "find_active_loop returns empty for non-matching session_id"
else
    fail "find_active_loop returns empty for non-matching session_id" "empty" "$RESULT"
fi

# ========================================
# Test: find_active_loop with empty stored session_id matches any
# ========================================

setup_test_dir
mkdir -p "$TEST_DIR/loop/2026-01-01_00-00-00"
cat > "$TEST_DIR/loop/2026-01-01_00-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 10
session_id:
review_started: false
base_branch: main
plan_tracked: false
start_branch: main
---
EOF

RESULT=$(find_active_loop "$TEST_DIR/loop" "any-session-id")
if [[ -n "$RESULT" ]]; then
    pass "find_active_loop with empty stored session_id matches any session"
else
    fail "find_active_loop with empty stored session_id matches any session" "non-empty" "empty"
fi

# ========================================
# Test: find_active_loop without session_id param (backward compat)
# ========================================

setup_test_dir
mkdir -p "$TEST_DIR/loop/2026-01-01_00-00-00"
cat > "$TEST_DIR/loop/2026-01-01_00-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 10
session_id: some-session
review_started: false
base_branch: main
plan_tracked: false
start_branch: main
---
EOF

RESULT=$(find_active_loop "$TEST_DIR/loop")
if [[ -n "$RESULT" ]]; then
    pass "find_active_loop without session_id param is backward compatible"
else
    fail "find_active_loop without session_id param is backward compatible" "non-empty" "empty"
fi

# ========================================
# Test: find_active_loop with finalize-state.md and session_id
# ========================================

setup_test_dir
mkdir -p "$TEST_DIR/loop/2026-01-01_00-00-00"
cat > "$TEST_DIR/loop/2026-01-01_00-00-00/finalize-state.md" << 'EOF'
---
current_round: 5
max_iterations: 10
session_id: finalize-session
review_started: true
base_branch: main
plan_tracked: false
start_branch: main
---
EOF

RESULT=$(find_active_loop "$TEST_DIR/loop" "finalize-session")
if [[ -n "$RESULT" ]]; then
    pass "find_active_loop matches session_id in finalize-state.md"
else
    fail "find_active_loop matches session_id in finalize-state.md" "non-empty" "empty"
fi

RESULT=$(find_active_loop "$TEST_DIR/loop" "wrong-session")
if [[ -z "$RESULT" ]]; then
    pass "find_active_loop rejects wrong session_id for finalize-state.md"
else
    fail "find_active_loop rejects wrong session_id for finalize-state.md" "empty" "$RESULT"
fi

# ========================================
# Test: parse_state_file reads session_id
# ========================================

setup_test_dir
mkdir -p "$TEST_DIR/loop"
cat > "$TEST_DIR/loop/state.md" << 'EOF'
---
current_round: 3
max_iterations: 20
session_id: parsed-session-xyz
review_started: false
base_branch: main
plan_tracked: false
start_branch: main
---
EOF

if parse_state_file "$TEST_DIR/loop/state.md"; then
    if [[ "${STATE_SESSION_ID:-}" == "parsed-session-xyz" ]]; then
        pass "parse_state_file reads session_id field"
    else
        fail "parse_state_file reads session_id field" "parsed-session-xyz" "${STATE_SESSION_ID:-empty}"
    fi
else
    fail "parse_state_file reads session_id field" "successful parse" "parse failed"
fi

# ========================================
# Test: cancel script works regardless of session_id
# ========================================

setup_test_dir
init_test_git_repo "$TEST_DIR/project"
mkdir -p "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00"

cat > "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" << 'EOF'
---
current_round: 2
max_iterations: 10
session_id: leader-session-id
review_started: false
base_branch: main
plan_tracked: false
start_branch: main
---
EOF

CANCEL_SCRIPT="$SCRIPT_DIR/../scripts/cancel-rlcr-loop.sh"
cd "$TEST_DIR/project"
CANCEL_OUTPUT=$(CLAUDE_PROJECT_DIR="$TEST_DIR/project" bash "$CANCEL_SCRIPT" 2>&1) || true

if echo "$CANCEL_OUTPUT" | grep -q "CANCELLED"; then
    pass "cancel script works regardless of session_id"
else
    fail "cancel script works regardless of session_id" "CANCELLED in output" "$CANCEL_OUTPUT"
fi

# Verify state was renamed
if [[ -f "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/cancel-state.md" ]]; then
    pass "cancel script renames state to cancel-state.md with session_id"
else
    fail "cancel script renames state to cancel-state.md with session_id" "cancel-state.md exists" "not found"
fi

# ========================================
# Test: cancel script finds older active loop when newer is inactive
# ========================================

setup_test_dir
init_test_git_repo "$TEST_DIR/project"

# Create older active loop (stale)
mkdir -p "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00"
cat > "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" << 'EOF'
---
current_round: 3
max_iterations: 10
session_id: active-session
review_started: false
base_branch: main
plan_tracked: false
start_branch: main
---
EOF

# Create newer inactive loop (completed, only complete-state.md)
mkdir -p "$TEST_DIR/project/.humanize/rlcr/2026-02-01_00-00-00"
cat > "$TEST_DIR/project/.humanize/rlcr/2026-02-01_00-00-00/complete-state.md" << 'EOF'
---
current_round: 10
max_iterations: 10
session_id: done-session
review_started: true
base_branch: main
plan_tracked: false
start_branch: main
---
EOF

# Zombie-loop protection: cancel only checks newest dir, which is completed.
# Stale older loop should NOT be revived and cancelled.
cd "$TEST_DIR/project"
CANCEL_OUTPUT=$(CLAUDE_PROJECT_DIR="$TEST_DIR/project" bash "$CANCEL_SCRIPT" 2>&1) || true

if echo "$CANCEL_OUTPUT" | grep -q "NO_LOOP"; then
    pass "cancel script reports no active loop when newest dir is completed"
else
    fail "cancel script reports no active loop when newest dir is completed" "NO_LOOP in output" "$CANCEL_OUTPUT"
fi

# Verify the older stale loop was NOT touched
if [[ -f "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" ]]; then
    pass "cancel script does not revive stale older loop"
else
    fail "cancel script does not revive stale older loop" "state.md still present" "not found"
fi

# ========================================
# Test: session_id with YAML-safe characters only
# ========================================

setup_test_dir
mkdir -p "$TEST_DIR/loop/2026-01-01_00-00-00"
cat > "$TEST_DIR/loop/2026-01-01_00-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 10
session_id: abc-123_def.456
review_started: false
base_branch: main
plan_tracked: false
start_branch: main
---
EOF

RESULT=$(find_active_loop "$TEST_DIR/loop" "abc-123_def.456")
if [[ -n "$RESULT" ]]; then
    pass "session_id with alphanumeric, dash, underscore, dot works"
else
    fail "session_id with alphanumeric, dash, underscore, dot works" "non-empty" "empty"
fi

# ========================================
# Test: PostToolUse hook rejects non-setup Bash commands (race prevention)
# ========================================

setup_test_dir
init_test_git_repo "$TEST_DIR/project"
mkdir -p "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00"
mkdir -p "$TEST_DIR/project/.humanize"

cat > "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 10
session_id:
review_started: false
base_branch: main
plan_tracked: false
start_branch: main
---
EOF

# Create signal file with full script path as command signature
printf '%s\n%s\n' "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" "$MOCK_SETUP_PATH" > "$TEST_DIR/project/.humanize/.pending-session-id"

if [[ -f "$POST_HOOK" ]]; then
    # Send a non-setup Bash command - hook should NOT consume the signal
    MOCK_JSON='{"tool_name":"Bash","tool_input":{"command":"echo hello"},"session_id":"wrong-session","transcript_path":"/tmp/test","cwd":"/tmp","permission_mode":"default","hook_event_name":"PostToolUse"}'
    echo "$MOCK_JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR/project" bash "$POST_HOOK" > /dev/null 2>&1 || true

    # session_id should still be empty (signal not consumed)
    RECORDED_ID=$(grep "^session_id:" "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" | sed 's/session_id: *//')
    if [[ -z "$RECORDED_ID" ]]; then
        pass "PostToolUse hook rejects non-setup Bash commands"
    else
        fail "PostToolUse hook rejects non-setup Bash commands" "empty session_id" "$RECORDED_ID"
    fi

    # Signal file should still exist
    if [[ -f "$TEST_DIR/project/.humanize/.pending-session-id" ]]; then
        pass "signal file preserved after non-setup Bash command"
    else
        fail "signal file preserved after non-setup Bash command" "signal file exists" "removed"
    fi
else
    skip "PostToolUse hook rejects non-setup Bash commands" "hook file not found"
    skip "signal file preserved after non-setup Bash command" "hook file not found"
fi

# ========================================
# Test: PostToolUse hook accepts setup-rlcr-loop.sh command
# ========================================

if [[ -f "$POST_HOOK" ]]; then
    # Now send the actual setup command (quoted invocation) - hook should consume the signal
    MOCK_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"\\\"${MOCK_SETUP_PATH}\\\" plan.md\"},\"session_id\":\"leader-session-id\",\"transcript_path\":\"/tmp/test\",\"cwd\":\"/tmp\",\"permission_mode\":\"default\",\"hook_event_name\":\"PostToolUse\"}"
    echo "$MOCK_JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR/project" bash "$POST_HOOK" > /dev/null 2>&1 || true

    RECORDED_ID=$(grep "^session_id:" "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" | sed 's/session_id: *//')
    if [[ "$RECORDED_ID" == "leader-session-id" ]]; then
        pass "PostToolUse hook accepts setup-rlcr-loop.sh command"
    else
        fail "PostToolUse hook accepts setup-rlcr-loop.sh command" "leader-session-id" "$RECORDED_ID"
    fi
else
    skip "PostToolUse hook accepts setup-rlcr-loop.sh command" "hook file not found"
fi

# ========================================
# Test: PostToolUse hook handles special characters in session_id
# ========================================

setup_test_dir
init_test_git_repo "$TEST_DIR/project"
mkdir -p "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00"
mkdir -p "$TEST_DIR/project/.humanize"

cat > "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 10
session_id:
review_started: false
base_branch: main
plan_tracked: false
start_branch: main
---
EOF

printf '%s\n%s\n' "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" "$MOCK_SETUP_PATH" > "$TEST_DIR/project/.humanize/.pending-session-id"

if [[ -f "$POST_HOOK" ]]; then
    # session_id with special chars: slashes, ampersands, dots
    MOCK_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"${MOCK_SETUP_PATH} plan.md\"},\"session_id\":\"abc/def&ghi.jkl\",\"transcript_path\":\"/tmp/test\",\"cwd\":\"/tmp\",\"permission_mode\":\"default\",\"hook_event_name\":\"PostToolUse\"}"
    echo "$MOCK_JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR/project" bash "$POST_HOOK" > /dev/null 2>&1 || true

    RECORDED_ID=$(grep "^session_id:" "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" | sed 's/session_id: *//')
    if [[ "$RECORDED_ID" == "abc/def&ghi.jkl" ]]; then
        pass "PostToolUse hook handles special characters in session_id"
    else
        fail "PostToolUse hook handles special characters in session_id" "abc/def&ghi.jkl" "$RECORDED_ID"
    fi

    # Signal file should be removed
    if [[ ! -f "$TEST_DIR/project/.humanize/.pending-session-id" ]]; then
        pass "signal file removed after special-char session_id recording"
    else
        fail "signal file removed after special-char session_id recording" "removed" "still exists"
    fi
else
    skip "PostToolUse hook handles special characters in session_id" "hook file not found"
    skip "signal file removed after special-char session_id recording" "hook file not found"
fi

# ========================================
# Test: find_active_loop filter-first: newer non-matching, older matching
# ========================================

setup_test_dir

# Create older loop dir with matching session_id
mkdir -p "$TEST_DIR/loop/2026-01-01_00-00-00"
cat > "$TEST_DIR/loop/2026-01-01_00-00-00/state.md" << 'EOF'
---
current_round: 3
max_iterations: 10
session_id: leader-session
review_started: false
base_branch: main
plan_tracked: false
start_branch: main
---
EOF

# Create newer loop dir with different session_id
mkdir -p "$TEST_DIR/loop/2026-02-01_00-00-00"
cat > "$TEST_DIR/loop/2026-02-01_00-00-00/state.md" << 'EOF'
---
current_round: 1
max_iterations: 10
session_id: other-session
review_started: false
base_branch: main
plan_tracked: false
start_branch: main
---
EOF

RESULT=$(find_active_loop "$TEST_DIR/loop" "leader-session")
if [[ -n "$RESULT" ]] && [[ "$RESULT" == *"2026-01-01"* ]]; then
    pass "find_active_loop filter-first: skips newer non-matching, finds older matching"
else
    fail "find_active_loop filter-first: skips newer non-matching, finds older matching" "2026-01-01 dir" "$RESULT"
fi

# Also verify the other session finds the newer dir
RESULT=$(find_active_loop "$TEST_DIR/loop" "other-session")
if [[ -n "$RESULT" ]] && [[ "$RESULT" == *"2026-02-01"* ]]; then
    pass "find_active_loop filter-first: other session finds its newer loop"
else
    fail "find_active_loop filter-first: other session finds its newer loop" "2026-02-01 dir" "$RESULT"
fi

# Without filter, should return newest (2026-02-01)
RESULT=$(find_active_loop "$TEST_DIR/loop")
if [[ -n "$RESULT" ]] && [[ "$RESULT" == *"2026-02-01"* ]]; then
    pass "find_active_loop without filter returns newest active loop"
else
    fail "find_active_loop without filter returns newest active loop" "2026-02-01 dir" "$RESULT"
fi

# ========================================
# Test: find_active_loop session filter: terminal newest dir blocks stale revival
# ========================================
# When the newest dir for a session is in terminal state (complete-state.md),
# find_active_loop must NOT fall through to an older active dir for the same session.
# This prevents stale loop revival and enables concurrent loops with different sessions.

setup_test_dir

# Create older matching active loop (state.md still present -- stale)
mkdir -p "$TEST_DIR/loop/2026-01-01_00-00-00"
cat > "$TEST_DIR/loop/2026-01-01_00-00-00/state.md" << 'EOF'
---
current_round: 2
max_iterations: 10
session_id: my-session
review_started: false
base_branch: main
plan_tracked: false
start_branch: main
---
EOF

# Create newer dir that is in terminal state (complete-state.md, no state.md)
mkdir -p "$TEST_DIR/loop/2026-02-01_00-00-00"
cat > "$TEST_DIR/loop/2026-02-01_00-00-00/complete-state.md" << 'EOF'
---
current_round: 10
max_iterations: 10
session_id: my-session
review_started: true
base_branch: main
plan_tracked: false
start_branch: main
---
EOF

RESULT=$(find_active_loop "$TEST_DIR/loop" "my-session")
if [[ -z "$RESULT" ]]; then
    pass "find_active_loop session filter: terminal newest blocks stale revival"
else
    fail "find_active_loop session filter: terminal newest blocks stale revival" "empty (no active loop)" "$RESULT"
fi

# Without filter: newest dir has terminal state, so no-filter returns empty
# (only checks newest directory -- zombie-loop protection)
RESULT=$(find_active_loop "$TEST_DIR/loop")
if [[ -z "$RESULT" ]]; then
    pass "find_active_loop no-filter: returns empty when newest dir is terminal"
else
    fail "find_active_loop no-filter: returns empty when newest dir is terminal" "empty" "$RESULT"
fi

# ========================================
# Test: find_active_loop session filter: different session finds its own active loop
# ========================================
# Session A has terminal newest, session B has active loop -- they don't interfere

setup_test_dir

# Session A: older active (stale), newer completed
mkdir -p "$TEST_DIR/loop/2026-01-01_00-00-00"
cat > "$TEST_DIR/loop/2026-01-01_00-00-00/state.md" << 'EOF'
---
current_round: 2
max_iterations: 10
session_id: session-A
review_started: false
base_branch: main
plan_tracked: false
start_branch: main
---
EOF
mkdir -p "$TEST_DIR/loop/2026-02-01_00-00-00"
cat > "$TEST_DIR/loop/2026-02-01_00-00-00/complete-state.md" << 'EOF'
---
current_round: 10
max_iterations: 10
session_id: session-A
review_started: true
base_branch: main
plan_tracked: false
start_branch: main
---
EOF

# Session B: active loop in between
mkdir -p "$TEST_DIR/loop/2026-01-15_00-00-00"
cat > "$TEST_DIR/loop/2026-01-15_00-00-00/state.md" << 'EOF'
---
current_round: 3
max_iterations: 10
session_id: session-B
review_started: false
base_branch: main
plan_tracked: false
start_branch: main
---
EOF

RESULT=$(find_active_loop "$TEST_DIR/loop" "session-A")
if [[ -z "$RESULT" ]]; then
    pass "find_active_loop: session-A returns empty (newest is terminal)"
else
    fail "find_active_loop: session-A returns empty (newest is terminal)" "empty" "$RESULT"
fi

RESULT=$(find_active_loop "$TEST_DIR/loop" "session-B")
if [[ -n "$RESULT" ]] && [[ "$RESULT" == *"2026-01-15"* ]]; then
    pass "find_active_loop: session-B finds its own active loop"
else
    fail "find_active_loop: session-B finds its own active loop" "2026-01-15 dir" "$RESULT"
fi

# ========================================
# Test: find_active_loop session filter: cancel-state.md also blocks revival
# ========================================

setup_test_dir

mkdir -p "$TEST_DIR/loop/2026-01-01_00-00-00"
cat > "$TEST_DIR/loop/2026-01-01_00-00-00/state.md" << 'EOF'
---
current_round: 2
max_iterations: 10
session_id: my-session
review_started: false
base_branch: main
plan_tracked: false
start_branch: main
---
EOF

mkdir -p "$TEST_DIR/loop/2026-02-01_00-00-00"
cat > "$TEST_DIR/loop/2026-02-01_00-00-00/cancel-state.md" << 'EOF'
---
current_round: 5
max_iterations: 10
session_id: my-session
review_started: false
base_branch: main
plan_tracked: false
start_branch: main
---
EOF

RESULT=$(find_active_loop "$TEST_DIR/loop" "my-session")
if [[ -z "$RESULT" ]]; then
    pass "find_active_loop: cancel-state.md in newest also blocks stale revival"
else
    fail "find_active_loop: cancel-state.md in newest also blocks stale revival" "empty" "$RESULT"
fi

# ========================================
# Test: Signal file format includes command marker
# ========================================

setup_test_dir
init_test_git_repo "$TEST_DIR/project"

mkdir -p "$TEST_DIR/project/temp"
cat > "$TEST_DIR/project/temp/plan.md" << 'EOF'
# Test Plan

This is a test plan with enough content.
Line 3 with meaningful content.
Line 4 with more content.
Line 5 final content line.
EOF

echo "temp/" > "$TEST_DIR/project/.gitignore"
cd "$TEST_DIR/project"
git add .gitignore
git commit -q -m "Add gitignore"

cd "$TEST_DIR/project"
CLAUDE_PROJECT_DIR="$TEST_DIR/project" bash "$SETUP_SCRIPT" temp/plan.md > /dev/null 2>&1 || true

SIGNAL_FILE="$TEST_DIR/project/.humanize/.pending-session-id"
if [[ -f "$SIGNAL_FILE" ]]; then
    LINE_COUNT=$(wc -l < "$SIGNAL_FILE")
    SIGNATURE_LINE=$(sed -n '2p' "$SIGNAL_FILE")
    # Line 2 should be the full resolved path ending in setup-rlcr-loop.sh
    if [[ "$LINE_COUNT" -ge 2 ]] && [[ "$SIGNATURE_LINE" == *"/setup-rlcr-loop.sh" ]] && [[ "$SIGNATURE_LINE" == /* ]]; then
        pass "signal file contains full script path as command signature"
    else
        fail "signal file contains full script path as command signature" "absolute path ending in /setup-rlcr-loop.sh" "lines=$LINE_COUNT sig=$SIGNATURE_LINE"
    fi
else
    fail "signal file contains full script path as command signature" "signal file exists" "not found"
fi

# ========================================
# Test: PostToolUse hook rejects command containing marker as substring (false positive)
# ========================================

setup_test_dir
init_test_git_repo "$TEST_DIR/project"
mkdir -p "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00"
mkdir -p "$TEST_DIR/project/.humanize"

cat > "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 10
session_id:
review_started: false
base_branch: main
plan_tracked: false
start_branch: main
---
EOF

printf '%s\n%s\n' "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" "$MOCK_SETUP_PATH" > "$TEST_DIR/project/.humanize/.pending-session-id"

if [[ -f "$POST_HOOK" ]]; then
    # Command contains the script name as text but is NOT an actual invocation
    MOCK_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"echo ${MOCK_SETUP_PATH}\"},\"session_id\":\"attacker-session\",\"transcript_path\":\"/tmp/test\",\"cwd\":\"/tmp\",\"permission_mode\":\"default\",\"hook_event_name\":\"PostToolUse\"}"
    echo "$MOCK_JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR/project" bash "$POST_HOOK" > /dev/null 2>&1 || true

    RECORDED_ID=$(grep "^session_id:" "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" | sed 's/session_id: *//')
    if [[ -z "$RECORDED_ID" ]]; then
        pass "PostToolUse hook rejects echo-with-path false positive"
    else
        fail "PostToolUse hook rejects echo-with-path false positive" "empty session_id" "$RECORDED_ID"
    fi

    if [[ -f "$TEST_DIR/project/.humanize/.pending-session-id" ]]; then
        pass "signal file preserved after echo-with-path false positive"
    else
        fail "signal file preserved after echo-with-path false positive" "signal file exists" "removed"
    fi

    # Also test with basename-only substring (cat setup-rlcr-loop.sh)
    MOCK_JSON='{"tool_name":"Bash","tool_input":{"command":"cat setup-rlcr-loop.sh"},"session_id":"attacker-session","transcript_path":"/tmp/test","cwd":"/tmp","permission_mode":"default","hook_event_name":"PostToolUse"}'
    echo "$MOCK_JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR/project" bash "$POST_HOOK" > /dev/null 2>&1 || true

    RECORDED_ID=$(grep "^session_id:" "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" | sed 's/session_id: *//')
    if [[ -z "$RECORDED_ID" ]]; then
        pass "PostToolUse hook rejects basename-only false positive"
    else
        fail "PostToolUse hook rejects basename-only false positive" "empty session_id" "$RECORDED_ID"
    fi
else
    skip "PostToolUse hook rejects echo-with-path false positive" "hook file not found"
    skip "signal file preserved after echo-with-path false positive" "hook file not found"
    skip "PostToolUse hook rejects basename-only false positive" "hook file not found"
fi

# ========================================
# Test: PostToolUse hook rejects quoted-prefix concatenation (boundary bypass)
# ========================================

setup_test_dir
init_test_git_repo "$TEST_DIR/project"
mkdir -p "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00"
mkdir -p "$TEST_DIR/project/.humanize"

cat > "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 10
session_id:
review_started: false
base_branch: main
plan_tracked: false
start_branch: main
---
EOF

printf '%s\n%s\n' "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" "$MOCK_SETUP_PATH" > "$TEST_DIR/project/.humanize/.pending-session-id"

if [[ -f "$POST_HOOK" ]]; then
    # Quoted path with suffix concatenated (no space boundary after closing quote)
    MOCK_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"\\\"${MOCK_SETUP_PATH}\\\"foo\"},\"session_id\":\"attacker\",\"transcript_path\":\"/tmp/test\",\"cwd\":\"/tmp\",\"permission_mode\":\"default\",\"hook_event_name\":\"PostToolUse\"}"
    echo "$MOCK_JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR/project" bash "$POST_HOOK" > /dev/null 2>&1 || true

    RECORDED_ID=$(grep "^session_id:" "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" | sed 's/session_id: *//')
    if [[ -z "$RECORDED_ID" ]]; then
        pass "PostToolUse hook rejects quoted-prefix concatenation"
    else
        fail "PostToolUse hook rejects quoted-prefix concatenation" "empty session_id" "$RECORDED_ID"
    fi

    if [[ -f "$TEST_DIR/project/.humanize/.pending-session-id" ]]; then
        pass "signal file preserved after quoted-prefix concatenation attempt"
    else
        fail "signal file preserved after quoted-prefix concatenation attempt" "signal file exists" "removed"
    fi
else
    skip "PostToolUse hook rejects quoted-prefix concatenation" "hook file not found"
    skip "signal file preserved after quoted-prefix concatenation attempt" "hook file not found"
fi

# ========================================
# Test: PostToolUse hook accepts unquoted setup invocation
# ========================================

setup_test_dir
init_test_git_repo "$TEST_DIR/project"
mkdir -p "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00"
mkdir -p "$TEST_DIR/project/.humanize"

cat > "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 10
session_id:
review_started: false
base_branch: main
plan_tracked: false
start_branch: main
---
EOF

printf '%s\n%s\n' "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" "$MOCK_SETUP_PATH" > "$TEST_DIR/project/.humanize/.pending-session-id"

if [[ -f "$POST_HOOK" ]]; then
    # Unquoted invocation (no surrounding quotes on path)
    MOCK_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"${MOCK_SETUP_PATH} plan.md --agent-teams\"},\"session_id\":\"unquoted-session\",\"transcript_path\":\"/tmp/test\",\"cwd\":\"/tmp\",\"permission_mode\":\"default\",\"hook_event_name\":\"PostToolUse\"}"
    echo "$MOCK_JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR/project" bash "$POST_HOOK" > /dev/null 2>&1 || true

    RECORDED_ID=$(grep "^session_id:" "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" | sed 's/session_id: *//')
    if [[ "$RECORDED_ID" == "unquoted-session" ]]; then
        pass "PostToolUse hook accepts unquoted setup invocation"
    else
        fail "PostToolUse hook accepts unquoted setup invocation" "unquoted-session" "$RECORDED_ID"
    fi
else
    skip "PostToolUse hook accepts unquoted setup invocation" "hook file not found"
fi

# ========================================
# Test: PostToolUse hook accepts tab-delimited quoted setup invocation
# ========================================

setup_test_dir
init_test_git_repo "$TEST_DIR/project"
mkdir -p "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00"
mkdir -p "$TEST_DIR/project/.humanize"

cat > "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 10
session_id:
review_started: false
base_branch: main
plan_tracked: false
start_branch: main
---
EOF

printf '%s\n%s\n' "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" "$MOCK_SETUP_PATH" > "$TEST_DIR/project/.humanize/.pending-session-id"

if [[ -f "$POST_HOOK" ]]; then
    # Quoted invocation with tab-delimited args (tab = \t in JSON)
    MOCK_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"\\\"${MOCK_SETUP_PATH}\\\"\\tplan.md\"},\"session_id\":\"tab-quoted-session\",\"transcript_path\":\"/tmp/test\",\"cwd\":\"/tmp\",\"permission_mode\":\"default\",\"hook_event_name\":\"PostToolUse\"}"
    echo "$MOCK_JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR/project" bash "$POST_HOOK" > /dev/null 2>&1 || true

    RECORDED_ID=$(grep "^session_id:" "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" | sed 's/session_id: *//')
    if [[ "$RECORDED_ID" == "tab-quoted-session" ]]; then
        pass "PostToolUse hook accepts tab-delimited quoted setup invocation"
    else
        fail "PostToolUse hook accepts tab-delimited quoted setup invocation" "tab-quoted-session" "$RECORDED_ID"
    fi

    if [[ ! -f "$TEST_DIR/project/.humanize/.pending-session-id" ]]; then
        pass "signal file consumed after tab-delimited quoted invocation"
    else
        fail "signal file consumed after tab-delimited quoted invocation" "signal file removed" "still exists"
    fi
else
    skip "PostToolUse hook accepts tab-delimited quoted setup invocation" "hook file not found"
    skip "signal file consumed after tab-delimited quoted invocation" "hook file not found"
fi

# ========================================
# Test: PostToolUse hook accepts tab-delimited unquoted setup invocation
# ========================================

setup_test_dir
init_test_git_repo "$TEST_DIR/project"
mkdir -p "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00"
mkdir -p "$TEST_DIR/project/.humanize"

cat > "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 10
session_id:
review_started: false
base_branch: main
plan_tracked: false
start_branch: main
---
EOF

printf '%s\n%s\n' "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" "$MOCK_SETUP_PATH" > "$TEST_DIR/project/.humanize/.pending-session-id"

if [[ -f "$POST_HOOK" ]]; then
    # Unquoted invocation with tab-delimited args (tab = \t in JSON)
    MOCK_JSON="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"${MOCK_SETUP_PATH}\\tplan.md --agent-teams\"},\"session_id\":\"tab-unquoted-session\",\"transcript_path\":\"/tmp/test\",\"cwd\":\"/tmp\",\"permission_mode\":\"default\",\"hook_event_name\":\"PostToolUse\"}"
    echo "$MOCK_JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR/project" bash "$POST_HOOK" > /dev/null 2>&1 || true

    RECORDED_ID=$(grep "^session_id:" "$TEST_DIR/project/.humanize/rlcr/2026-01-01_00-00-00/state.md" | sed 's/session_id: *//')
    if [[ "$RECORDED_ID" == "tab-unquoted-session" ]]; then
        pass "PostToolUse hook accepts tab-delimited unquoted setup invocation"
    else
        fail "PostToolUse hook accepts tab-delimited unquoted setup invocation" "tab-unquoted-session" "$RECORDED_ID"
    fi

    if [[ ! -f "$TEST_DIR/project/.humanize/.pending-session-id" ]]; then
        pass "signal file consumed after tab-delimited unquoted invocation"
    else
        fail "signal file consumed after tab-delimited unquoted invocation" "signal file removed" "still exists"
    fi
else
    skip "PostToolUse hook accepts tab-delimited unquoted setup invocation" "hook file not found"
    skip "signal file consumed after tab-delimited unquoted invocation" "hook file not found"
fi

# ========================================
# Print Summary
# ========================================

print_test_summary "Session ID Feature Tests"
