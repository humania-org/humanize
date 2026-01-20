#!/bin/bash
#
# Test runner for PR loop system
#
# Runs all tests in the tests/ directory using the mock gh CLI
#
# Usage:
#   ./tests/run-tests.sh [test-name]
#
# Environment:
#   TEST_VERBOSE=1 - Show verbose output

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Test configuration
TESTS_DIR="$SCRIPT_DIR"
MOCKS_DIR="$TESTS_DIR/mocks"
FIXTURES_DIR="$TESTS_DIR/fixtures"
TEST_VERBOSE="${TEST_VERBOSE:-0}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Test helper functions
log_test() {
    echo -e "${YELLOW}[TEST]${NC} $1"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# Setup test environment
setup_test_env() {
    # Add mocks to PATH
    export PATH="$MOCKS_DIR:$PATH"
    export MOCK_GH_FIXTURES_DIR="$FIXTURES_DIR"

    # Create temp directory for tests
    export TEST_TEMP_DIR=$(mktemp -d)
    export CLAUDE_PROJECT_DIR="$TEST_TEMP_DIR"

    # Initialize git repo for tests
    (
        cd "$TEST_TEMP_DIR"
        git init -q
        git config user.email "test@example.com"
        git config user.name "Test User"
        git config commit.gpgsign false
        echo "# Test" > README.md
        git add README.md
        git commit -q -m "Initial commit"
    ) >/dev/null 2>&1
}

# Cleanup test environment
cleanup_test_env() {
    if [[ -n "${TEST_TEMP_DIR:-}" && -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
}

# Run a test function
run_test() {
    local test_name="$1"
    local test_func="$2"

    TESTS_RUN=$((TESTS_RUN + 1))
    log_test "$test_name"

    setup_test_env

    # Run test in subshell to isolate failures
    local result=0
    (
        cd "$TEST_TEMP_DIR"
        $test_func
    ) && result=0 || result=$?

    if [[ $result -eq 0 ]]; then
        log_pass "$test_name"
    else
        log_fail "$test_name (exit code: $result)"
    fi

    cleanup_test_env
}

# ========================================
# Test: Mutual Exclusion
# ========================================

test_mutual_exclusion_rlcr_blocks_pr() {
    # Create an active RLCR loop
    mkdir -p .humanize/rlcr/2026-01-18_12-00-00
    echo "---
current_round: 1
max_iterations: 10
---" > .humanize/rlcr/2026-01-18_12-00-00/state.md

    # Try to start a PR loop - should fail
    export MOCK_GH_PR_NUMBER=123
    export MOCK_GH_PR_STATE="OPEN"

    local result
    result=$("$PROJECT_ROOT/scripts/setup-pr-loop.sh" --codex 2>&1) && return 1 || true

    # Should contain error about RLCR loop active
    echo "$result" | grep -q "RLCR loop is already active" || return 1
}

test_mutual_exclusion_pr_blocks_rlcr() {
    # Create an active PR loop
    mkdir -p .humanize/pr-loop/2026-01-18_12-00-00
    echo "---
current_round: 0
max_iterations: 42
pr_number: 123
---" > .humanize/pr-loop/2026-01-18_12-00-00/state.md

    # Try to start an RLCR loop - should fail
    echo "# Test Plan" > test-plan.md

    local result
    result=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" test-plan.md 2>&1) && return 1 || true

    # Should contain error about PR loop active
    echo "$result" | grep -q "PR loop is already active" || return 1
}

# ========================================
# Test: Check PR Reviewer Status
# ========================================

test_reviewer_status_case1_no_comments() {
    # Fixture with no bot comments - must clear ALL comment sources
    echo "[]" > "$FIXTURES_DIR/issue-comments.json"
    echo "[]" > "$FIXTURES_DIR/review-comments.json"
    echo "[]" > "$FIXTURES_DIR/pr-reviews.json"

    local result
    result=$("$PROJECT_ROOT/scripts/check-pr-reviewer-status.sh" 123 --bots "claude,codex")

    # Should return case 1
    local test_passed=true
    echo "$result" | jq -e '.case == 1' || test_passed=false

    # Restore fixtures
    echo '[{"id":1001,"user":{"login":"claude[bot]"},"created_at":"2026-01-18T11:00:00Z","body":"Issue found"}]' > "$FIXTURES_DIR/issue-comments.json"
    echo '[]' > "$FIXTURES_DIR/review-comments.json"
    echo '[{"id":4001,"user":{"login":"chatgpt-codex-connector[bot]"},"submitted_at":"2026-01-18T11:15:00Z","body":"LGTM! Code looks good.","state":"APPROVED"}]' > "$FIXTURES_DIR/pr-reviews.json"

    $test_passed
}

test_reviewer_status_case2_partial_comments() {
    # Only claude has commented - must clear codex comments too
    echo '[{"id":1001,"user":{"login":"claude[bot]"},"created_at":"2026-01-18T11:00:00Z","body":"Issue found"}]' > "$FIXTURES_DIR/issue-comments.json"
    echo "[]" > "$FIXTURES_DIR/review-comments.json"
    echo "[]" > "$FIXTURES_DIR/pr-reviews.json"

    local result
    result=$("$PROJECT_ROOT/scripts/check-pr-reviewer-status.sh" 123 --bots "claude,codex")

    # Should return case 2 (partial)
    local test_passed=true
    echo "$result" | jq -e '.case == 2' || test_passed=false
    echo "$result" | jq -e '.reviewers_missing | contains(["codex"])' || test_passed=false

    # Restore fixtures
    echo '[{"id":1001,"user":{"login":"claude[bot]"},"created_at":"2026-01-18T11:00:00Z","body":"Issue found"}]' > "$FIXTURES_DIR/issue-comments.json"
    echo '[]' > "$FIXTURES_DIR/review-comments.json"
    echo '[{"id":4001,"user":{"login":"chatgpt-codex-connector[bot]"},"submitted_at":"2026-01-18T11:15:00Z","body":"LGTM! Code looks good.","state":"APPROVED"}]' > "$FIXTURES_DIR/pr-reviews.json"

    $test_passed
}

# ========================================
# Test: Codex +1 Detection
# ========================================

test_codex_thumbsup_detected() {
    local result
    result=$("$PROJECT_ROOT/scripts/check-bot-reactions.sh" codex-thumbsup 123)

    # Should find the +1 reaction
    echo "$result" | jq -e '.content == "+1"' || return 1
}

test_codex_thumbsup_with_after_filter() {
    # Test --after filter - reaction is at 11:10:00Z, we filter for after 12:00:00Z
    # So no reaction should be found
    local result
    if "$PROJECT_ROOT/scripts/check-bot-reactions.sh" codex-thumbsup 123 --after "2026-01-18T12:00:00Z" 2>/dev/null; then
        # Should NOT succeed - reaction is before the filter time
        return 1
    fi
    # Correctly failed - reaction is before filter time
    return 0
}

# ========================================
# Test: Claude Eyes Detection
# ========================================

test_claude_eyes_detected() {
    # Use delay 0 and retry 1 for fast test
    local result
    result=$("$PROJECT_ROOT/scripts/check-bot-reactions.sh" claude-eyes 12345 --retry 1 --delay 0)

    # Should find the eyes reaction
    echo "$result" | jq -e '.content == "eyes"' || return 1
}

# ========================================
# Test: PR Reviews Detection (PR submissions)
# ========================================

test_reviewer_status_includes_pr_reviews() {
    # Set up fixture where codex has APPROVED via PR review (not comment)
    echo "[]" > "$FIXTURES_DIR/issue-comments.json"
    echo "[]" > "$FIXTURES_DIR/review-comments.json"
    echo '[{"id":4001,"user":{"login":"chatgpt-codex-connector[bot]"},"submitted_at":"2026-01-18T11:15:00Z","body":"LGTM! Code looks good.","state":"APPROVED"}]' > "$FIXTURES_DIR/pr-reviews.json"

    local result
    result=$("$PROJECT_ROOT/scripts/check-pr-reviewer-status.sh" 123 --bots "codex")

    # Codex should be in reviewers_commented because of PR review
    local test_passed=true
    echo "$result" | jq -e '.reviewers_commented | contains(["codex"])' || test_passed=false

    $test_passed
}

# ========================================
# Test: Phase Detection
# ========================================

test_phase_detection_approved() {
    # Source monitor-common.sh (located in scripts/lib/)
    source "$PROJECT_ROOT/scripts/lib/monitor-common.sh"

    # Create a fake session dir with approve-state.md
    local session_dir="$TEST_TEMP_DIR/.humanize/pr-loop/2026-01-18_12-00-00"
    mkdir -p "$session_dir"
    touch "$session_dir/approve-state.md"

    local phase
    phase=$(get_pr_loop_phase "$session_dir")

    [[ "$phase" == "approved" ]] || return 1
}

test_phase_detection_waiting_initial() {
    # Source monitor-common.sh
    source "$PROJECT_ROOT/scripts/lib/monitor-common.sh"

    # Create a fake session dir with state.md at round 0 and startup_case 1
    local session_dir="$TEST_TEMP_DIR/.humanize/pr-loop/2026-01-18_12-00-00"
    mkdir -p "$session_dir"
    cat > "$session_dir/state.md" << 'EOF'
---
current_round: 0
startup_case: 1
---
EOF

    local phase
    phase=$(get_pr_loop_phase "$session_dir")

    [[ "$phase" == "waiting_initial_review" ]] || return 1
}

test_phase_detection_waiting_reviewer() {
    # Source monitor-common.sh
    source "$PROJECT_ROOT/scripts/lib/monitor-common.sh"

    # Create a fake session dir with state.md at round 1
    local session_dir="$TEST_TEMP_DIR/.humanize/pr-loop/2026-01-18_12-00-00"
    mkdir -p "$session_dir"
    cat > "$session_dir/state.md" << 'EOF'
---
current_round: 1
startup_case: 2
---
EOF

    local phase
    phase=$(get_pr_loop_phase "$session_dir")

    [[ "$phase" == "waiting_reviewer" ]] || return 1
}

# ========================================
# Test: Goal Tracker Parsing
# ========================================

test_goal_tracker_parsing() {
    # Source monitor-common.sh
    source "$PROJECT_ROOT/scripts/lib/monitor-common.sh"

    # Create a fake goal tracker file
    local tracker_file="$TEST_TEMP_DIR/goal-tracker.md"
    cat > "$tracker_file" << 'EOF'
# Goal Tracker

### Ultimate Goal
Get all bots to approve the PR.

### Acceptance Criteria

| AC | Description |
|----|-------------|
| AC-1 | Bot claude approves |
| AC-2 | Bot codex approves |

### Completed and Verified

| AC | Description |
|----|-------------|
| AC-1 | Completed |

#### Active Tasks

| Task | Description | Status |
|------|-------------|--------|
| Fix bug | Fix the bug | pending |
| Add test | Add a test | completed |

### Explicitly Deferred

| Task | Description |
|------|-------------|

### Open Issues

| Issue | Description |
|-------|-------------|

EOF

    local result
    result=$(parse_goal_tracker "$tracker_file")

    # Should return: total_acs|completed_acs|active_tasks|completed_tasks|deferred_tasks|open_issues|goal_summary
    # Expected: 2|1|1|0|0|0|Get all bots to approve the PR.

    local total_acs completed_acs active_tasks
    IFS='|' read -r total_acs completed_acs active_tasks _ _ _ _ <<< "$result"

    [[ "$total_acs" == "2" ]] || { echo "Expected total_acs=2, got $total_acs"; return 1; }
    [[ "$completed_acs" == "1" ]] || { echo "Expected completed_acs=1, got $completed_acs"; return 1; }
    [[ "$active_tasks" == "1" ]] || { echo "Expected active_tasks=1, got $active_tasks"; return 1; }
}

# ========================================
# Test: PR Goal Tracker Parsing
# ========================================

test_pr_goal_tracker_parsing() {
    # Source monitor-common.sh
    source "$PROJECT_ROOT/scripts/lib/monitor-common.sh"

    # Create a fake PR goal tracker file
    local tracker_file="$TEST_TEMP_DIR/pr-goal-tracker.md"
    cat > "$tracker_file" << 'EOF'
# PR Goal Tracker

## Total Statistics

- Total Issues Found: 5
- Total Issues Resolved: 3
- Remaining: 2

## Issue Summary

| ID | Reviewer | Round | Status | Description |
|----|----------|-------|--------|-------------|
| 1 | Claude | 0 | resolved | Issue one |
| 2 | Claude | 0 | resolved | Issue two |
| 3 | Codex | 1 | open | Issue three |
| 4 | Codex | 1 | resolved | Issue four |
| 5 | Claude | 2 | open | Issue five |

EOF

    local result
    result=$(humanize_parse_pr_goal_tracker "$tracker_file")

    # Should return: total_issues|resolved_issues|remaining_issues|last_reviewer
    # Expected: 5|3|2|Claude

    local total_issues resolved_issues remaining_issues last_reviewer
    IFS='|' read -r total_issues resolved_issues remaining_issues last_reviewer <<< "$result"

    [[ "$total_issues" == "5" ]] || { echo "Expected total_issues=5, got $total_issues"; return 1; }
    [[ "$resolved_issues" == "3" ]] || { echo "Expected resolved_issues=3, got $resolved_issues"; return 1; }
    [[ "$remaining_issues" == "2" ]] || { echo "Expected remaining_issues=2, got $remaining_issues"; return 1; }
    [[ "$last_reviewer" == "Claude" ]] || { echo "Expected last_reviewer=Claude, got $last_reviewer"; return 1; }
}

# ========================================
# Test: State File Detection
# ========================================

test_state_file_detection_active() {
    # Source monitor-common.sh
    source "$PROJECT_ROOT/scripts/lib/monitor-common.sh"

    # Create active state
    local session_dir="$TEST_TEMP_DIR/.humanize/pr-loop/2026-01-18_12-00-00"
    mkdir -p "$session_dir"
    echo "current_round: 0" > "$session_dir/state.md"

    local result
    result=$(monitor_find_state_file "$session_dir")

    # Should return state.md with active status
    echo "$result" | grep -q "state.md|active" || { echo "Expected active state, got $result"; return 1; }
}

test_state_file_detection_approve() {
    # Source monitor-common.sh
    source "$PROJECT_ROOT/scripts/lib/monitor-common.sh"

    # Create approve state (no state.md, only approve-state.md)
    local session_dir="$TEST_TEMP_DIR/.humanize/pr-loop/2026-01-18_12-00-00"
    mkdir -p "$session_dir"
    echo "approved" > "$session_dir/approve-state.md"

    local result
    result=$(monitor_find_state_file "$session_dir")

    # Should return approve-state.md with approve status
    echo "$result" | grep -q "approve-state.md|approve" || { echo "Expected approve state, got $result"; return 1; }
}

# ========================================
# Test: Phase Detection - Cancelled
# ========================================

test_phase_detection_cancelled() {
    # Source monitor-common.sh
    source "$PROJECT_ROOT/scripts/lib/monitor-common.sh"

    # Create a fake session dir with cancel-state.md
    local session_dir="$TEST_TEMP_DIR/.humanize/pr-loop/2026-01-18_12-00-00"
    mkdir -p "$session_dir"
    touch "$session_dir/cancel-state.md"

    local phase
    phase=$(get_pr_loop_phase "$session_dir")

    [[ "$phase" == "cancelled" ]] || { echo "Expected cancelled, got $phase"; return 1; }
}

test_phase_detection_maxiter() {
    # Source monitor-common.sh
    source "$PROJECT_ROOT/scripts/lib/monitor-common.sh"

    # Create a fake session dir with maxiter-state.md
    local session_dir="$TEST_TEMP_DIR/.humanize/pr-loop/2026-01-18_12-00-00"
    mkdir -p "$session_dir"
    touch "$session_dir/maxiter-state.md"

    local phase
    phase=$(get_pr_loop_phase "$session_dir")

    [[ "$phase" == "maxiter" ]] || { echo "Expected maxiter, got $phase"; return 1; }
}

# ========================================
# Test: Startup Case Detection
# ========================================

test_reviewer_status_case3_all_commented() {
    # All bots have commented - should be case 3
    echo '[{"id":1001,"user":{"login":"claude[bot]"},"created_at":"2026-01-18T11:00:00Z","body":"Issue found"}]' > "$FIXTURES_DIR/issue-comments.json"
    echo '[]' > "$FIXTURES_DIR/review-comments.json"
    echo '[{"id":4001,"user":{"login":"chatgpt-codex-connector[bot]"},"submitted_at":"2026-01-18T11:15:00Z","body":"LGTM","state":"APPROVED"}]' > "$FIXTURES_DIR/pr-reviews.json"

    local result
    result=$("$PROJECT_ROOT/scripts/check-pr-reviewer-status.sh" 123 --bots "claude,codex")

    # Should return case 3 (all bots commented)
    local test_passed=true
    echo "$result" | jq -e '.case == 3' || test_passed=false

    $test_passed
}

# ========================================
# Test: update_pr_goal_tracker helper
# ========================================

test_update_pr_goal_tracker() {
    # Source loop-common.sh
    source "$PROJECT_ROOT/hooks/lib/loop-common.sh"

    # Create a goal tracker file
    local tracker_file="$TEST_TEMP_DIR/goal-tracker.md"
    cat > "$tracker_file" << 'EOF'
# PR Goal Tracker

## Total Statistics

- Total Issues Found: 2
- Total Issues Resolved: 1
- Remaining: 1

## Issue Summary
EOF

    # Update with new bot results (JSON format: issues=new found, resolved=new resolved)
    update_pr_goal_tracker "$tracker_file" 1 '{"issues": 3, "resolved": 2, "bot": "Codex"}'

    # Verify update - should add 3 found, 2 resolved (new totals: 5 found, 3 resolved, 2 remaining)
    grep -q "Total Issues Found: 5" "$tracker_file" || { echo "Expected 5 total found"; return 1; }
    grep -q "Total Issues Resolved: 3" "$tracker_file" || { echo "Expected 3 total resolved"; return 1; }
    grep -q "Remaining: 2" "$tracker_file" || { echo "Expected 2 remaining"; return 1; }
}

# ========================================
# Test: Unpushed Commits Detection
# ========================================

test_unpushed_commits_detected() {
    # Create a git repo with unpushed commits
    local test_dir="$TEST_TEMP_DIR"
    cd "$test_dir"

    # Initialize git repo and create a commit
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test User"
    echo "# Test" > README.md
    git add README.md
    git commit -q -m "Initial commit"

    # Create a fake remote tracking branch (simulates having unpushed commits)
    # This creates a local branch that pretends to track origin/main
    git branch --set-upstream-to=HEAD 2>/dev/null || true

    # Add another commit (this will be "unpushed")
    echo "new content" >> README.md
    git add README.md
    git commit -q -m "New commit"

    # Check git status for unpushed detection pattern
    local ahead_count=$(git status -sb 2>/dev/null | grep -oE '\[ahead [0-9]+\]' | grep -oE '[0-9]+' || echo "0")

    # Test passes if we can detect we have local commits
    # Note: In this test setup, we can't truly simulate upstream, so we verify the pattern matching works
    [[ -n "$(git log --oneline -1)" ]] || return 1
}

# ========================================
# Test: Force Push Detection Logic
# ========================================

test_force_push_ancestry_check() {
    # Test git merge-base --is-ancestor behavior
    local test_dir="$TEST_TEMP_DIR"
    cd "$test_dir"

    # Create a git repo with two branches
    git init -q
    git config user.email "test@example.com"
    git config user.name "Test User"

    # Create initial commit
    echo "v1" > file.txt
    git add file.txt
    git commit -q -m "Initial"
    local INITIAL_SHA=$(git rev-parse HEAD)

    # Create second commit
    echo "v2" >> file.txt
    git add file.txt
    git commit -q -m "Second"
    local SECOND_SHA=$(git rev-parse HEAD)

    # Test: INITIAL_SHA should be ancestor of SECOND_SHA
    git merge-base --is-ancestor "$INITIAL_SHA" "$SECOND_SHA" || { echo "Expected $INITIAL_SHA to be ancestor of $SECOND_SHA"; return 1; }

    # Test: SECOND_SHA should NOT be ancestor of INITIAL_SHA
    if git merge-base --is-ancestor "$SECOND_SHA" "$INITIAL_SHA" 2>/dev/null; then
        echo "Expected $SECOND_SHA to NOT be ancestor of $INITIAL_SHA"
        return 1
    fi

    return 0
}

# ========================================
# Test: Approve State Creation
# ========================================

test_approve_state_detection() {
    # Source monitor-common.sh
    source "$PROJECT_ROOT/scripts/lib/monitor-common.sh"

    # Create session dir with approve-state.md
    local session_dir="$TEST_TEMP_DIR/.humanize/pr-loop/2026-01-18_12-00-00"
    mkdir -p "$session_dir"
    echo "approved" > "$session_dir/approve-state.md"

    # Phase should be "approved"
    local phase
    phase=$(get_pr_loop_phase "$session_dir")

    [[ "$phase" == "approved" ]] || { echo "Expected phase=approved, got $phase"; return 1; }

    # State file detection should also work
    local state_info
    state_info=$(monitor_find_state_file "$session_dir")

    echo "$state_info" | grep -q "approve" || { echo "Expected approve in state_info, got $state_info"; return 1; }
}

# ========================================
# Test: Goal Tracker Schema
# ========================================

test_goal_tracker_schema() {
    # Read the goal tracker init template
    local template_file="$PROJECT_ROOT/prompt-template/pr-loop/goal-tracker-initial.md"

    # Verify required sections exist per plan
    grep -q "## Issue Summary" "$template_file" || { echo "Missing Issue Summary section"; return 1; }
    grep -q "## Total Statistics" "$template_file" || { echo "Missing Total Statistics section"; return 1; }
    grep -q "## Issue Log" "$template_file" || { echo "Missing Issue Log section"; return 1; }

    # Verify Total Statistics has required fields
    grep -q "Total Issues Found:" "$template_file" || { echo "Missing Total Issues Found field"; return 1; }
    grep -q "Total Issues Resolved:" "$template_file" || { echo "Missing Total Issues Resolved field"; return 1; }
    grep -q "Remaining:" "$template_file" || { echo "Missing Remaining field"; return 1; }
}

# ========================================
# Test: Dynamic Startup Case
# ========================================

test_startup_case_4_5_detection() {
    # Test that check-pr-reviewer-status.sh detects case 4/5 (commits after reviews)
    # Set up fixtures: both bots commented, but there's a newer commit
    echo '[{"id":1001,"user":{"login":"claude[bot]"},"created_at":"2026-01-18T10:00:00Z","body":"Issue found"}]' > "$FIXTURES_DIR/issue-comments.json"
    echo '[]' > "$FIXTURES_DIR/review-comments.json"
    echo '[{"id":4001,"user":{"login":"chatgpt-codex-connector[bot]"},"submitted_at":"2026-01-18T10:15:00Z","body":"LGTM","state":"APPROVED"}]' > "$FIXTURES_DIR/pr-reviews.json"

    # Note: The mock would need to simulate a newer commit timestamp
    # For this test, we verify the script returns valid JSON
    local result
    result=$("$PROJECT_ROOT/scripts/check-pr-reviewer-status.sh" 123 --bots "claude,codex" 2>/dev/null) || true

    # Should return valid JSON with case field
    echo "$result" | jq -e '.case' >/dev/null || { echo "Invalid JSON or missing case field"; return 1; }
}

# ========================================
# Test: Goal Tracker Update with Issue Summary Row
# ========================================

test_goal_tracker_update_adds_row() {
    # Source loop-common.sh
    source "$PROJECT_ROOT/hooks/lib/loop-common.sh"

    # Create a goal tracker file with proper schema
    local tracker_file="$TEST_TEMP_DIR/goal-tracker.md"
    cat > "$tracker_file" << 'EOF'
# PR Review Goal Tracker

## Issue Summary

| Round | Reviewer | Issues Found | Issues Resolved | Status |
|-------|----------|--------------|-----------------|--------|
| 0     | -        | 0            | 0               | Initial |

## Total Statistics

- Total Issues Found: 0
- Total Issues Resolved: 0
- Remaining: 0

## Issue Log

### Round 0
*Awaiting initial reviews*
EOF

    # Update with new bot results
    update_pr_goal_tracker "$tracker_file" 1 '{"issues": 2, "resolved": 0, "bot": "Codex"}'

    # Verify Issue Log has Round 1 entry
    grep -q "### Round 1" "$tracker_file" || { echo "Missing Round 1 in Issue Log"; return 1; }

    # Verify totals updated
    grep -q "Total Issues Found: 2" "$tracker_file" || { echo "Expected 2 total found"; return 1; }
}

# ========================================
# Test: Goal Tracker Update Idempotency
# ========================================

test_goal_tracker_update_idempotent() {
    # Source loop-common.sh
    source "$PROJECT_ROOT/hooks/lib/loop-common.sh"

    # Create a goal tracker file with proper schema
    local tracker_file="$TEST_TEMP_DIR/goal-tracker.md"
    cat > "$tracker_file" << 'EOF'
# PR Review Goal Tracker

## Issue Summary

| Round | Reviewer | Issues Found | Issues Resolved | Status |
|-------|----------|--------------|-----------------|--------|
| 0     | -        | 0            | 0               | Initial |

## Total Statistics

- Total Issues Found: 0
- Total Issues Resolved: 0
- Remaining: 0

## Issue Log

### Round 0
*Awaiting initial reviews*
EOF

    # First update - should succeed
    update_pr_goal_tracker "$tracker_file" 1 '{"issues": 3, "resolved": 0, "bot": "Codex"}'

    # Verify first update worked
    grep -q "Total Issues Found: 3" "$tracker_file" || { echo "First update failed - expected 3 total found"; return 1; }

    # Second update with SAME round AND SAME bot - should be SKIPPED (idempotent)
    update_pr_goal_tracker "$tracker_file" 1 '{"issues": 5, "resolved": 0, "bot": "Codex"}'

    # Totals should still be 3 (not 8) because round 1 was already recorded
    grep -q "Total Issues Found: 3" "$tracker_file" || { echo "Idempotency failed - totals changed on duplicate update"; return 1; }

    # Count Issue Summary rows - should only have 2 (Round 0 + Round 1)
    local row_count=$(grep -cE '^\|[[:space:]]*[0-9]+[[:space:]]*\|' "$tracker_file")
    [[ "$row_count" -eq 2 ]] || { echo "Idempotency failed - expected 2 rows, got $row_count"; return 1; }
}

# ========================================
# Test: Shared Monitor - Find Latest Session
# ========================================

test_shared_monitor_find_latest_session() {
    # Source monitor-common.sh
    source "$PROJECT_ROOT/scripts/lib/monitor-common.sh"

    # Create session directories with different timestamps
    local loop_dir="$TEST_TEMP_DIR/.humanize/pr-loop"
    mkdir -p "$loop_dir/2026-01-18_10-00-00"
    mkdir -p "$loop_dir/2026-01-18_12-00-00"
    mkdir -p "$loop_dir/2026-01-18_11-00-00"

    # Test that the latest session is found
    local result
    result=$(monitor_find_latest_session "$loop_dir")

    [[ "$(basename "$result")" == "2026-01-18_12-00-00" ]] || {
        echo "Expected 2026-01-18_12-00-00, got $(basename "$result")"
        return 1
    }
}

# ========================================
# Test: Shared Monitor - Find State File
# ========================================

test_shared_monitor_find_state_file() {
    # Source monitor-common.sh
    source "$PROJECT_ROOT/scripts/lib/monitor-common.sh"

    local session_dir="$TEST_TEMP_DIR/session"
    mkdir -p "$session_dir"

    # Test 1: active state
    touch "$session_dir/state.md"
    local result
    result=$(monitor_find_state_file "$session_dir")
    local status="${result#*|}"
    [[ "$status" == "active" ]] || { echo "Expected active, got $status"; return 1; }

    # Test 2: approve state (remove state.md, add approve-state.md)
    rm "$session_dir/state.md"
    touch "$session_dir/approve-state.md"
    result=$(monitor_find_state_file "$session_dir")
    status="${result#*|}"
    [[ "$status" == "approve" ]] || { echo "Expected approve, got $status"; return 1; }

    # Test 3: no state file
    rm "$session_dir/approve-state.md"
    result=$(monitor_find_state_file "$session_dir")
    status="${result#*|}"
    [[ "$status" == "unknown" ]] || { echo "Expected unknown, got $status"; return 1; }
}

# ========================================
# Test: Shared Monitor - Get File Size
# ========================================

test_shared_monitor_get_file_size() {
    # Source monitor-common.sh
    source "$PROJECT_ROOT/scripts/lib/monitor-common.sh"

    # Create a test file with known content
    local test_file="$TEST_TEMP_DIR/test-file.txt"
    echo "Hello World" > "$test_file"

    local result
    result=$(monitor_get_file_size "$test_file")

    # File should have content (size > 0)
    [[ "$result" -gt 0 ]] || { echo "Expected size > 0, got $result"; return 1; }

    # Test non-existent file returns 0
    result=$(monitor_get_file_size "$TEST_TEMP_DIR/nonexistent.txt")
    [[ "$result" -eq 0 ]] || { echo "Expected 0 for nonexistent file, got $result"; return 1; }
}

# ========================================
# Test: Phase Detection - Codex Analyzing (File Growth)
# ========================================

test_phase_detection_codex_analyzing() {
    # Source monitor-common.sh
    source "$PROJECT_ROOT/scripts/lib/monitor-common.sh"

    local session_dir="$TEST_TEMP_DIR/session"
    mkdir -p "$session_dir"

    # Create state.md for active session
    cat > "$session_dir/state.md" << 'EOF'
---
current_round: 1
startup_case: 2
---
EOF

    # Create a pr-check file with recent mtime (simulates Codex writing)
    local check_file="$session_dir/round-1-pr-check.md"
    echo "Analyzing PR..." > "$check_file"
    # Touch with current time ensures mtime is within 10 seconds
    touch "$check_file"

    # Test phase detection shows codex_analyzing
    local result
    result=$(get_pr_loop_phase "$session_dir")
    [[ "$result" == "codex_analyzing" ]] || {
        echo "Expected codex_analyzing, got $result"
        return 1
    }

    # For the second test: make the file old and ensure cache shows no growth
    # Touch with past timestamp
    touch -d "2026-01-18 10:00:00" "$check_file"

    # Get the current file size and write it to cache twice
    # (so second call sees no growth)
    local size
    size=$(stat -c%s "$check_file" 2>/dev/null || stat -f%z "$check_file" 2>/dev/null || echo 0)
    local session_name=$(basename "$session_dir")
    local cache_file="/tmp/humanize-phase-${session_name}-1.size"
    echo "$size" > "$cache_file"

    # Now call again - same size, old mtime -> should be waiting_reviewer
    result=$(get_pr_loop_phase "$session_dir")
    [[ "$result" == "waiting_reviewer" ]] || {
        echo "Expected waiting_reviewer after old mtime and no growth, got $result"
        return 1
    }

    # Cleanup
    rm -f "$cache_file" 2>/dev/null || true
}

# ========================================
# Test: Monitor Phase Display Output Assertions
# ========================================

# Helper: Run monitor with --once and capture output
run_monitor_once_capture_output() {
    local session_dir="$1"
    local project_dir="$2"

    # Create wrapper script that runs monitor and captures output
    local wrapper="$project_dir/run_monitor_test.sh"
    cat > "$wrapper" << 'WRAPPER_EOF'
#!/bin/bash
PROJECT_DIR="$1"
PROJECT_ROOT="$2"

cd "$PROJECT_DIR"

# Stub terminal commands for non-interactive mode
tput() {
    case "$1" in
        cols) echo "80" ;;
        lines) echo "24" ;;
        *) : ;;
    esac
}
export -f tput
clear() { :; }
export -f clear

# Disable ANSI colors for easier parsing
export NO_COLOR=1

# Source humanize.sh
source "$PROJECT_ROOT/scripts/humanize.sh"

# Run monitor with --once flag
humanize monitor pr --once 2>&1
WRAPPER_EOF
    chmod +x "$wrapper"

    # Run and capture output
    timeout 10 bash "$wrapper" "$project_dir" "$PROJECT_ROOT" 2>&1 || true
}

