#!/bin/bash
#
# Tests for --agent-teams feature in RLCR loop
#
# Tests cover:
# - --agent-teams CLI option validation
# - CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS env var check
# - agent_teams field in state.md
# - parse_state_file reads agent_teams
# - Initial prompt includes team leader instructions
# - Next-round prompt includes team usage in implementation phase
# - Next-round prompt excludes team usage in review phase
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

# Source shared loop library
HOOKS_LIB_DIR="$(cd "$SCRIPT_DIR/../hooks/lib" && pwd)"
source "$HOOKS_LIB_DIR/loop-common.sh"

echo "=========================================="
echo "Agent Teams Feature Tests"
echo "=========================================="
echo ""

SETUP_SCRIPT="$SCRIPT_DIR/../scripts/setup-rlcr-loop.sh"

# ========================================
# Test: --agent-teams fails without CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS
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

echo "temp/" > "$TEST_DIR/project/.gitignore"
cd "$TEST_DIR/project"
git add .gitignore
git commit -q -m "Add gitignore"

# Run setup with --agent-teams but WITHOUT env var
cd "$TEST_DIR/project"
SETUP_OUTPUT=$(CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS="" CLAUDE_PROJECT_DIR="$TEST_DIR/project" bash "$SETUP_SCRIPT" --agent-teams temp/plan.md 2>&1) || SETUP_EXIT=$?

if [[ "${SETUP_EXIT:-0}" -ne 0 ]]; then
    pass "setup with --agent-teams fails without env var"
else
    fail "setup with --agent-teams fails without env var" "non-zero exit" "exit 0"
fi

# Check error message mentions CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS
if echo "$SETUP_OUTPUT" | grep -qi "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"; then
    pass "error message mentions CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS env var"
else
    fail "error message mentions CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS env var" "env var name in output" "$SETUP_OUTPUT"
fi

# Test: --agent-teams rejects non-"1" values like "0" and "false"
for BAD_VALUE in "0" "false" "yes" "true"; do
    SETUP_OUTPUT=$(CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS="$BAD_VALUE" CLAUDE_PROJECT_DIR="$TEST_DIR/project" bash "$SETUP_SCRIPT" --agent-teams temp/plan.md 2>&1) || SETUP_EXIT=$?
    if [[ "${SETUP_EXIT:-0}" -ne 0 ]]; then
        pass "setup rejects CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=$BAD_VALUE"
    else
        fail "setup rejects CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=$BAD_VALUE" "non-zero exit" "exit 0"
    fi
done

# ========================================
# Test: --agent-teams succeeds with env var set
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
CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 CLAUDE_PROJECT_DIR="$TEST_DIR/project" bash "$SETUP_SCRIPT" --agent-teams temp/plan.md > /dev/null 2>&1 || true

STATE_FILE=$(find "$TEST_DIR/project/.humanize/rlcr" -name "state.md" -type f 2>/dev/null | head -1)
if [[ -n "$STATE_FILE" ]]; then
    pass "setup with --agent-teams succeeds with env var set"
else
    fail "setup with --agent-teams succeeds with env var set" "state.md created" "not found"
fi

# ========================================
# Test: agent_teams: true is recorded in state.md
# ========================================

if [[ -n "$STATE_FILE" ]] && grep -q "^agent_teams: true" "$STATE_FILE"; then
    pass "agent_teams: true recorded in state.md with --agent-teams"
else
    fail "agent_teams: true recorded in state.md with --agent-teams" "agent_teams: true" "$(grep 'agent_teams' "$STATE_FILE" 2>/dev/null || echo 'not found')"
fi

# ========================================
# Test: agent_teams: false by default (without --agent-teams)
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

STATE_FILE=$(find "$TEST_DIR/project/.humanize/rlcr" -name "state.md" -type f 2>/dev/null | head -1)
if [[ -n "$STATE_FILE" ]] && grep -q "^agent_teams: false" "$STATE_FILE"; then
    pass "agent_teams: false by default without --agent-teams flag"
else
    fail "agent_teams: false by default without --agent-teams flag" "agent_teams: false" "$(grep 'agent_teams' "$STATE_FILE" 2>/dev/null || echo 'not found')"
fi

# ========================================
# Test: parse_state_file reads agent_teams field
# ========================================

setup_test_dir
mkdir -p "$TEST_DIR/loop"
cat > "$TEST_DIR/loop/state.md" << 'EOF'
---
current_round: 3
max_iterations: 20
session_id: test-session
agent_teams: true
review_started: false
base_branch: main
plan_tracked: false
start_branch: main
---
EOF

