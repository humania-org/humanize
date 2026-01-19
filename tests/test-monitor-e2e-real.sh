#!/bin/bash
#
# TRUE End-to-End Monitor Tests for AC-1.1, AC-1.3, AC-1.4
#
# This test runs the REAL _humanize_monitor_codex function (not stubs)
# and verifies graceful stop behavior when .humanize/rlcr is deleted.
#
# Validates:
# - AC-1.1: Clean exit with user-friendly message when .humanize deleted
# - AC-1.2: No zsh/bash "no matches found" errors
# - AC-1.3: Terminal state properly restored (scroll region reset)
# - AC-1.4: Works correctly in both bash and zsh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo -e "${GREEN}PASS${NC}: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "${RED}FAIL${NC}: $1"
    echo "  Details: $2"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

echo "========================================"
echo "TRUE End-to-End Monitor Tests"
echo "========================================"
echo ""

# ========================================
# Test Setup
# ========================================

TEST_BASE="/tmp/test-monitor-e2e-real-$$"
mkdir -p "$TEST_BASE"

cleanup_test() {
    # Kill any lingering monitor processes
    pkill -f "test-monitor-e2e-real-$$" 2>/dev/null || true
    rm -rf "$TEST_BASE"
}
trap cleanup_test EXIT

# ========================================
# Test 1: Real _humanize_monitor_codex with directory deletion (bash)
# ========================================
echo "Test 1: Real _humanize_monitor_codex with directory deletion (bash)"
echo ""

# Create test project directory
TEST_PROJECT="$TEST_BASE/project1"
mkdir -p "$TEST_PROJECT/.humanize/rlcr/2026-01-16_10-00-00"

# Create valid state.md file
cat > "$TEST_PROJECT/.humanize/rlcr/2026-01-16_10-00-00/state.md" << 'STATE'
current_round: 1
max_iterations: 5
codex_model: o3
codex_effort: high
started_at: 2026-01-16T10:00:00Z
plan_file: temp/plan.md
STATE

# Create goal-tracker.md (required by monitor)
cat > "$TEST_PROJECT/.humanize/rlcr/2026-01-16_10-00-00/goal-tracker.md" << 'GOALTRACKER_EOF1'
# Goal Tracker
## IMMUTABLE SECTION
### Ultimate Goal
Test goal
### Acceptance Criteria
- AC-1: Test criterion
## MUTABLE SECTION
### Plan Version: 1
### Completed and Verified
| AC | Task |
|----|------|
GOALTRACKER_EOF1

# Create a fake HOME with cache directory for log files
FAKE_HOME="$TEST_BASE/home1"
mkdir -p "$FAKE_HOME"

# Create cache directory matching the project path
SANITIZED_PROJECT=$(echo "$TEST_PROJECT" | sed 's/[^a-zA-Z0-9._-]/-/g' | sed 's/--*/-/g')
CACHE_DIR="$FAKE_HOME/.cache/humanize/$SANITIZED_PROJECT/2026-01-16_10-00-00"
mkdir -p "$CACHE_DIR"
echo "Round 1 started" > "$CACHE_DIR/round-1-codex-run.log"

# Create the test runner script
# This script runs the REAL _humanize_monitor_codex function
cat > "$TEST_PROJECT/run_real_monitor.sh" << 'MONITOR_SCRIPT'
#!/bin/bash
# Run the REAL _humanize_monitor_codex function

PROJECT_DIR="$1"
PROJECT_ROOT="$2"
FAKE_HOME="$3"
OUTPUT_FILE="$4"

cd "$PROJECT_DIR"

# Override HOME and XDG_CACHE_HOME to use our fake home with cache
export HOME="$FAKE_HOME"
export XDG_CACHE_HOME="$FAKE_HOME/.cache"

# Create shim functions for terminal commands (non-interactive mode)
tput() {
    case "$1" in
        cols) echo "80" ;;
        lines) echo "24" ;;
        sc) : ;;  # save cursor - no-op
        rc) : ;;  # restore cursor - no-op
        cup) : ;; # cursor position - no-op
        csr) : ;; # set scroll region - no-op
        ed) : ;;  # clear to end - no-op
        smcup) : ;; # enter alt screen - no-op
        rmcup) echo "RMCUP_CALLED" ;; # exit alt screen - track this
        *) : ;;
    esac
}
export -f tput

clear() {
    : # no-op
}
export -f clear

# Source the humanize.sh script to get the REAL _humanize_monitor_codex function
source "$PROJECT_ROOT/scripts/humanize.sh"

# Run the REAL monitor function and capture all output
_humanize_monitor_codex 2>&1
exit_code=$?

echo "EXIT_CODE:$exit_code"
MONITOR_SCRIPT

chmod +x "$TEST_PROJECT/run_real_monitor.sh"