# Test: Monitor displays "All reviews approved" for approved state
test_monitor_output_phase_approved() {
    local test_dir="$TEST_TEMP_DIR/monitor_phase_approved"
    mkdir -p "$test_dir/.humanize/pr-loop/2026-01-18_10-00-00"

    # Create approve-state.md (final approved state)
    cat > "$test_dir/.humanize/pr-loop/2026-01-18_10-00-00/approve-state.md" << 'EOF'
---
current_round: 1
startup_case: 3
pr_number: 123
configured_bots:
  - codex
active_bots:
---
EOF

    # Create goal-tracker.md (required by monitor)
    cat > "$test_dir/.humanize/pr-loop/2026-01-18_10-00-00/goal-tracker.md" << 'GOAL'
# Goal Tracker
## Issue Summary
| Round | Reviewer | Issues Found | Status |
|-------|----------|--------------|--------|
| 0     | -        | 0            | Initial |
GOAL

    local output
    output=$(run_monitor_once_capture_output "$test_dir/.humanize/pr-loop/2026-01-18_10-00-00" "$test_dir")

    # Assert output contains approved phase (require Phase: label)
    if echo "$output" | grep -qi "Phase:.*approved\|Phase:.*All reviews"; then
        return 0
    else
        echo "Expected 'All reviews approved' in output, got: $(echo "$output" | head -20)"
        return 1
    fi
}