if parse_state_file "$TEST_DIR/loop/state.md"; then
    if [[ "${STATE_AGENT_TEAMS:-}" == "true" ]]; then
        pass "parse_state_file reads agent_teams: true"
    else
        fail "parse_state_file reads agent_teams: true" "true" "${STATE_AGENT_TEAMS:-empty}"
    fi
else
    fail "parse_state_file reads agent_teams: true" "successful parse" "parse failed"
fi

# ========================================
# Test: parse_state_file defaults agent_teams to false
# ========================================

setup_test_dir
mkdir -p "$TEST_DIR/loop"
cat > "$TEST_DIR/loop/state.md" << 'EOF'
---
current_round: 1
max_iterations: 10
review_started: false
base_branch: main
plan_tracked: false
start_branch: main
---
EOF

if parse_state_file "$TEST_DIR/loop/state.md"; then
    if [[ "${STATE_AGENT_TEAMS:-}" == "false" ]]; then
        pass "parse_state_file defaults agent_teams to false when missing"
    else
        fail "parse_state_file defaults agent_teams to false when missing" "false" "${STATE_AGENT_TEAMS:-empty}"
    fi
else
    fail "parse_state_file defaults agent_teams to false when missing" "successful parse" "parse failed"
fi

# ========================================
# Test: Initial prompt includes team leader instructions with --agent-teams
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
CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 CLAUDE_PROJECT_DIR="$TEST_DIR/project" bash "$SETUP_SCRIPT" --agent-teams temp/plan.md > /dev/null 2>&1 || true

PROMPT_FILE=$(find "$TEST_DIR/project/.humanize/rlcr" -name "round-0-prompt.md" -type f 2>/dev/null | head -1)

if [[ -n "$PROMPT_FILE" ]]; then
    # Check for team leader keywords
    TEAM_INSTRUCTIONS_FOUND=0
    if grep -qi "team leader" "$PROMPT_FILE"; then
        TEAM_INSTRUCTIONS_FOUND=$((TEAM_INSTRUCTIONS_FOUND + 1))
    fi
    if grep -qi "agent.team" "$PROMPT_FILE"; then
        TEAM_INSTRUCTIONS_FOUND=$((TEAM_INSTRUCTIONS_FOUND + 1))
    fi
    if grep -qi "coordinate\|coordination" "$PROMPT_FILE"; then
        TEAM_INSTRUCTIONS_FOUND=$((TEAM_INSTRUCTIONS_FOUND + 1))
    fi

    if [[ $TEAM_INSTRUCTIONS_FOUND -ge 2 ]]; then
        pass "initial prompt includes team leader instructions"
    else
        fail "initial prompt includes team leader instructions" ">=2 team keywords" "$TEAM_INSTRUCTIONS_FOUND keywords found"
    fi
else
    fail "initial prompt includes team leader instructions" "prompt file exists" "not found"
fi

# ========================================
# Test: Initial prompt WITHOUT --agent-teams has no team instructions
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

PROMPT_FILE=$(find "$TEST_DIR/project/.humanize/rlcr" -name "round-0-prompt.md" -type f 2>/dev/null | head -1)

if [[ -n "$PROMPT_FILE" ]]; then
    if ! grep -qi "team leader" "$PROMPT_FILE"; then
        pass "initial prompt without --agent-teams has no team leader instructions"
    else
        fail "initial prompt without --agent-teams has no team leader instructions" "no team leader text" "found team leader text"
    fi
else
    skip "initial prompt without --agent-teams has no team leader instructions" "prompt file not found"
fi

# ========================================
# Test: agent-teams prompt template file exists
# ========================================

TEMPLATE_FILE="$SCRIPT_DIR/../prompt-template/claude/agent-teams-instructions.md"
if [[ -f "$TEMPLATE_FILE" ]]; then
    # Check it has meaningful content (at least 100 bytes)
    FILE_SIZE=$(wc -c < "$TEMPLATE_FILE")
    if [[ $FILE_SIZE -ge 100 ]]; then
        pass "agent-teams-instructions.md template exists with content"
    else
        fail "agent-teams-instructions.md template exists with content" ">=100 bytes" "$FILE_SIZE bytes"
    fi
else
    skip "agent-teams-instructions.md template exists with content" "template file not yet created"
fi

# ========================================
# Test: agent-teams continue prompt template file exists
# ========================================

CONTINUE_TEMPLATE="$SCRIPT_DIR/../prompt-template/claude/agent-teams-continue.md"
if [[ -f "$CONTINUE_TEMPLATE" ]]; then
    FILE_SIZE=$(wc -c < "$CONTINUE_TEMPLATE")
    if [[ $FILE_SIZE -ge 50 ]]; then
        pass "agent-teams-continue.md template exists with content"
    else
        fail "agent-teams-continue.md template exists with content" ">=50 bytes" "$FILE_SIZE bytes"
    fi