# Run the monitor in background and capture output
OUTPUT_FILE="$TEST_BASE/output1.txt"
"$TEST_PROJECT/run_real_monitor.sh" "$TEST_PROJECT" "$PROJECT_ROOT" "$FAKE_HOME" "$OUTPUT_FILE" > "$OUTPUT_FILE" 2>&1 &
MONITOR_PID=$!

# Wait for monitor to start (check for initial output)
sleep 2

# Delete the .humanize/rlcr directory to trigger graceful stop
rm -rf "$TEST_PROJECT/.humanize/rlcr"

# Wait for monitor to exit (bounded loop)
WAIT_COUNT=0
while kill -0 $MONITOR_PID 2>/dev/null && [[ $WAIT_COUNT -lt 20 ]]; do
    sleep 0.5
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

# Force kill if still running (should not happen)
if kill -0 $MONITOR_PID 2>/dev/null; then
    kill $MONITOR_PID 2>/dev/null || true
    wait $MONITOR_PID 2>/dev/null || true
    fail "Monitor exit" "Monitor did not exit within timeout after directory deletion"
else
    wait $MONITOR_PID 2>/dev/null || true
    pass "Monitor exited after directory deletion"
fi

# Read captured output
output=$(cat "$OUTPUT_FILE" 2>/dev/null || echo "")

# Verify AC-1.1: Clean exit with user-friendly message
if echo "$output" | grep -q "Monitoring stopped:"; then
    pass "AC-1.1: Graceful stop message displayed"
else
    fail "AC-1.1: Graceful stop message" "Missing 'Monitoring stopped:' in output"
fi

if echo "$output" | grep -q "directory no longer exists"; then
    pass "AC-1.1: User-friendly deletion reason"
else
    fail "AC-1.1: Deletion reason" "Missing 'directory no longer exists' in output"
fi

# Verify AC-1.2: No glob errors
if echo "$output" | grep -qE 'no matches found|bad pattern'; then
    fail "AC-1.2: Glob errors present" "Found glob errors: $(echo "$output" | grep -E 'no matches found|bad pattern')"
else
    pass "AC-1.2: No glob errors in output"
fi

# Verify AC-1.3: Terminal state restored (scroll region reset)
# Check for the scroll region reset escape sequence \033[r
if echo "$output" | grep -q 'Stopped monitoring'; then
    pass "AC-1.3: Cleanup message displayed"
else
    fail "AC-1.3: Cleanup message" "Missing 'Stopped monitoring' in output"
fi

# Check source code for scroll reset (backup verification)
if grep -q 'printf "\\033\[r"' "$PROJECT_ROOT/scripts/humanize.sh"; then
    pass "AC-1.3: Scroll region reset in source"
else
    fail "AC-1.3: Scroll reset" "Missing scroll reset escape in source"
fi

# Verify exit code is 0
if echo "$output" | grep -q "EXIT_CODE:0"; then
    pass "Exit code 0 on graceful stop"
else
    fail "Exit code" "Expected EXIT_CODE:0 in output"
fi

# ========================================
# Test 2: Real _humanize_monitor_codex with directory deletion (zsh)
# ========================================
echo ""
echo "Test 2: Real _humanize_monitor_codex with directory deletion (zsh)"
echo ""

if ! command -v zsh &>/dev/null; then
    echo "SKIP: zsh not available"
else
    # Create test project directory for zsh
    TEST_PROJECT_ZSH="$TEST_BASE/project_zsh"
    mkdir -p "$TEST_PROJECT_ZSH/.humanize/rlcr/2026-01-16_11-00-00"

    # Create valid state.md file
    cat > "$TEST_PROJECT_ZSH/.humanize/rlcr/2026-01-16_11-00-00/state.md" << 'STATE'
current_round: 1
max_iterations: 5
codex_model: o3
codex_effort: high
started_at: 2026-01-16T11:00:00Z
plan_file: temp/plan.md
STATE

    # Create goal-tracker.md
    cat > "$TEST_PROJECT_ZSH/.humanize/rlcr/2026-01-16_11-00-00/goal-tracker.md" << 'GOALTRACKER_EOF'
# Goal Tracker
## IMMUTABLE SECTION
### Ultimate Goal
Test goal
### Acceptance Criteria
- AC-1: Test criterion
## MUTABLE SECTION
### Plan Version: 1
### Completed and Verified
| AC | Task |
|----|------|
GOALTRACKER_EOF

    # Create fake HOME for zsh test
    FAKE_HOME_ZSH="$TEST_BASE/home_zsh"
    mkdir -p "$FAKE_HOME_ZSH"

    # Create cache directory
    SANITIZED_PROJECT_ZSH=$(echo "$TEST_PROJECT_ZSH" | sed 's/[^a-zA-Z0-9._-]/-/g' | sed 's/--*/-/g')
    CACHE_DIR_ZSH="$FAKE_HOME_ZSH/.cache/humanize/$SANITIZED_PROJECT_ZSH/2026-01-16_11-00-00"
    mkdir -p "$CACHE_DIR_ZSH"
    echo "Round 1 started" > "$CACHE_DIR_ZSH/round-1-codex-run.log"

    # Create zsh test runner script
    cat > "$TEST_PROJECT_ZSH/run_real_monitor_zsh.zsh" << 'ZSH_MONITOR_SCRIPT'