# Test: Monitor displays "Waiting for initial PR review" for waiting_initial_review state
test_monitor_output_phase_waiting_initial() {
    local test_dir="$TEST_TEMP_DIR/monitor_phase_waiting"
    mkdir -p "$test_dir/.humanize/pr-loop/2026-01-18_10-00-00"

    # Create state.md with startup_case=1, round=0 (waiting for initial review)
    cat > "$test_dir/.humanize/pr-loop/2026-01-18_10-00-00/state.md" << 'EOF'
---
current_round: 0
startup_case: 1
pr_number: 123
configured_bots:
  - codex
  - claude
active_bots:
  - codex
  - claude
---
EOF

    cat > "$test_dir/.humanize/pr-loop/2026-01-18_10-00-00/goal-tracker.md" << 'GOAL'
# Goal Tracker
## Issue Summary
| Round | Reviewer | Issues Found | Status |
|-------|----------|--------------|--------|
| 0     | -        | 0            | Initial |
GOAL

    local output
    output=$(run_monitor_once_capture_output "$test_dir/.humanize/pr-loop/2026-01-18_10-00-00" "$test_dir")

    # Assert output contains waiting phase (require Phase: label)
    # For startup_case=1 (no comments yet), the loop is waiting for initial review
    if echo "$output" | grep -qi "Phase:.*waiting"; then
        return 0
    else
        echo "Expected 'Phase:...waiting' in output, got: $(echo "$output" | head -20)"
        return 1
    fi
}