else
    skip "agent-teams-continue.md template exists with content" "template file not yet created"
fi

# ========================================
# Test: find_active_loop with agent_teams in state.md
# ========================================

setup_test_dir
mkdir -p "$TEST_DIR/loop/2026-01-01_00-00-00"
cat > "$TEST_DIR/loop/2026-01-01_00-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 10
session_id: team-session-123
agent_teams: true
review_started: false
base_branch: main
plan_tracked: false
start_branch: main
---
EOF

RESULT=$(find_active_loop "$TEST_DIR/loop" "team-session-123")
if [[ -n "$RESULT" ]]; then
    pass "find_active_loop works with agent_teams in state.md"
else
    fail "find_active_loop works with agent_teams in state.md" "non-empty" "empty"
fi

# ========================================
# Stop Hook Tests: Agent-Teams Continuation in Next-Round Prompt
# ========================================
# These tests exercise the actual stop hook (loop-codex-stop-hook.sh) to verify
# that agent-teams continuation instructions appear in implementation phase
# prompts but NOT in review phase prompts.

echo ""
echo "--- Stop Hook Agent-Teams Continuation Tests ---"
echo ""

PROJECT_ROOT="$SCRIPT_DIR/.."
STOP_HOOK="$SCRIPT_DIR/../hooks/loop-codex-stop-hook.sh"

# Helper: set up a test repo and loop dir for stop hook testing
setup_stophook_test() {
    local round="$1"
    local agent_teams="$2"
    local review_started="${3:-false}"
    local base_commit="${4:-abc123}"

    setup_test_dir
    cd "$TEST_DIR"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "init" > init.txt
    git add init.txt
    git -c commit.gpgsign=false commit -q -m "Initial"

    # Create plan file
    mkdir -p plans
    cat > plans/test-plan.md << 'PLAN_EOF'
# Test Plan
## Goal
Test agent teams continuation
## Requirements
- Requirement 1
PLAN_EOF

    # Gitignore for test artifacts
    cat > .gitignore << 'GI_EOF'
plans/
.humanize/
bin/
.cache/
GI_EOF
    git add .gitignore
    git -c commit.gpgsign=false commit -q -m "Add gitignore"

    # Create loop directory
    LOOP_DIR="$TEST_DIR/.humanize/rlcr/2024-01-01_12-00-00"
    mkdir -p "$LOOP_DIR"

    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD)

    cat > "$LOOP_DIR/state.md" << STATE_EOF
---
current_round: $round
max_iterations: 42
codex_model: gpt-5.3-codex
codex_effort: xhigh
codex_timeout: 5400
push_every_round: false
plan_file: plans/test-plan.md
plan_tracked: false
start_branch: $current_branch
base_branch: main
base_commit: $base_commit
review_started: $review_started
ask_codex_question: false
full_review_round: 5
session_id:
agent_teams: $agent_teams
---
STATE_EOF

    # Create plan backup and goal tracker
    cp plans/test-plan.md "$LOOP_DIR/plan.md"
    cat > "$LOOP_DIR/goal-tracker.md" << 'GT_EOF'
# Goal Tracker
## IMMUTABLE SECTION
### Ultimate Goal
Test agent teams continuation
### Acceptance Criteria
| ID | Criterion |
|----|-----------|
| AC-1 | Test passes |
---
## MUTABLE SECTION
#### Active Tasks
| Task | Target AC | Status |
|------|-----------|--------|
| Test | AC-1 | completed |
GT_EOF

    # Create summary for current round
    cat > "$LOOP_DIR/round-${round}-summary.md" << 'SUM_EOF'
# Round Summary
Implemented features as requested.
SUM_EOF

    # Set up isolated cache directory
    export XDG_CACHE_HOME="$TEST_DIR/.cache"
    mkdir -p "$XDG_CACHE_HOME"

    # If review_started, create the marker file
    if [[ "$review_started" == "true" ]]; then
        echo "build_finish_round=$round" > "$LOOP_DIR/.review-phase-started"
    fi
}

# Helper: set up mock codex for implementation phase (codex exec outputs feedback)
setup_mock_codex_impl_feedback() {
    local feedback="$1"
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/codex" << MOCK_EOF
#!/bin/bash
if [[ "\$1" == "exec" ]]; then
    cat << 'REVIEW'
$feedback
REVIEW
elif [[ "\$1" == "review" ]]; then
    echo "No issues found."
fi
MOCK_EOF
    chmod +x "$TEST_DIR/bin/codex"
    export PATH="$TEST_DIR/bin:$PATH"
}