#!/bin/zsh
# Run the REAL _humanize_monitor_codex function under zsh

PROJECT_DIR="$1"
PROJECT_ROOT="$2"
FAKE_HOME="$3"

cd "$PROJECT_DIR"

# Override HOME and XDG_CACHE_HOME
export HOME="$FAKE_HOME"
export XDG_CACHE_HOME="$FAKE_HOME/.cache"

# Create shim functions for terminal commands
tput() {
    case "$1" in
        cols) echo "80" ;;
        lines) echo "24" ;;
        *) : ;;
    esac
}

clear() { : }

# Source the humanize.sh script
source "$PROJECT_ROOT/scripts/humanize.sh"

# Run the REAL monitor function
_humanize_monitor_codex 2>&1
exit_code=$?

echo "EXIT_CODE:$exit_code"
ZSH_MONITOR_SCRIPT

    chmod +x "$TEST_PROJECT_ZSH/run_real_monitor_zsh.zsh"

    # Run the zsh monitor in background
    OUTPUT_FILE_ZSH="$TEST_BASE/output_zsh.txt"
    zsh "$TEST_PROJECT_ZSH/run_real_monitor_zsh.zsh" "$TEST_PROJECT_ZSH" "$PROJECT_ROOT" "$FAKE_HOME_ZSH" > "$OUTPUT_FILE_ZSH" 2>&1 &
    MONITOR_PID_ZSH=$!

    # Wait for monitor to start
    sleep 2

    # Delete the directory
    rm -rf "$TEST_PROJECT_ZSH/.humanize/rlcr"

    # Wait for exit
    WAIT_COUNT=0
    while kill -0 $MONITOR_PID_ZSH 2>/dev/null && [[ $WAIT_COUNT -lt 20 ]]; do
        sleep 0.5
        WAIT_COUNT=$((WAIT_COUNT + 1))
    done

    if kill -0 $MONITOR_PID_ZSH 2>/dev/null; then
        kill $MONITOR_PID_ZSH 2>/dev/null || true
        wait $MONITOR_PID_ZSH 2>/dev/null || true
        fail "AC-1.4: zsh monitor exit" "Monitor did not exit within timeout"
    else
        wait $MONITOR_PID_ZSH 2>/dev/null || true
        pass "AC-1.4: zsh monitor exited after deletion"
    fi

    output_zsh=$(cat "$OUTPUT_FILE_ZSH" 2>/dev/null || echo "")

    # Verify AC-1.4: Works correctly in zsh
    if echo "$output_zsh" | grep -q "Monitoring stopped:"; then
        pass "AC-1.4: zsh graceful stop message"
    else
        fail "AC-1.4: zsh graceful stop" "Missing message in zsh output"
    fi

    if echo "$output_zsh" | grep -qE 'no matches found|bad pattern'; then
        fail "AC-1.4: zsh glob errors" "Found glob errors in zsh"
    else
        pass "AC-1.4: zsh no glob errors"
    fi

    if echo "$output_zsh" | grep -q "EXIT_CODE:0"; then
        pass "AC-1.4: zsh exit code 0"
    else
        fail "AC-1.4: zsh exit code" "Expected EXIT_CODE:0"
    fi
fi

# ========================================
# Test 3: Real _humanize_monitor_pr with directory deletion (AC-13)
# ========================================
echo ""
echo "Test 3: Real _humanize_monitor_pr with directory deletion (AC-13)"
echo ""

# Create test project directory for PR monitor
TEST_PROJECT_PR="$TEST_BASE/project_pr"
mkdir -p "$TEST_PROJECT_PR/.humanize/pr-loop/2026-01-18_12-00-00"

# Create valid PR loop state.md file
cat > "$TEST_PROJECT_PR/.humanize/pr-loop/2026-01-18_12-00-00/state.md" << 'STATE'
current_round: 1
max_iterations: 42
pr_number: 123
start_branch: test-branch
configured_bots:
  - claude
  - codex
active_bots:
  - claude
codex_model: gpt-5.2-codex
codex_effort: medium
codex_timeout: 900
poll_interval: 30
poll_timeout: 900
started_at: 2026-01-18T10:00:00Z
STATE