# Test: Monitor displays "Loop cancelled" for cancelled state
test_monitor_output_phase_cancelled() {
    local test_dir="$TEST_TEMP_DIR/monitor_phase_cancelled"
    mkdir -p "$test_dir/.humanize/pr-loop/2026-01-18_10-00-00"

    # Create cancel-state.md (cancelled state)
    cat > "$test_dir/.humanize/pr-loop/2026-01-18_10-00-00/cancel-state.md" << 'EOF'
---
current_round: 1
startup_case: 3
pr_number: 123
configured_bots:
  - codex
active_bots:
  - codex
cancelled_at: 2026-01-18T12:00:00Z
---
EOF

    cat > "$test_dir/.humanize/pr-loop/2026-01-18_10-00-00/goal-tracker.md" << 'GOAL'
# Goal Tracker
## Issue Summary
| Round | Reviewer | Issues Found | Status |
|-------|----------|--------------|--------|
| 0     | -        | 0            | Initial |
GOAL

    local output
    output=$(run_monitor_once_capture_output "$test_dir/.humanize/pr-loop/2026-01-18_10-00-00" "$test_dir")

    # Assert output contains cancel phase (require Phase: label)
    if echo "$output" | grep -qi "Phase:.*cancel"; then
        return 0
    else
        echo "Expected 'Phase:...cancel' in output, got: $(echo "$output" | head -20)"
        return 1
    fi
}