# Helper: set up mock codex for review phase (codex review outputs issues)
setup_mock_codex_review_issues() {
    local review_output="$1"
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/codex" << MOCK_EOF
#!/bin/bash
if [[ "\$1" == "exec" ]]; then
    echo "Should not be called in review phase"
elif [[ "\$1" == "review" ]]; then
    cat << 'REVIEWOUT'
$review_output
REVIEWOUT
fi
MOCK_EOF
    chmod +x "$TEST_DIR/bin/codex"
    export PATH="$TEST_DIR/bin:$PATH"
}

# ========================================
# Test: Implementation phase with agent_teams=true includes continuation
# ========================================

setup_stophook_test 3 "true" "false"
setup_mock_codex_impl_feedback "## Review Feedback

Some issues found:
- Issue 1: Missing error handling

Please address and try again.

CONTINUE"

HOOK_INPUT='{"stop_hook_active": false, "transcript": [], "session_id": ""}'
set +e
RESULT=$(echo "$HOOK_INPUT" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$STOP_HOOK" 2>/dev/null)
HOOK_EXIT=$?
set -e

# The hook should block exit and generate a next-round prompt
NEXT_PROMPT="$LOOP_DIR/round-4-prompt.md"
if [[ -f "$NEXT_PROMPT" ]]; then
    if grep -qi "Agent Teams" "$NEXT_PROMPT"; then
        pass "impl phase with agent_teams=true: next-round prompt contains agent-teams continuation"
    else
        fail "impl phase with agent_teams=true: next-round prompt contains agent-teams continuation" "agent-teams text in prompt" "not found"
    fi
    if grep -qi "team leader" "$NEXT_PROMPT"; then
        pass "impl phase continuation includes team leader role reminder"
    else
        fail "impl phase continuation includes team leader role reminder" "team leader text" "not found"
    fi
else
    fail "impl phase with agent_teams=true: next-round prompt contains agent-teams continuation" "round-4-prompt.md exists" "not found (hook exit=$HOOK_EXIT)"
fi

# ========================================
# Test: Implementation phase with agent_teams=false has no continuation
# ========================================

setup_stophook_test 3 "false" "false"
setup_mock_codex_impl_feedback "## Review Feedback

Some issues found:
- Issue 1: Missing error handling

Please address and try again.

CONTINUE"

HOOK_INPUT='{"stop_hook_active": false, "transcript": [], "session_id": ""}'
set +e
RESULT=$(echo "$HOOK_INPUT" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$STOP_HOOK" 2>/dev/null)
set -e

NEXT_PROMPT="$LOOP_DIR/round-4-prompt.md"
if [[ -f "$NEXT_PROMPT" ]]; then
    if ! grep -qi "Agent Teams" "$NEXT_PROMPT"; then
        pass "impl phase with agent_teams=false: no agent-teams continuation in prompt"
    else
        fail "impl phase with agent_teams=false: no agent-teams continuation in prompt" "no agent-teams text" "found agent-teams text"
    fi
else
    fail "impl phase with agent_teams=false: no agent-teams continuation in prompt" "round-4-prompt.md exists" "not found"
fi

# ========================================
# Test: Review phase with agent_teams=true has NO continuation
# ========================================

setup_stophook_test 5 "true" "true"
setup_mock_codex_review_issues "[P1] Security issue: SQL injection in query builder
- File: src/db.py:42
- Fix: Use parameterized queries"

HOOK_INPUT='{"stop_hook_active": false, "transcript": [], "session_id": ""}'
set +e
RESULT=$(echo "$HOOK_INPUT" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$STOP_HOOK" 2>/dev/null)
set -e

# In review phase, the prompt is generated by continue_review_loop_with_issues()
# which uses review-phase-prompt.md template - should NOT include agent-teams
NEXT_PROMPT="$LOOP_DIR/round-6-prompt.md"
if [[ -f "$NEXT_PROMPT" ]]; then
    if ! grep -qi "Agent Teams" "$NEXT_PROMPT"; then
        pass "review phase with agent_teams=true: no agent-teams continuation in prompt"
    else
        fail "review phase with agent_teams=true: no agent-teams continuation in prompt" "no agent-teams text" "found agent-teams text"
    fi
    # Verify it IS a review-phase prompt (should mention P1 issues)
    if grep -q "P1" "$NEXT_PROMPT"; then
        pass "review phase prompt contains code review issues"
    else
        fail "review phase prompt contains code review issues" "P1 in prompt" "not found"
    fi
else
    fail "review phase with agent_teams=true: no agent-teams continuation in prompt" "round-6-prompt.md exists" "not found"
fi

# ========================================
# Print Summary
# ========================================

print_test_summary "Agent Teams Feature Tests"