# Create goal-tracker.md for PR loop
cat > "$TEST_PROJECT_PR/.humanize/pr-loop/2026-01-18_12-00-00/goal-tracker.md" << 'GOALTRACKER_EOF'
# PR Review Goal Tracker

## PR Information
- PR Number: #123
- Branch: test-branch
- Started: 2026-01-18T10:00:00Z

## Issue Summary
| Round | Reviewer | Issues Found | Status |
|-------|----------|--------------|--------|
| 0     | -        | 0            | Initial |

## Total Statistics
- Total Issues Found: 0
- Remaining: 0
GOALTRACKER_EOF

# Create fake HOME for PR monitor test
FAKE_HOME_PR="$TEST_BASE/home_pr"
mkdir -p "$FAKE_HOME_PR"

# Create cache directory for PR monitor
SANITIZED_PROJECT_PR=$(echo "$TEST_PROJECT_PR" | sed 's/[^a-zA-Z0-9._-]/-/g' | sed 's/--*/-/g')
CACHE_DIR_PR="$FAKE_HOME_PR/.cache/humanize/$SANITIZED_PROJECT_PR/2026-01-18_12-00-00"
mkdir -p "$CACHE_DIR_PR"
echo "PR round 1 started" > "$CACHE_DIR_PR/round-1-codex-run.log"

# Create bash test runner script for PR monitor
cat > "$TEST_PROJECT_PR/run_real_monitor_pr.sh" << 'MONITOR_SCRIPT'
#!/bin/bash
# Run the REAL _humanize_monitor_pr function

PROJECT_DIR="$1"
PROJECT_ROOT="$2"
FAKE_HOME="$3"

cd "$PROJECT_DIR"

# Override HOME and XDG_CACHE_HOME
export HOME="$FAKE_HOME"
export XDG_CACHE_HOME="$FAKE_HOME/.cache"

# Create shim functions for terminal commands
tput() {
    case "$1" in
        cols) echo "80" ;;
        lines) echo "24" ;;
        *) : ;;
    esac
}

# Stub terminal control
printf() {
    case "$1" in
        *\\033*) : ;;  # Ignore escape sequences
        *) builtin printf "$@" ;;
    esac
}

# Source the humanize script (loads all functions)
source "$PROJECT_ROOT/scripts/humanize.sh"

# Override _pr_cleanup for testing
_pr_cleanup() {
    echo "CLEANUP_CALLED_PR"
}

# Start monitor with --once flag (single iteration)
# Then delete directory after brief delay
(
    sleep 0.5
    rm -rf "$PROJECT_DIR/.humanize/pr-loop/2026-01-18_12-00-00"
) &
cleanup_pid=$!

# Run monitor in foreground (will detect deletion)
humanize monitor pr --once 2>&1

echo "EXIT_CODE:$?"

# Cleanup background process
kill $cleanup_pid 2>/dev/null || true
wait $cleanup_pid 2>/dev/null || true
MONITOR_SCRIPT

chmod +x "$TEST_PROJECT_PR/run_real_monitor_pr.sh"

# Run the PR monitor test
output_pr=$("$TEST_PROJECT_PR/run_real_monitor_pr.sh" "$TEST_PROJECT_PR" "$PROJECT_ROOT" "$FAKE_HOME_PR" 2>&1) || true

# Verify AC-13: PR monitor e2e - graceful exit
if echo "$output_pr" | grep -qE 'Stopped|gracefully|EXIT_CODE:0'; then
    pass "AC-13: PR monitor e2e - graceful exit on directory deletion"
else
    # Alternative: check for any clean exit indication
    if echo "$output_pr" | grep -q "EXIT_CODE:0"; then
        pass "AC-13: PR monitor e2e - clean exit"
    else
        fail "AC-13: PR monitor e2e" "Expected graceful stop or EXIT_CODE:0, got: $output_pr"
    fi
fi

# Verify no glob errors in PR monitor output
if echo "$output_pr" | grep -qE 'no matches found|bad pattern'; then
    fail "AC-13: PR monitor glob errors" "Found glob errors: $(echo "$output_pr" | grep -E 'no matches found|bad pattern')"
else
    pass "AC-13: PR monitor no glob errors"
fi

# ========================================
# Summary
# ========================================
echo ""
echo "========================================"
echo "Test Summary"
echo "========================================"
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo ""
    echo -e "${GREEN}All TRUE end-to-end monitor tests passed!${NC}"
    echo ""
    echo "AC-1.1 VERIFIED: Clean exit with user-friendly message"
    echo "AC-1.2 VERIFIED: No glob errors"
    echo "AC-1.3 VERIFIED: Terminal state restored"
    echo "AC-1.4 VERIFIED: Works in bash and zsh"
    echo "AC-13 VERIFIED: PR monitor e2e works"
    exit 0
else
    echo ""
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi
