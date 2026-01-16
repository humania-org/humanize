#!/bin/bash
#
# Tests for Finalize Phase feature
#
# Positive Test Cases:
# - T-POS-1: COMPLETE triggers Finalize entry
# - T-POS-2: Finalize Phase completion flow
# - T-POS-3: Finalized-state detected as active loop
# - T-POS-4: Finalize summary file writable
# - T-POS-5: Normal RLCR rounds unaffected
#
# Negative Test Cases:
# - T-NEG-1: Max iterations skips Finalize
# - T-NEG-2: Finalize still requires git clean
# - T-NEG-3: Finalize still requires summary
# - T-NEG-4: Finalize still requires todos complete
# - T-NEG-5: Finalized-state file protected
# - T-NEG-6: Complete-state not detected as active
# - T-NEG-7: Finalize phase does not trigger Codex
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Test helpers
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

pass() { echo -e "${GREEN}PASS${NC}: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}FAIL${NC}: $1"; echo "  Expected: $2"; echo "  Got: $3"; TESTS_FAILED=$((TESTS_FAILED + 1)); }
skip() { echo -e "${YELLOW}SKIP${NC}: $1 - $2"; TESTS_SKIPPED=$((TESTS_SKIPPED + 1)); }

# Setup test environment
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

# Source the loop-common.sh to get helper functions
source "$PROJECT_ROOT/hooks/lib/loop-common.sh"

# Create a mock codex that outputs COMPLETE or custom content
setup_mock_codex() {
    local output="$1"
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/codex" << EOF
#!/bin/bash
# Mock codex - outputs the provided content
if [[ "\$1" == "exec" ]]; then
    cat << 'REVIEW'
$output
REVIEW
fi
EOF
    chmod +x "$TEST_DIR/bin/codex"
    export PATH="$TEST_DIR/bin:$PATH"
}

# Create a mock codex that tracks if it was called
setup_mock_codex_with_tracking() {
    local output="$1"
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/codex" << EOF
#!/bin/bash
# Track that codex was called
echo "CODEX_WAS_CALLED" > "$TEST_DIR/codex_called.marker"
if [[ "\$1" == "exec" ]]; then
    cat << 'REVIEW'
$output
REVIEW
fi
EOF
    chmod +x "$TEST_DIR/bin/codex"
    export PATH="$TEST_DIR/bin:$PATH"
    rm -f "$TEST_DIR/codex_called.marker"
}

setup_test_repo() {
    cd "$TEST_DIR"

    if [[ ! -d ".git" ]]; then
        git init -q
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "init" > init.txt
        git add init.txt
        git -c commit.gpgsign=false commit -q -m "Initial"

        # Create a plan file
        mkdir -p plans
        cat > plans/test-plan.md << 'EOF'
# Test Plan
## Goal
Test the RLCR loop
## Requirements
- Requirement 1
- Requirement 2
- Requirement 3
EOF
        # Add .humanize and bin to gitignore (they are created by tests)
        cat >> .gitignore << 'GITIGNORE'
plans/
.humanize/
.humanize*
bin/
GITIGNORE
        git add .gitignore
        git -c commit.gpgsign=false commit -q -m "Add gitignore"
    fi
}

setup_loop_dir() {
    local round="$1"
    local max_iter="${2:-42}"

    LOOP_DIR="$TEST_DIR/.humanize/rlcr/2024-01-01_12-00-00"
    mkdir -p "$LOOP_DIR"

    local current_branch
    current_branch=$(git rev-parse --abbrev-ref HEAD)

    cat > "$LOOP_DIR/state.md" << EOF
---
current_round: $round
max_iterations: $max_iter
codex_model: gpt-5.2-codex
codex_effort: high
codex_timeout: 5400
push_every_round: false
plan_file: plans/test-plan.md
plan_tracked: false
start_branch: $current_branch
started_at: 2024-01-01T12:00:00Z
---
EOF

    # Create plan backup
    cp plans/test-plan.md "$LOOP_DIR/plan.md"

    # Create goal tracker
    cat > "$LOOP_DIR/goal-tracker.md" << 'EOF'
# Goal Tracker
## IMMUTABLE SECTION
### Ultimate Goal
Test finalize phase
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
EOF
}

echo "=== Test: Finalize Phase Feature ==="
echo ""

# ========================================
# Test: Helper Functions
# ========================================
echo "=== Helper Function Tests ==="
echo ""

# Test: is_finalized_state_file_path
echo "Test: is_finalized_state_file_path matches finalized-state.md"
if is_finalized_state_file_path "finalized-state.md"; then
    pass "is_finalized_state_file_path matches finalized-state.md"
else
    fail "is_finalized_state_file_path" "true" "false"
fi

