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
# Test: Mutual Exclusion - AC-1
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
# Test: Check PR Reviewer Status - AC-2
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
# Test: Codex +1 Detection - AC-8
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
# Test: Claude Eyes Detection - AC-9
# ========================================

test_claude_eyes_detected() {
    # Use delay 0 and retry 1 for fast test
    local result
    result=$("$PROJECT_ROOT/scripts/check-bot-reactions.sh" claude-eyes 12345 --retry 1 --delay 0)

    # Should find the eyes reaction
    echo "$result" | jq -e '.content == "eyes"' || return 1
}

# ========================================
# Test: PR Reviews Detection - AC-2 (PR submissions)
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
# Test: Phase Detection - AC-11
# ========================================

test_phase_detection_approved() {
    # Source monitor-common.sh
    source "$PROJECT_ROOT/scripts/monitor-common.sh"

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
    source "$PROJECT_ROOT/scripts/monitor-common.sh"

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
    source "$PROJECT_ROOT/scripts/monitor-common.sh"

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
    source "$PROJECT_ROOT/scripts/monitor-common.sh"

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
        run_test "AC-1: Mutual exclusion - RLCR blocks PR" test_mutual_exclusion_rlcr_blocks_pr
        run_test "AC-1: Mutual exclusion - PR blocks RLCR" test_mutual_exclusion_pr_blocks_rlcr
    fi

    if [[ -z "$test_filter" || "$test_filter" == "reviewer_status" ]]; then
        run_test "AC-2: Reviewer status - Case 1 (no comments)" test_reviewer_status_case1_no_comments
        run_test "AC-2: Reviewer status - Case 2 (partial comments)" test_reviewer_status_case2_partial_comments
    fi

    if [[ -z "$test_filter" || "$test_filter" == "reactions" ]]; then
        run_test "AC-8: Codex +1 detection" test_codex_thumbsup_detected
        run_test "AC-8: Codex +1 with --after filter" test_codex_thumbsup_with_after_filter
        run_test "AC-9: Claude eyes detection" test_claude_eyes_detected
    fi

    if [[ -z "$test_filter" || "$test_filter" == "pr_reviews" ]]; then
        run_test "AC-2: PR reviews detection" test_reviewer_status_includes_pr_reviews
    fi

    if [[ -z "$test_filter" || "$test_filter" == "phase" ]]; then
        run_test "AC-11: Phase detection - approved" test_phase_detection_approved
        run_test "AC-11: Phase detection - waiting initial" test_phase_detection_waiting_initial
        run_test "AC-11: Phase detection - waiting reviewer" test_phase_detection_waiting_reviewer
    fi

    if [[ -z "$test_filter" || "$test_filter" == "goal_tracker" ]]; then
        run_test "AC-12: Goal tracker parsing" test_goal_tracker_parsing
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
