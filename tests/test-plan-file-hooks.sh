#!/bin/bash
#
# Tests for plan file hooks during RLCR loop
#
# Tests:
# - UserPromptSubmit hook (loop-plan-file-validator.sh)
# - Write validator blocking plan.md
# - Edit validator blocking plan.md
# - Bash validator blocking plan.md modifications
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

setup_test_loop() {
    cd "$TEST_DIR"

    # Only init git if not already initialized
    if [[ ! -d ".git" ]]; then
        git init -q
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "initial" > init.txt
        git add init.txt
        git commit -q -m "Initial commit"
    fi

    # Create loop directory structure
    LOOP_DIR="$TEST_DIR/.humanize-loop.local/2024-01-01_12-00-00"
    mkdir -p "$LOOP_DIR"

    # Create plan file (gitignored)
    mkdir -p plans
    cat > plans/test-plan.md << 'EOF'
# Test Plan
## Goal
Test the RLCR loop
## Requirements
- Requirement 1
EOF
    echo "plans/" >> .gitignore
    git add .gitignore
    git commit -q -m "Add gitignore"

    # Create plan backup
    cp plans/test-plan.md "$LOOP_DIR/plan.md"

    # Create state file with v1.1.2+ fields (plan_file is quoted in YAML)
    cat > "$LOOP_DIR/state.md" << EOF
---
current_round: 0
max_iterations: 42
plan_file: "plans/test-plan.md"
plan_tracked: false
start_branch: main
---
EOF
}

echo "=== Test: UserPromptSubmit Hook ==="
echo ""

# Test 1: Hook passes with valid state
setup_test_loop
export CLAUDE_PROJECT_DIR="$TEST_DIR"