echo "Test: is_finalized_state_file_path does not match state.md"
if is_finalized_state_file_path "state.md"; then
    fail "is_finalized_state_file_path on state.md" "false" "true"
else
    pass "is_finalized_state_file_path does not match state.md"
fi

echo "Test: is_finalized_state_file_path matches full path"
if is_finalized_state_file_path "/path/to/loop/finalized-state.md"; then
    pass "is_finalized_state_file_path matches full path"
else
    fail "is_finalized_state_file_path full path" "true" "false"
fi

# Test: is_finalize_summary_path
echo "Test: is_finalize_summary_path matches finalize-summary.md"
if is_finalize_summary_path "finalize-summary.md"; then
    pass "is_finalize_summary_path matches finalize-summary.md"
else
    fail "is_finalize_summary_path" "true" "false"
fi

echo "Test: is_finalize_summary_path does not match round-N-summary.md"
if is_finalize_summary_path "round-0-summary.md"; then
    fail "is_finalize_summary_path on round-N-summary.md" "false" "true"
else
    pass "is_finalize_summary_path does not match round-N-summary.md"
fi

echo "Test: finalized_state_file_blocked_message function exists"
if type finalized_state_file_blocked_message &>/dev/null; then
    pass "finalized_state_file_blocked_message function exists"
else
    fail "finalized_state_file_blocked_message" "function defined" "function not found"
fi

echo ""
echo "=== T-POS-3: Finalized-State Detection ==="
echo ""

setup_test_repo
setup_loop_dir 5
export CLAUDE_PROJECT_DIR="$TEST_DIR"

# Replace state.md with finalized-state.md
mv "$LOOP_DIR/state.md" "$LOOP_DIR/finalized-state.md"

echo "T-POS-3: finalized-state.md detected as active loop"
ACTIVE_LOOP=$(find_active_loop "$TEST_DIR/.humanize/rlcr")
if [[ -n "$ACTIVE_LOOP" ]]; then
    pass "finalized-state.md detected as active loop"
else
    fail "finalized-state.md detection" "active loop found" "no active loop"
fi

echo ""
echo "=== T-NEG-6: Complete-State Not Active ==="
echo ""

# Replace with complete-state.md
rm -f "$LOOP_DIR/finalized-state.md"
cat > "$LOOP_DIR/complete-state.md" << 'EOF'
---
current_round: 5
max_iterations: 42
---
EOF

echo "T-NEG-6: complete-state.md not detected as active loop"
ACTIVE_LOOP=$(find_active_loop "$TEST_DIR/.humanize/rlcr")
if [[ -z "$ACTIVE_LOOP" ]]; then
    pass "complete-state.md not detected as active loop"
else
    fail "complete-state.md detection" "no active loop" "$ACTIVE_LOOP"
fi

echo ""
echo "=== T-POS-5: Normal RLCR Rounds Unaffected ==="
echo ""

rm -f "$LOOP_DIR/complete-state.md"
setup_loop_dir 3

echo "T-POS-5: state.md still detected as active loop"
ACTIVE_LOOP=$(find_active_loop "$TEST_DIR/.humanize/rlcr")
if [[ -n "$ACTIVE_LOOP" ]]; then
    pass "state.md still detected as active loop"
else
    fail "state.md detection" "active loop found" "no active loop"
fi

echo ""
echo "=== T-POS-4 & T-NEG-5: Write Validator Tests ==="
echo ""

# Reset to finalize phase
setup_loop_dir 5
mv "$LOOP_DIR/state.md" "$LOOP_DIR/finalized-state.md"