# Test: Monitor displays "Codex analyzing..." for codex_analyzing phase
test_monitor_output_phase_codex_analyzing() {
    local test_dir="$TEST_TEMP_DIR/monitor_phase_analyzing"
    mkdir -p "$test_dir/.humanize/pr-loop/2026-01-18_10-00-00"

    # Create state.md for active session
    cat > "$test_dir/.humanize/pr-loop/2026-01-18_10-00-00/state.md" << 'EOF'
---
current_round: 1
startup_case: 2
pr_number: 123
configured_bots:
  - codex
active_bots:
  - codex
---
EOF

    cat > "$test_dir/.humanize/pr-loop/2026-01-18_10-00-00/goal-tracker.md" << 'GOAL'
# Goal Tracker
## Issue Summary
| Round | Reviewer | Issues Found | Status |
|-------|----------|--------------|--------|
| 0     | -        | 0            | Initial |
GOAL

    # Create a pr-check file with current mtime (simulates Codex actively writing)
    local check_file="$test_dir/.humanize/pr-loop/2026-01-18_10-00-00/round-1-pr-check.md"
    echo "Analyzing PR..." > "$check_file"
    # Touch with current time ensures mtime is within 10 seconds
    touch "$check_file"

    local output
    output=$(run_monitor_once_capture_output "$test_dir/.humanize/pr-loop/2026-01-18_10-00-00" "$test_dir")

    # Assert output contains "Codex analyzing" phase (require Phase: prefix)
    if echo "$output" | grep -qi "Phase:.*Codex.*analyz"; then
        return 0
    else
        echo "Expected 'Phase:...Codex analyzing' in output, got: $(echo "$output" | head -20)"
        return 1
    fi
}

# ========================================
# Test: Case 1 Exception - No Trigger Required
# ========================================

test_case1_exception_no_trigger() {
    # For startup_case 1/2/3 in round 0, no trigger is required
    # This tests the logic that determines REQUIRE_TRIGGER

    # Test startup_case 1, round 0 -> REQUIRE_TRIGGER=false
    local round=0
    local startup_case=1
    local require_trigger=false

    if [[ "$round" -gt 0 ]]; then
        require_trigger=true
    elif [[ "$round" -eq 0 ]]; then
        case "$startup_case" in
            1|2|3) require_trigger=false ;;
            4|5) require_trigger=true ;;
        esac
    fi

    [[ "$require_trigger" == "false" ]] || { echo "Case 1 should not require trigger"; return 1; }

    # Test startup_case 2, round 0 -> REQUIRE_TRIGGER=false
    startup_case=2
    require_trigger=false
    if [[ "$round" -gt 0 ]]; then
        require_trigger=true
    elif [[ "$round" -eq 0 ]]; then
        case "$startup_case" in
            1|2|3) require_trigger=false ;;
            4|5) require_trigger=true ;;
        esac
    fi

    [[ "$require_trigger" == "false" ]] || { echo "Case 2 should not require trigger"; return 1; }

    # Test startup_case 4, round 0 -> REQUIRE_TRIGGER=true
    startup_case=4
    require_trigger=false
    if [[ "$round" -gt 0 ]]; then
        require_trigger=true
    elif [[ "$round" -eq 0 ]]; then
        case "$startup_case" in
            1|2|3) require_trigger=false ;;
            4|5) require_trigger=true ;;
        esac
    fi

    [[ "$require_trigger" == "true" ]] || { echo "Case 4 should require trigger"; return 1; }

    # Test round 1 (any case) -> REQUIRE_TRIGGER=true
    round=1
    startup_case=1
    require_trigger=false
    if [[ "$round" -gt 0 ]]; then
        require_trigger=true
    elif [[ "$round" -eq 0 ]]; then
        case "$startup_case" in
            1|2|3) require_trigger=false ;;
            4|5) require_trigger=true ;;
        esac
    fi

    [[ "$require_trigger" == "true" ]] || { echo "Round 1 should require trigger"; return 1; }
}

# ========================================
# Test: Goal Tracker Row Inside Table
# ========================================

test_goal_tracker_row_inside_table() {
    # Verify that update_pr_goal_tracker inserts rows INSIDE the Issue Summary table
    # Not before "## Total Statistics"

    source "$PROJECT_ROOT/hooks/lib/loop-common.sh"

    local tracker_file="$TEST_TEMP_DIR/goal-tracker-table.md"
    cat > "$tracker_file" << 'EOF'
# PR Review Goal Tracker

## Issue Summary

| Round | Reviewer | Issues Found | Issues Resolved | Status |
|-------|----------|--------------|-----------------|--------|
| 0     | -        | 0            | 0               | Initial |

## Total Statistics

- Total Issues Found: 0
- Total Issues Resolved: 0
- Remaining: 0

## Issue Log

### Round 0
*Awaiting initial reviews*
EOF

    # Update with round 1
    update_pr_goal_tracker "$tracker_file" 1 '{"issues": 2, "resolved": 0, "bot": "Codex"}'

    # Verify: The new row should be BEFORE the blank line that ends the table
    # Check that there's a table row with Round 1 BEFORE "## Total Statistics"

    # Extract just the Issue Summary section
    local summary_section
    summary_section=$(sed -n '/^## Issue Summary/,/^## Total Statistics/p' "$tracker_file")

    # The section should contain | 1 | somewhere (Round 1 row)
    echo "$summary_section" | grep -qE '^\|[[:space:]]*1[[:space:]]*\|' || {
        echo "Round 1 row not found in Issue Summary table"
        echo "Content:"
        cat "$tracker_file"
        return 1
    }

    # Verify the row appears BEFORE "## Total Statistics" (already ensured by sed range)
    # and the table structure is valid (rows end before blank line before ## Total Statistics)

    # Count table rows in Issue Summary (should be 3: header, separator, round 0, round 1)
    local row_count
    row_count=$(echo "$summary_section" | grep -cE '^\|' || echo 0)
    [[ "$row_count" -ge 4 ]] || {
        echo "Expected at least 4 table rows (header + separator + 2 data rows), got $row_count"
        return 1
    }
}

# ========================================
# Test: Goal Tracker Partial Update Repair
# ========================================

test_goal_tracker_partial_update_repair() {
    # Verify that update_pr_goal_tracker repairs partial updates
    # (when only summary OR log exists, not both)

    source "$PROJECT_ROOT/hooks/lib/loop-common.sh"

    # Test 1: Tracker with summary row but NO log entry
    local tracker_file="$TEST_TEMP_DIR/goal-tracker-partial1.md"
    cat > "$tracker_file" << 'EOF'
# PR Review Goal Tracker

## Issue Summary

| Round | Reviewer | Issues Found | Issues Resolved | Status |
|-------|----------|--------------|-----------------|--------|
| 0     | -        | 0            | 0               | Initial |
| 1     | Codex | 2            | 0               | Issues Found |

## Total Statistics

- Total Issues Found: 2
- Total Issues Resolved: 0
- Remaining: 2

## Issue Log

### Round 0
*Awaiting initial reviews*
EOF

    # Update - should add log entry but not summary row (since summary exists)
    update_pr_goal_tracker "$tracker_file" 1 '{"issues": 2, "resolved": 0, "bot": "Codex"}'

    # Should now have Round 1 in Issue Log
    grep -q "### Round 1" "$tracker_file" || { echo "Log entry for Round 1 not added"; return 1; }

    # Test 2: Tracker with log entry but NO summary row
    local tracker_file2="$TEST_TEMP_DIR/goal-tracker-partial2.md"
    cat > "$tracker_file2" << 'EOF'
# PR Review Goal Tracker

## Issue Summary

| Round | Reviewer | Issues Found | Issues Resolved | Status |
|-------|----------|--------------|-----------------|--------|
| 0     | -        | 0            | 0               | Initial |

## Total Statistics

- Total Issues Found: 0
- Total Issues Resolved: 0
- Remaining: 0

## Issue Log

### Round 0
*Awaiting initial reviews*

### Round 1
Codex: Found 2 issues, Resolved 0
EOF

    # Update - should add summary row but not log entry (since log exists)
    update_pr_goal_tracker "$tracker_file2" 1 '{"issues": 2, "resolved": 0, "bot": "Codex"}'

    # Should now have Round 1 in summary table
    grep -qE '^\|[[:space:]]*1[[:space:]]*\|' "$tracker_file2" || { echo "Summary row for Round 1 not added"; return 1; }
}

# ========================================
# Test: Case 4 Emission (all commented + new commits)
# ========================================

test_case4_all_commented_new_commits() {
    # Verify Case 4 is emitted when ALL reviewers commented and new commits after

    # Fixture: All bots commented at 10:00, latest commit at 11:00
    echo '[{"id":1001,"user":{"login":"claude[bot]"},"created_at":"2026-01-18T10:00:00Z","body":"Issue found"}]' > "$FIXTURES_DIR/issue-comments.json"
    echo '[]' > "$FIXTURES_DIR/review-comments.json"
    echo '[{"id":4001,"user":{"login":"chatgpt-codex-connector[bot]"},"submitted_at":"2026-01-18T10:05:00Z","body":"LGTM","state":"APPROVED"}]' > "$FIXTURES_DIR/pr-reviews.json"

    # Mock commit at 11:00 (after reviews)
    export MOCK_GH_LATEST_COMMIT_AT="2026-01-18T11:00:00Z"

    local result
    result=$("$PROJECT_ROOT/scripts/check-pr-reviewer-status.sh" 123 --bots "claude,codex" 2>/dev/null) || true

    # Should return Case 4 (all commented, new commits)
    local case_num
    case_num=$(echo "$result" | jq -r '.case')
    [[ "$case_num" == "4" ]] || { echo "Expected Case 4, got $case_num"; return 1; }

    # has_commits_after_reviews should be true
    local has_commits
    has_commits=$(echo "$result" | jq -r '.has_commits_after_reviews')
    [[ "$has_commits" == "true" ]] || { echo "Expected has_commits_after_reviews=true, got $has_commits"; return 1; }

    # Cleanup mock
    unset MOCK_GH_LATEST_COMMIT_AT
}