echo "Test 1: Hook passes with valid state"
set +e
RESULT=$(echo '{}' | "$PROJECT_ROOT/hooks/loop-plan-file-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]] && [[ -z "$RESULT" ]]; then
    pass "Hook passes with valid state"
else
    fail "Hook with valid state" "exit 0, no output" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 1.5: Hook correctly parses YAML-quoted plan_file
echo "Test 1.5: Hook correctly parses YAML-quoted plan_file"
# The hook should strip quotes and find the plan file correctly
set +e
RESULT=$(echo '{}' | "$PROJECT_ROOT/hooks/loop-plan-file-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
# If the plan_file wasn't parsed correctly, it would fail to find the file
# and might block. Success means empty output and exit 0.
if [[ $EXIT_CODE -eq 0 ]] && [[ -z "$RESULT" ]]; then
    pass "Hook correctly parses YAML-quoted plan_file"
else
    fail "Hook parsing YAML-quoted plan_file" "exit 0, no output" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 2: Hook blocks when plan_tracked field is missing
echo "Test 2: Hook blocks when plan_tracked field is missing"
cat > "$LOOP_DIR/state.md" << 'EOF'
---
current_round: 0
max_iterations: 42
plan_file: "plans/test-plan.md"
start_branch: main
---
EOF
set +e
RESULT=$(echo '{}' | "$PROJECT_ROOT/hooks/loop-plan-file-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]] && echo "$RESULT" | grep -q "plan_tracked"; then
    pass "Hook blocks on missing plan_tracked"
else
    fail "Hook blocking missing plan_tracked" "block with plan_tracked error" "$RESULT"
fi

# Test 3: Hook blocks when start_branch field is missing
echo "Test 3: Hook blocks when start_branch field is missing"
cat > "$LOOP_DIR/state.md" << 'EOF'
---
current_round: 0
max_iterations: 42
plan_file: "plans/test-plan.md"
plan_tracked: false
---
EOF
set +e
RESULT=$(echo '{}' | "$PROJECT_ROOT/hooks/loop-plan-file-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]] && echo "$RESULT" | grep -q "start_branch"; then
    pass "Hook blocks on missing start_branch"
else
    fail "Hook blocking missing start_branch" "block with start_branch error" "$RESULT"
fi

# Restore valid state for remaining tests
setup_test_loop

# Test 4: Hook blocks when branch changes
echo "Test 4: Hook blocks when branch changes"
git checkout -q -b feature-branch
cat > "$LOOP_DIR/state.md" << 'EOF'
---
current_round: 0
max_iterations: 42
plan_file: "plans/test-plan.md"
plan_tracked: false
start_branch: main
---
EOF
set +e
RESULT=$(echo '{}' | "$PROJECT_ROOT/hooks/loop-plan-file-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]] && echo "$RESULT" | grep -q "branch"; then
    pass "Hook blocks on branch change"
else
    fail "Hook blocking branch change" "block with branch error" "$RESULT"
fi
git checkout -q main

echo ""
echo "=== Test: Write Validator ==="
echo ""

# Restore state
setup_test_loop

# Test 5: Write validator blocks plan.md in loop directory
echo "Test 5: Block writes to plan.md backup"
HOOK_INPUT='{"tool_name": "Write", "tool_input": {"file_path": "'$LOOP_DIR'/plan.md"}}'
set +e
RESULT=$(echo "$HOOK_INPUT" | "$PROJECT_ROOT/hooks/loop-write-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 2 ]] && echo "$RESULT" | grep -qi "plan"; then
    pass "Write validator blocks plan.md backup"
else
    fail "Write validator blocking plan.md" "exit 2 with plan error" "exit $EXIT_CODE, output: $RESULT"
fi

echo ""
echo "=== Test: Edit Validator ==="
echo ""

# Test 6: Edit validator blocks plan.md in loop directory
echo "Test 6: Block edits to plan.md backup"
HOOK_INPUT='{"tool_name": "Edit", "tool_input": {"file_path": "'$LOOP_DIR'/plan.md"}}'
set +e
RESULT=$(echo "$HOOK_INPUT" | "$PROJECT_ROOT/hooks/loop-edit-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 2 ]] && echo "$RESULT" | grep -qi "plan"; then
    pass "Edit validator blocks plan.md backup"
else
    fail "Edit validator blocking plan.md" "exit 2 with plan error" "exit $EXIT_CODE, output: $RESULT"
fi

echo ""
echo "=== Test: Bash Validator ==="
echo ""

# Test 7: Bash validator blocks modifications to plan.md
echo "Test 7: Block bash modifications to plan.md backup"
HOOK_INPUT='{"tool_name": "Bash", "tool_input": {"command": "echo test > '$LOOP_DIR'/plan.md"}}'
set +e
RESULT=$(echo "$HOOK_INPUT" | "$PROJECT_ROOT/hooks/loop-bash-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 2 ]] && echo "$RESULT" | grep -qi "plan"; then
    pass "Bash validator blocks plan.md modification"
else
    fail "Bash validator blocking plan.md" "exit 2 with plan error" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 8: Bash validator blocks rm on plan.md
echo "Test 8: Block bash rm on plan.md backup"
HOOK_INPUT='{"tool_name": "Bash", "tool_input": {"command": "rm '$LOOP_DIR'/plan.md"}}'
set +e
RESULT=$(echo "$HOOK_INPUT" | "$PROJECT_ROOT/hooks/loop-bash-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 2 ]] && echo "$RESULT" | grep -qi "plan"; then
    pass "Bash validator blocks rm on plan.md"
else
    fail "Bash validator blocking rm" "exit 2 with plan error" "exit $EXIT_CODE, output: $RESULT"
fi

echo ""
echo "=== Test: Stop Hook Plan File Integrity ==="
echo ""

# Test 9: Stop hook blocks when plan file has been modified
echo "Test 9: Stop hook blocks when plan file is modified"
setup_test_loop
# Modify the project plan file (different from backup)
echo "# Modified content" >> "$TEST_DIR/plans/test-plan.md"
# Create a summary file so the hook doesn't fail on that check first
cat > "$LOOP_DIR/round-0-summary.md" << 'EOF'
# Summary
Work done.
EOF
# Create goal tracker so the hook doesn't fail on that check
cat > "$LOOP_DIR/goal-tracker.md" << 'EOF'
# Goal Tracker
## IMMUTABLE SECTION
### Ultimate Goal
Test goal
### Acceptance Criteria
- Criterion 1
## MUTABLE SECTION
### Plan Version: 1 (Updated: Round 0)
#### Plan Evolution Log
| Round | Change | Reason | Impact on AC |
|-------|--------|--------|--------------|
| 0 | Initial plan | - | - |
#### Active Tasks
| Task | Target AC | Status | Notes |
|------|-----------|--------|-------|
| Task 1 | AC1 | in_progress | - |
EOF
set +e
RESULT=$(echo '{}' | "$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh" 2>&1)
EXIT_CODE=$?
set -e
# The hook should output JSON with "block" decision and mention plan file modified
if echo "$RESULT" | grep -q '"decision"' && echo "$RESULT" | grep -qi "plan.*modified"; then
    pass "Stop hook blocks when plan file is modified"
else
    fail "Stop hook plan modification detection" "block with plan modified error" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 10: Stop hook blocks when plan file is deleted
echo "Test 10: Stop hook blocks when plan file is deleted"
setup_test_loop
# Delete the project plan file
rm -f "$TEST_DIR/plans/test-plan.md"
# Create necessary files
cat > "$LOOP_DIR/round-0-summary.md" << 'EOF'
# Summary
Work done.
EOF
cat > "$LOOP_DIR/goal-tracker.md" << 'EOF'
# Goal Tracker
## IMMUTABLE SECTION
### Ultimate Goal
Test goal
### Acceptance Criteria
- Criterion 1
## MUTABLE SECTION
### Plan Version: 1 (Updated: Round 0)
#### Active Tasks
| Task | Target AC | Status | Notes |
|------|-----------|--------|-------|
| Task 1 | AC1 | done | - |
EOF
set +e
RESULT=$(echo '{}' | "$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh" 2>&1)
EXIT_CODE=$?
set -e
if echo "$RESULT" | grep -q '"decision"' && echo "$RESULT" | grep -qi "plan.*deleted"; then
    pass "Stop hook blocks when plan file is deleted"
else
    fail "Stop hook plan deletion detection" "block with plan deleted error" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 11: Stop hook blocks when plan backup is missing
echo "Test 11: Stop hook blocks when plan backup is missing"
setup_test_loop
# Remove the backup
rm -f "$LOOP_DIR/plan.md"
cat > "$LOOP_DIR/round-0-summary.md" << 'EOF'
# Summary
Work done.
EOF
set +e
RESULT=$(echo '{}' | "$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh" 2>&1)
EXIT_CODE=$?
set -e
if echo "$RESULT" | grep -q '"decision"' && echo "$RESULT" | grep -qi "backup.*not found\|plan.*backup"; then
    pass "Stop hook blocks when plan backup is missing"
else
    fail "Stop hook plan backup detection" "block with backup missing error" "exit $EXIT_CODE, output: $RESULT"
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