echo "T-POS-4: Write validator allows finalize-summary.md"
HOOK_INPUT='{"tool_name": "Write", "tool_input": {"file_path": "'$LOOP_DIR'/finalize-summary.md"}}'
set +e
RESULT=$(echo "$HOOK_INPUT" | "$PROJECT_ROOT/hooks/loop-write-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Write validator allows finalize-summary.md"
else
    fail "Write validator finalize-summary.md" "exit 0" "exit $EXIT_CODE, output: $RESULT"
fi

echo "T-NEG-5: Write validator blocks finalized-state.md"
HOOK_INPUT='{"tool_name": "Write", "tool_input": {"file_path": "'$LOOP_DIR'/finalized-state.md"}}'
set +e
RESULT=$(echo "$HOOK_INPUT" | "$PROJECT_ROOT/hooks/loop-write-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 2 ]] && echo "$RESULT" | grep -qi "finalized"; then
    pass "Write validator blocks finalized-state.md"
else
    fail "Write validator finalized-state.md" "exit 2 with finalized error" "exit $EXIT_CODE, output: $RESULT"
fi

echo "T-NEG-5b: Edit validator blocks finalized-state.md"
HOOK_INPUT='{"tool_name": "Edit", "tool_input": {"file_path": "'$LOOP_DIR'/finalized-state.md"}}'
set +e
RESULT=$(echo "$HOOK_INPUT" | "$PROJECT_ROOT/hooks/loop-edit-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 2 ]] && echo "$RESULT" | grep -qi "finalized"; then
    pass "Edit validator blocks finalized-state.md"
else
    fail "Edit validator finalized-state.md" "exit 2 with finalized error" "exit $EXIT_CODE, output: $RESULT"
fi

echo "T-NEG-5c: Bash validator blocks finalized-state.md modification"
HOOK_INPUT='{"tool_name": "Bash", "tool_input": {"command": "echo test > '$LOOP_DIR'/finalized-state.md"}}'
set +e
RESULT=$(echo "$HOOK_INPUT" | "$PROJECT_ROOT/hooks/loop-bash-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 2 ]] && echo "$RESULT" | grep -qi "finalized"; then
    pass "Bash validator blocks finalized-state.md modification"
else
    fail "Bash validator finalized-state.md" "exit 2 with finalized error" "exit $EXIT_CODE, output: $RESULT"
fi

echo ""
echo "=== T-POS-2 & T-NEG-2/3/7: Stop Hook Finalize Phase Tests ==="
echo ""

# Setup for Stop Hook tests
setup_test_repo
setup_loop_dir 5
mv "$LOOP_DIR/state.md" "$LOOP_DIR/finalized-state.md"
setup_mock_codex_with_tracking "All looks good.

COMPLETE"

# T-NEG-3: Missing summary blocks exit
echo "T-NEG-3: Finalize phase blocks exit when summary missing"
# Ensure no summary exists
rm -f "$LOOP_DIR/finalize-summary.md"
# Create empty hook input (minimal for Stop hook)
HOOK_INPUT='{"stop_hook_active": false, "transcript": []}'
set +e
RESULT=$(echo "$HOOK_INPUT" | "$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh" 2>&1)
EXIT_CODE=$?
set -e
# Check if it blocks with missing summary message
if echo "$RESULT" | grep -q '"decision".*block' && echo "$RESULT" | grep -qi "summary"; then
    pass "Finalize phase blocks exit when summary missing"
else
    fail "Finalize phase missing summary check" "block with summary error" "exit $EXIT_CODE, output: $RESULT"
fi

# T-NEG-7: Verify Codex was NOT called
echo "T-NEG-7: Finalize phase does not invoke Codex"
if [[ ! -f "$TEST_DIR/codex_called.marker" ]]; then
    pass "Finalize phase does not invoke Codex (summary check)"
else
    fail "Finalize phase Codex invocation" "Codex not called" "Codex was called"
fi

# T-NEG-2: Git not clean blocks exit
echo "T-NEG-2: Finalize phase blocks exit when git not clean"
# Create finalize-summary.md so it passes that check
cat > "$LOOP_DIR/finalize-summary.md" << 'EOF'
# Finalize Summary
Simplified code.
EOF
# Create uncommitted changes
echo "uncommitted" > "$TEST_DIR/dirty.txt"
set +e
RESULT=$(echo "$HOOK_INPUT" | "$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh" 2>&1)
EXIT_CODE=$?
set -e
if echo "$RESULT" | grep -q '"decision".*block' && echo "$RESULT" | grep -qi "uncommitted\|git\|clean"; then
    pass "Finalize phase blocks exit when git not clean"
else
    fail "Finalize phase git clean check" "block with git error" "exit $EXIT_CODE, output: $RESULT"
fi

# Clean up git state
rm -f "$TEST_DIR/dirty.txt"

# T-POS-2: Finalize phase completes when all checks pass
echo "T-POS-2: Finalize phase completes when all checks pass"
# Ensure git is clean
git -C "$TEST_DIR" status --porcelain
# Clear codex marker
rm -f "$TEST_DIR/codex_called.marker"
set +e
RESULT=$(echo "$HOOK_INPUT" | "$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh" 2>&1)
EXIT_CODE=$?
set -e
# Should allow exit (exit 0, no block decision)
if [[ $EXIT_CODE -eq 0 ]] && ! echo "$RESULT" | grep -q '"decision".*block'; then
    # Also verify state file renamed to complete-state.md
    if [[ -f "$LOOP_DIR/complete-state.md" ]] && [[ ! -f "$LOOP_DIR/finalized-state.md" ]]; then
        pass "Finalize phase completes and renames to complete-state.md"
    else
        fail "Finalize phase completion" "finalized-state.md renamed to complete-state.md" "state files: $(ls $LOOP_DIR/*state*.md 2>/dev/null || echo 'none')"
    fi
else
    fail "Finalize phase completion" "exit 0, no block" "exit $EXIT_CODE, output: $RESULT"
fi

# T-NEG-7 continued: Verify Codex was NOT called during completion
echo "T-NEG-7b: Finalize phase completion does not invoke Codex"
if [[ ! -f "$TEST_DIR/codex_called.marker" ]]; then
    pass "Finalize phase completion does not invoke Codex"
else
    fail "Finalize phase completion Codex" "Codex not called" "Codex was called"
fi

echo ""
echo "=== T-POS-1 & T-NEG-1: COMPLETE Handling Tests ==="
echo ""

# Reset test environment for COMPLETE handling tests
rm -rf "$TEST_DIR/.humanize"
setup_test_repo
setup_loop_dir 3 10  # current_round: 3, max_iterations: 10
setup_mock_codex "All requirements met.

COMPLETE"

# Create summary for current round
cat > "$LOOP_DIR/round-3-summary.md" << 'EOF'
# Round 3 Summary
Implemented all features.
EOF

echo "T-POS-1: COMPLETE triggers Finalize Phase entry"
HOOK_INPUT='{"stop_hook_active": false, "transcript": []}'
set +e
RESULT=$(echo "$HOOK_INPUT" | "$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh" 2>&1)
EXIT_CODE=$?
set -e
# Should block with Finalize phase prompt and create finalized-state.md
if echo "$RESULT" | grep -q '"decision".*block' && [[ -f "$LOOP_DIR/finalized-state.md" ]] && [[ ! -f "$LOOP_DIR/state.md" ]]; then
    # Also check the prompt mentions code-simplifier
    if echo "$RESULT" | grep -qi "simplif"; then
        pass "COMPLETE triggers Finalize Phase (state.md -> finalized-state.md, block with Finalize prompt)"
    else
        fail "COMPLETE Finalize prompt" "prompt mentioning simplification" "output: $RESULT"
    fi
else
    fail "COMPLETE Finalize entry" "block with finalized-state.md" "exit $EXIT_CODE, files: $(ls $LOOP_DIR/*state*.md 2>/dev/null || echo 'none'), output: $RESULT"
fi

# T-NEG-1: Max iterations skips Finalize
echo "T-NEG-1: Max iterations skips Finalize Phase"
rm -rf "$TEST_DIR/.humanize"
setup_loop_dir 10 10  # current_round: 10, max_iterations: 10 (at max)
# Create summary for current round
cat > "$LOOP_DIR/round-10-summary.md" << 'EOF'
# Round 10 Summary
Final iteration.
EOF
set +e
RESULT=$(echo "$HOOK_INPUT" | "$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh" 2>&1)
EXIT_CODE=$?
set -e
# Should NOT create finalized-state.md, should create maxiter-state.md
if [[ -f "$LOOP_DIR/maxiter-state.md" ]] && [[ ! -f "$LOOP_DIR/finalized-state.md" ]] && [[ ! -f "$LOOP_DIR/state.md" ]]; then
    pass "Max iterations skips Finalize Phase (creates maxiter-state.md)"
else
    fail "Max iterations skip Finalize" "maxiter-state.md (no finalized-state.md)" "files: $(ls $LOOP_DIR/*state*.md 2>/dev/null || echo 'none')"
fi

echo ""
echo "=== Validator Finalize Phase State Parsing Tests ==="
echo ""

# Test that validators correctly parse finalized-state.md
rm -rf "$TEST_DIR/.humanize"
setup_test_repo
setup_loop_dir 5
mv "$LOOP_DIR/state.md" "$LOOP_DIR/finalized-state.md"

echo "Test: Bash validator parses finalized-state.md correctly"
# The bash validator should not error when only finalized-state.md exists
HOOK_INPUT='{"tool_name": "Bash", "tool_input": {"command": "ls"}}'
set +e
RESULT=$(echo "$HOOK_INPUT" | "$PROJECT_ROOT/hooks/loop-bash-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Bash validator parses finalized-state.md without errors"
else
    fail "Bash validator finalized-state.md parsing" "exit 0" "exit $EXIT_CODE, output: $RESULT"
fi

echo "Test: Read validator parses finalized-state.md correctly"
# Try to read current round summary (round 5)
HOOK_INPUT='{"tool_name": "Read", "tool_input": {"file_path": "'$LOOP_DIR'/round-5-summary.md"}}'
set +e
RESULT=$(echo "$HOOK_INPUT" | "$PROJECT_ROOT/hooks/loop-read-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
# Should allow read of current round file
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Read validator parses finalized-state.md and allows current round"
else
    fail "Read validator finalized-state.md parsing" "exit 0" "exit $EXIT_CODE, output: $RESULT"
fi

echo ""
echo "========================================="
echo "Test Results"
echo "========================================="
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
echo -e "Skipped: ${YELLOW}$TESTS_SKIPPED${NC}"
echo ""

exit $TESTS_FAILED