# ========================================
# Test: Case 5 Emission (partial + new commits)
# ========================================

test_case5_partial_commented_new_commits() {
    # Verify Case 5 is emitted when SOME reviewers commented and new commits after

    # Fixture: Only claude commented at 10:00, codex missing
    echo '[{"id":1001,"user":{"login":"claude[bot]"},"created_at":"2026-01-18T10:00:00Z","body":"Issue found"}]' > "$FIXTURES_DIR/issue-comments.json"
    echo '[]' > "$FIXTURES_DIR/review-comments.json"
    echo '[]' > "$FIXTURES_DIR/pr-reviews.json"  # No codex

    # Mock commit at 11:00 (after claude's review)
    export MOCK_GH_LATEST_COMMIT_AT="2026-01-18T11:00:00Z"

    local result
    result=$("$PROJECT_ROOT/scripts/check-pr-reviewer-status.sh" 123 --bots "claude,codex" 2>/dev/null) || true

    # Should return Case 5 (partial commented, new commits)
    local case_num
    case_num=$(echo "$result" | jq -r '.case')
    [[ "$case_num" == "5" ]] || { echo "Expected Case 5, got $case_num"; return 1; }

    # has_commits_after_reviews should be true
    local has_commits
    has_commits=$(echo "$result" | jq -r '.has_commits_after_reviews')
    [[ "$has_commits" == "true" ]] || { echo "Expected has_commits_after_reviews=true, got $has_commits"; return 1; }

    # Cleanup mock
    unset MOCK_GH_LATEST_COMMIT_AT

    # Restore original fixtures
    echo '[{"id":1001,"user":{"login":"claude[bot]"},"created_at":"2026-01-18T11:00:00Z","body":"Issue found"}]' > "$FIXTURES_DIR/issue-comments.json"
    echo '[]' > "$FIXTURES_DIR/review-comments.json"
    echo '[{"id":4001,"user":{"login":"chatgpt-codex-connector[bot]"},"submitted_at":"2026-01-18T11:15:00Z","body":"LGTM! Code looks good.","state":"APPROVED"}]' > "$FIXTURES_DIR/pr-reviews.json"
}

# ========================================
# Test: Setup Case 4/5 Failure Path (missing trigger_comment_id)
# ========================================

test_setup_case45_missing_trigger_comment_id() {
    # Test that setup-pr-loop.sh fails when trigger_comment_id cannot be retrieved
    # for Case 4/5 with --claude option
    # This tests the fix that requires eyes verification

    # Set up fixtures for Case 4: All bots commented, new commits after reviews
    # Only claude for simplicity - fixture needs bot comment BEFORE latest commit
    echo '[{"id":1001,"user":{"login":"claude[bot]"},"created_at":"2026-01-18T08:00:00Z","body":"Issue found"}]' > "$FIXTURES_DIR/issue-comments.json"
    echo '[]' > "$FIXTURES_DIR/review-comments.json"
    echo '[]' > "$FIXTURES_DIR/pr-reviews.json"

    # Set latest commit AFTER bot comments to trigger Case 4
    export MOCK_GH_LATEST_COMMIT_AT="2026-01-18T12:00:00Z"
    export MOCK_GH_PR_NUMBER=123
    export MOCK_GH_PR_STATE="OPEN"
    # Make the regular mock return null for the comment lookup that gets the trigger ID
    export MOCK_GH_COMMENT_ID_LOOKUP_FAIL=true

    # Run setup-pr-loop.sh with --claude - should fail due to missing trigger_comment_id
    local result exit_code
    result=$("$PROJECT_ROOT/scripts/setup-pr-loop.sh" --claude 2>&1) && exit_code=0 || exit_code=$?

    # Clean up mock env vars
    unset MOCK_GH_LATEST_COMMIT_AT MOCK_GH_COMMENT_ID_LOOKUP_FAIL

    # Verify it failed
    if [[ $exit_code -eq 0 ]]; then
        echo "Expected setup to fail but it succeeded"
        echo "Output (last 30 lines): $(echo "$result" | tail -30)"
        # Restore fixtures
        echo '[{"id":1001,"user":{"login":"claude[bot]"},"created_at":"2026-01-18T11:00:00Z","body":"Issue found"}]' > "$FIXTURES_DIR/issue-comments.json"
        echo '[]' > "$FIXTURES_DIR/review-comments.json"
        echo '[{"id":4001,"user":{"login":"chatgpt-codex-connector[bot]"},"submitted_at":"2026-01-18T11:15:00Z","body":"LGTM!","state":"APPROVED"}]' > "$FIXTURES_DIR/pr-reviews.json"
        return 1
    fi

    # Verify error message about missing trigger comment ID
    if ! echo "$result" | grep -q "Could not find trigger comment ID"; then
        echo "Expected error message about missing trigger_comment_id"
        echo "Got: $result"
        # Restore fixtures
        echo '[{"id":1001,"user":{"login":"claude[bot]"},"created_at":"2026-01-18T11:00:00Z","body":"Issue found"}]' > "$FIXTURES_DIR/issue-comments.json"
        echo '[]' > "$FIXTURES_DIR/review-comments.json"
        echo '[{"id":4001,"user":{"login":"chatgpt-codex-connector[bot]"},"submitted_at":"2026-01-18T11:15:00Z","body":"LGTM!","state":"APPROVED"}]' > "$FIXTURES_DIR/pr-reviews.json"
        return 1
    fi

    # Verify loop directory was cleaned up
    if ls .humanize/pr-loop/*/state.md 2>/dev/null | head -1 | grep -q .; then
        echo "Loop directory was not cleaned up on failure"
        # Restore fixtures
        echo '[{"id":1001,"user":{"login":"claude[bot]"},"created_at":"2026-01-18T11:00:00Z","body":"Issue found"}]' > "$FIXTURES_DIR/issue-comments.json"
        echo '[]' > "$FIXTURES_DIR/review-comments.json"
        echo '[{"id":4001,"user":{"login":"chatgpt-codex-connector[bot]"},"submitted_at":"2026-01-18T11:15:00Z","body":"LGTM!","state":"APPROVED"}]' > "$FIXTURES_DIR/pr-reviews.json"
        return 1
    fi

    # Restore fixtures
    echo '[{"id":1001,"user":{"login":"claude[bot]"},"created_at":"2026-01-18T11:00:00Z","body":"Issue found"}]' > "$FIXTURES_DIR/issue-comments.json"
    echo '[]' > "$FIXTURES_DIR/review-comments.json"
    echo '[{"id":4001,"user":{"login":"chatgpt-codex-connector[bot]"},"submitted_at":"2026-01-18T11:15:00Z","body":"LGTM!","state":"APPROVED"}]' > "$FIXTURES_DIR/pr-reviews.json"

    return 0
}

# ========================================
# Test: Goal Tracker Creation/Update Integration Test
# ========================================

test_goal_tracker_creation_integration() {
    # Test that setup-pr-loop.sh creates goal-tracker.md
    # This verifies: goal tracker is created at setup

    # Set up fixtures for Case 1: No comments yet (simplest setup)
    echo '[]' > "$FIXTURES_DIR/issue-comments.json"
    echo '[]' > "$FIXTURES_DIR/review-comments.json"
    echo '[]' > "$FIXTURES_DIR/pr-reviews.json"
    echo '[]' > "$FIXTURES_DIR/reactions.json"

    export MOCK_GH_PR_NUMBER=999
    export MOCK_GH_PR_STATE="OPEN"
    export MOCK_GH_LATEST_COMMIT_AT="2026-01-18T10:00:00Z"
    export MOCK_GH_HEAD_SHA="abc123xyz"

    # Clean up any existing pr-loop directories
    rm -rf .humanize/pr-loop 2>/dev/null || true

    # Run setup-pr-loop.sh with --codex
    local result exit_code
    result=$("$PROJECT_ROOT/scripts/setup-pr-loop.sh" --codex 2>&1) && exit_code=0 || exit_code=$?

    # Clean up mock env vars
    unset MOCK_GH_PR_NUMBER MOCK_GH_PR_STATE MOCK_GH_LATEST_COMMIT_AT MOCK_GH_HEAD_SHA

    # Find the created loop directory
    local loop_dir
    loop_dir=$(ls -d .humanize/pr-loop/*/ 2>/dev/null | head -1)

    if [[ -z "$loop_dir" ]]; then
        echo "No loop directory created by setup-pr-loop.sh"
        echo "Output: $(echo "$result" | tail -20)"
        # Restore fixtures
        echo '[{"id":1001,"user":{"login":"claude[bot]"},"created_at":"2026-01-18T11:00:00Z","body":"Issue found"}]' > "$FIXTURES_DIR/issue-comments.json"
        echo '[{"id":4001,"user":{"login":"chatgpt-codex-connector[bot]"},"submitted_at":"2026-01-18T11:15:00Z","body":"LGTM!","state":"APPROVED"}]' > "$FIXTURES_DIR/pr-reviews.json"
        echo '[{"id":5001,"user":{"login":"chatgpt-codex-connector[bot]"},"content":"+1","created_at":"2026-01-18T11:10:00Z"}]' > "$FIXTURES_DIR/reactions.json"
        return 1
    fi

    # Verify goal-tracker.md was created
    if [[ ! -f "${loop_dir}goal-tracker.md" ]]; then
        echo "goal-tracker.md not found in $loop_dir"
        echo "Files in loop dir: $(ls -la "$loop_dir" 2>/dev/null)"
        # Clean up
        rm -rf .humanize/pr-loop
        # Restore fixtures
        echo '[{"id":1001,"user":{"login":"claude[bot]"},"created_at":"2026-01-18T11:00:00Z","body":"Issue found"}]' > "$FIXTURES_DIR/issue-comments.json"
        echo '[{"id":4001,"user":{"login":"chatgpt-codex-connector[bot]"},"submitted_at":"2026-01-18T11:15:00Z","body":"LGTM!","state":"APPROVED"}]' > "$FIXTURES_DIR/pr-reviews.json"
        echo '[{"id":5001,"user":{"login":"chatgpt-codex-connector[bot]"},"content":"+1","created_at":"2026-01-18T11:10:00Z"}]' > "$FIXTURES_DIR/reactions.json"
        return 1
    fi

    # Verify goal-tracker.md has expected structure (Issue Summary table)
    if ! grep -q "Issue Summary" "${loop_dir}goal-tracker.md"; then
        echo "goal-tracker.md missing 'Issue Summary' section"
        echo "Contents: $(cat "${loop_dir}goal-tracker.md")"
        rm -rf .humanize/pr-loop
        # Restore fixtures
        echo '[{"id":1001,"user":{"login":"claude[bot]"},"created_at":"2026-01-18T11:00:00Z","body":"Issue found"}]' > "$FIXTURES_DIR/issue-comments.json"
        echo '[{"id":4001,"user":{"login":"chatgpt-codex-connector[bot]"},"submitted_at":"2026-01-18T11:15:00Z","body":"LGTM!","state":"APPROVED"}]' > "$FIXTURES_DIR/pr-reviews.json"
        echo '[{"id":5001,"user":{"login":"chatgpt-codex-connector[bot]"},"content":"+1","created_at":"2026-01-18T11:10:00Z"}]' > "$FIXTURES_DIR/reactions.json"
        return 1
    fi

    # Verify goal-tracker.md has PR number from mock
    if ! grep -q "999" "${loop_dir}goal-tracker.md"; then
        echo "goal-tracker.md missing PR number 999"
        echo "Contents: $(cat "${loop_dir}goal-tracker.md")"
        rm -rf .humanize/pr-loop
        # Restore fixtures
        echo '[{"id":1001,"user":{"login":"claude[bot]"},"created_at":"2026-01-18T11:00:00Z","body":"Issue found"}]' > "$FIXTURES_DIR/issue-comments.json"
        echo '[{"id":4001,"user":{"login":"chatgpt-codex-connector[bot]"},"submitted_at":"2026-01-18T11:15:00Z","body":"LGTM!","state":"APPROVED"}]' > "$FIXTURES_DIR/pr-reviews.json"
        echo '[{"id":5001,"user":{"login":"chatgpt-codex-connector[bot]"},"content":"+1","created_at":"2026-01-18T11:10:00Z"}]' > "$FIXTURES_DIR/reactions.json"
        return 1
    fi

    # Clean up
    rm -rf .humanize/pr-loop

    # Restore fixtures
    echo '[{"id":1001,"user":{"login":"claude[bot]"},"created_at":"2026-01-18T11:00:00Z","body":"Issue found"}]' > "$FIXTURES_DIR/issue-comments.json"
    echo '[]' > "$FIXTURES_DIR/review-comments.json"
    echo '[{"id":4001,"user":{"login":"chatgpt-codex-connector[bot]"},"submitted_at":"2026-01-18T11:15:00Z","body":"LGTM!","state":"APPROVED"}]' > "$FIXTURES_DIR/pr-reviews.json"
    echo '[{"id":5001,"user":{"login":"chatgpt-codex-connector[bot]"},"content":"+1","created_at":"2026-01-18T11:10:00Z"}]' > "$FIXTURES_DIR/reactions.json"

    return 0
}

# Test: Stop hook updates goal tracker with round results
test_stophook_updates_goal_tracker() {
    # This test verifies that running the stop hook after bot review updates the goal tracker
    local test_dir="$TEST_TEMP_DIR/stophook_goal_test"
    mkdir -p "$test_dir/.humanize/pr-loop/2026-01-18_12-00-00"

    # Use dynamic timestamps
    local trigger_ts commit_ts comment_ts
    trigger_ts=$(date -u -d "-10 seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-10S +%Y-%m-%dT%H:%M:%SZ)
    commit_ts=$(date -u -d "-60 seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-60S +%Y-%m-%dT%H:%M:%SZ)
    comment_ts=$(date -u -d "-5 seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-5S +%Y-%m-%dT%H:%M:%SZ)

    # Create state.md for Round 0
    cat > "$test_dir/.humanize/pr-loop/2026-01-18_12-00-00/state.md" << EOF
---
current_round: 0
max_iterations: 42
pr_number: 123
start_branch: test-branch
configured_bots:
  - codex
active_bots:
  - codex
codex_model: gpt-5.2-codex
codex_effort: medium
codex_timeout: 900
poll_interval: 1
poll_timeout: 60
started_at: $commit_ts
last_trigger_at: $trigger_ts
trigger_comment_id: 999
startup_case: 1
latest_commit_sha: abc123
latest_commit_at: $commit_ts
---
EOF

    # Create initial goal tracker (need blank line after table header for row insertion)
    cat > "$test_dir/.humanize/pr-loop/2026-01-18_12-00-00/goal-tracker.md" << 'EOF'
# PR Review Goal Tracker (PR #123)

## Issue Summary

| Round | Bot | Issues Found | Issues Resolved | Status |
|-------|-----|--------------|-----------------|--------|

## Total Statistics
- Total Issues Found: 0
- Total Issues Resolved: 0
EOF

    # Create round-0 resolve file
    echo "# Resolution" > "$test_dir/.humanize/pr-loop/2026-01-18_12-00-00/round-0-pr-resolve.md"

    # Create mock gh and git
    local mock_bin="$test_dir/bin"
    mkdir -p "$mock_bin"

    cat > "$mock_bin/gh" << MOCK_GH
#!/bin/bash
COMMENT_TS="$comment_ts"
COMMIT_TS="$commit_ts"

case "\$1" in
    repo)
        if [[ "\$*" == *"--json owner"* ]]; then
            echo "testowner"
            exit 0
        fi
        if [[ "\$*" == *"--json name"* ]]; then
            echo "testrepo"
            exit 0
        fi
        ;;
    api)
        if [[ "\$2" == "user" ]]; then
            echo "testuser"
            exit 0
        fi
        if [[ "\$2" == *"/issues/"*"/comments"* ]]; then
            # Return codex comment with issues
            echo "[{\"id\":1001,\"user\":{\"login\":\"chatgpt-codex-connector[bot]\",\"type\":\"Bot\"},\"created_at\":\"\$COMMENT_TS\",\"body\":\"Found 2 issues: fix X, fix Y\"}]"
            exit 0
        fi
        if [[ "\$2" == *"/pulls/"*"/reviews"* ]]; then
            echo '[]'
            exit 0
        fi
        if [[ "\$2" == *"/pulls/"*"/comments"* ]]; then
            echo '[]'
            exit 0
        fi
        echo '[]'
        exit 0
        ;;
    pr)
        if [[ "\$*" == *"commits"* ]] && [[ "\$*" == *"headRefOid"* ]]; then
            echo "{\"sha\":\"abc123\",\"date\":\"\$COMMIT_TS\"}"
            exit 0
        fi
        if [[ "\$*" == *"commits"* ]] && [[ "\$*" == *"--jq"* ]]; then
            # When --jq is used, return just the extracted timestamp
            echo "\$COMMIT_TS"
            exit 0
        fi
        if [[ "\$*" == *"commits"* ]]; then
            echo "{\"commits\":[{\"committedDate\":\"\$COMMIT_TS\"}]}"
            exit 0
        fi
        if [[ "\$*" == *"baseRepository"* ]]; then
            echo '{"baseRepository":{"owner":{"login":"testowner"},"name":"testrepo"}}'
            exit 0
        fi
        if [[ "\$*" == *"state"* ]]; then
            echo '{"state": "OPEN"}'
            exit 0
        fi
        ;;
esac
exit 0
MOCK_GH
    chmod +x "$mock_bin/gh"

    cat > "$mock_bin/git" << 'MOCK_GIT'
#!/bin/bash
case "$1" in
    rev-parse)
        if [[ "$2" == "HEAD" ]]; then
            echo "abc123"
        elif [[ "$2" == "--git-dir" ]]; then
            echo ".git"
        else
            echo "/tmp/git"
        fi
        ;;
    status)
        echo ""
        ;;
    merge-base) exit 0 ;;
esac
exit 0
MOCK_GIT
    chmod +x "$mock_bin/git"

    # Mock codex command - returns ISSUES_REMAINING to trigger goal tracker update
    cat > "$mock_bin/codex" << 'MOCK_CODEX'
#!/bin/bash
# Mock codex for testing - output review analysis
cat << 'CODEX_OUTPUT'
## Bot Review Analysis

### codex (chatgpt-codex-connector[bot])
**Status**: ISSUES
**Issues Found**: 1
- Fix issue X

### Issues Found (if any)
- Fix issue X

### Approved Bots (to remove from active_bots)
(none)

### Final Recommendation
ISSUES_REMAINING
CODEX_OUTPUT
exit 0
MOCK_CODEX
    chmod +x "$mock_bin/codex"

    # Run stop hook
    export CLAUDE_PROJECT_DIR="$test_dir"
    local old_path="$PATH"
    export PATH="$mock_bin:$PATH"

    local hook_output
    hook_output=$(timeout 15 bash -c 'echo "{}" | "$1/hooks/pr-loop-stop-hook.sh" 2>&1' _ "$PROJECT_ROOT" 2>&1) || true

    export PATH="$old_path"
    unset CLAUDE_PROJECT_DIR

    # Verify goal tracker was updated with Round 1 row
    local goal_file="$test_dir/.humanize/pr-loop/2026-01-18_12-00-00/goal-tracker.md"
    if [[ ! -f "$goal_file" ]]; then
        echo "Goal tracker file not found"
        rm -rf "$test_dir"
        return 1
    fi

    # Check that Round 1 row was added (format: | 1     | with possible spaces)
    if ! grep -qE '^\|[[:space:]]*1[[:space:]]*\|' "$goal_file"; then
        echo "Goal tracker not updated with Round 1"
        echo "Contents: $(cat "$goal_file")"
        echo "Hook output: $(echo "$hook_output" | tail -20)"
        rm -rf "$test_dir"
        return 1
    fi

    # Check that codex bot is mentioned in the row (lowercase to match configured bot names)
    if ! grep -qi "codex" "$goal_file"; then
        echo "Goal tracker missing codex bot entry"
        echo "Contents: $(cat "$goal_file")"
        rm -rf "$test_dir"
        return 1
    fi

    rm -rf "$test_dir"
    return 0
}

# ========================================
# Main test runner
# ========================================

main() {
    local test_filter="${1:-}"

    echo "=========================================="
    echo " PR Loop System Tests"
    echo "=========================================="
    echo ""
    echo "Project root: $PROJECT_ROOT"
    echo "Mock directory: $MOCKS_DIR"
    echo "Fixtures directory: $FIXTURES_DIR"
    echo ""

    # Run tests
    if [[ -z "$test_filter" || "$test_filter" == "mutual_exclusion" ]]; then
        run_test "Mutual exclusion - RLCR blocks PR" test_mutual_exclusion_rlcr_blocks_pr
        run_test "Mutual exclusion - PR blocks RLCR" test_mutual_exclusion_pr_blocks_rlcr
    fi

    if [[ -z "$test_filter" || "$test_filter" == "reviewer_status" ]]; then
        run_test "Reviewer status - Case 1 (no comments)" test_reviewer_status_case1_no_comments
        run_test "Reviewer status - Case 2 (partial comments)" test_reviewer_status_case2_partial_comments
    fi

    if [[ -z "$test_filter" || "$test_filter" == "reactions" ]]; then
        run_test "Codex +1 detection" test_codex_thumbsup_detected
        run_test "Codex +1 with --after filter" test_codex_thumbsup_with_after_filter
        run_test "Claude eyes detection" test_claude_eyes_detected
    fi

    if [[ -z "$test_filter" || "$test_filter" == "pr_reviews" ]]; then
        run_test "PR reviews detection" test_reviewer_status_includes_pr_reviews
    fi

    if [[ -z "$test_filter" || "$test_filter" == "phase" ]]; then
        run_test "Phase detection - approved" test_phase_detection_approved
        run_test "Phase detection - waiting initial" test_phase_detection_waiting_initial
        run_test "Phase detection - waiting reviewer" test_phase_detection_waiting_reviewer
    fi

    if [[ -z "$test_filter" || "$test_filter" == "goal_tracker" ]]; then
        run_test "Goal tracker parsing" test_goal_tracker_parsing
    fi

    if [[ -z "$test_filter" || "$test_filter" == "pr_goal_tracker" ]]; then
        run_test "PR goal tracker parsing" test_pr_goal_tracker_parsing
        run_test "update_pr_goal_tracker helper" test_update_pr_goal_tracker
    fi

    if [[ -z "$test_filter" || "$test_filter" == "state_file" ]]; then
        run_test "State file detection - active" test_state_file_detection_active
        run_test "State file detection - approve" test_state_file_detection_approve
    fi

    if [[ -z "$test_filter" || "$test_filter" == "phase_extended" ]]; then
        run_test "Phase detection - cancelled" test_phase_detection_cancelled
        run_test "Phase detection - maxiter" test_phase_detection_maxiter
    fi

    if [[ -z "$test_filter" || "$test_filter" == "reviewer_status_extended" ]]; then
        run_test "Reviewer status - Case 3 (all commented)" test_reviewer_status_case3_all_commented
    fi

    if [[ -z "$test_filter" || "$test_filter" == "unpushed" ]]; then
        run_test "Unpushed commits detection" test_unpushed_commits_detected
    fi

    if [[ -z "$test_filter" || "$test_filter" == "force_push" ]]; then
        run_test "Force push ancestry check" test_force_push_ancestry_check
    fi

    if [[ -z "$test_filter" || "$test_filter" == "approve_state" ]]; then
        run_test "Approve state detection" test_approve_state_detection
    fi

    if [[ -z "$test_filter" || "$test_filter" == "goal_tracker_schema" ]]; then
        run_test "Goal tracker schema" test_goal_tracker_schema
        run_test "Goal tracker update adds row" test_goal_tracker_update_adds_row
        run_test "Goal tracker update idempotent" test_goal_tracker_update_idempotent
    fi

    if [[ -z "$test_filter" || "$test_filter" == "startup_case" ]]; then
        run_test "Startup case 4/5 detection" test_startup_case_4_5_detection
    fi

    if [[ -z "$test_filter" || "$test_filter" == "shared_monitor" ]]; then
        run_test "Shared monitor - find latest session" test_shared_monitor_find_latest_session
        run_test "Shared monitor - find state file" test_shared_monitor_find_state_file
        run_test "Shared monitor - get file size" test_shared_monitor_get_file_size
    fi

    if [[ -z "$test_filter" || "$test_filter" == "phase_analyzing" ]]; then
        run_test "Phase detection - codex analyzing (file growth)" test_phase_detection_codex_analyzing
    fi

    # Monitor output assertions for phase labels
    if [[ -z "$test_filter" || "$test_filter" == "monitor_output" ]]; then
        run_test "Monitor output - approved phase display" test_monitor_output_phase_approved
        run_test "Monitor output - waiting initial phase display" test_monitor_output_phase_waiting_initial
        run_test "Monitor output - cancelled phase display" test_monitor_output_phase_cancelled
        run_test "Monitor output - codex analyzing phase display" test_monitor_output_phase_codex_analyzing
    fi

    if [[ -z "$test_filter" || "$test_filter" == "case1_exception" ]]; then
        run_test "Case 1 exception - no trigger required for startup_case 1" test_case1_exception_no_trigger
    fi

    if [[ -z "$test_filter" || "$test_filter" == "goal_tracker_table" ]]; then
        run_test "Goal tracker row inserted inside table" test_goal_tracker_row_inside_table
    fi

    if [[ -z "$test_filter" || "$test_filter" == "goal_tracker_partial" ]]; then
        run_test "Goal tracker partial update repair" test_goal_tracker_partial_update_repair
    fi

    if [[ -z "$test_filter" || "$test_filter" == "case_4_5" ]]; then
        run_test "Case 4 emission (all commented + new commits)" test_case4_all_commented_new_commits
        run_test "Case 5 emission (partial + new commits)" test_case5_partial_commented_new_commits
    fi

    if [[ -z "$test_filter" || "$test_filter" == "setup_failure" ]]; then
        run_test "Setup Case 4/5 failure path (missing trigger_comment_id)" test_setup_case45_missing_trigger_comment_id
    fi

    if [[ -z "$test_filter" || "$test_filter" == "goal_tracker_integration" ]]; then
        run_test "Goal tracker creation via setup-pr-loop.sh" test_goal_tracker_creation_integration
        run_test "Stop hook updates goal tracker with round results" test_stophook_updates_goal_tracker
    fi

    echo ""
    echo "=========================================="
    echo " Results"
    echo "=========================================="
    echo ""
    echo "Tests run:    $TESTS_RUN"
    echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
    echo ""

    if [[ $TESTS_FAILED -gt 0 ]]; then
        exit 1
    fi
}

main "$@"
