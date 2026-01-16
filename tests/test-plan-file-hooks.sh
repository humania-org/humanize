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

# Default branch name (set after first git init)
DEFAULT_BRANCH=""

setup_test_loop() {
    cd "$TEST_DIR"

    # Only init git if not already initialized
    if [[ ! -d ".git" ]]; then
        git init -q
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "initial" > init.txt
        git add init.txt
        git -c commit.gpgsign=false commit -q -m "Initial commit"
        # Capture default branch name (main or master depending on git version)
        DEFAULT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    fi

    # Get current branch name (handles both 'main' and 'master' defaults)
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

    # Create loop directory structure
    LOOP_DIR="$TEST_DIR/.humanize/rlcr/2024-01-01_12-00-00"
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
    git -c commit.gpgsign=false commit -q -m "Add gitignore"

    # Create plan backup
    cp plans/test-plan.md "$LOOP_DIR/plan.md"

    # Create state file with v1.1.2+ fields (plan_file is quoted in YAML)
    # Use actual branch name to handle both 'main' and 'master' defaults
    cat > "$LOOP_DIR/state.md" << EOF
---
current_round: 0
max_iterations: 42
plan_file: "plans/test-plan.md"
plan_tracked: false
start_branch: $CURRENT_BRANCH
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
cat > "$LOOP_DIR/state.md" << EOF
---
current_round: 0
max_iterations: 42
plan_file: "plans/test-plan.md"
start_branch: $DEFAULT_BRANCH
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
cat > "$LOOP_DIR/state.md" << EOF
---
current_round: 0
max_iterations: 42
plan_file: "plans/test-plan.md"
plan_tracked: false
start_branch: $DEFAULT_BRANCH
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
git checkout -q "$DEFAULT_BRANCH"

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

# Test 8a: Bash validator blocks direct .humanize/rlcr/plan.md (no intermediate dir)
# This tests Fix #1 for the regex bypass vulnerability
echo "Test 8a: Block bash modifications to direct .humanize/rlcr/plan.md"
HOOK_INPUT='{"tool_name": "Bash", "tool_input": {"command": "echo evil > .humanize/rlcr/plan.md"}}'
set +e
RESULT=$(echo "$HOOK_INPUT" | "$PROJECT_ROOT/hooks/loop-bash-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 2 ]] && echo "$RESULT" | grep -qi "plan"; then
    pass "Bash validator blocks direct .humanize/rlcr/plan.md"
else
    fail "Bash validator direct plan.md" "exit 2 with plan error" "exit $EXIT_CODE, output: $RESULT"
fi

echo ""
echo "=== Test: Command Injection Bypass Prevention ==="
echo ""

# Test 8.1: Block command substitution bypass attempt
echo "Test 8.1: Block command substitution bypass"
HOOK_INPUT='{"tool_name": "Bash", "tool_input": {"command": "echo test > .humanize/rlcr/$(date +%Y)/plan.md"}}'
set +e
RESULT=$(echo "$HOOK_INPUT" | "$PROJECT_ROOT/hooks/loop-bash-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 2 ]] && echo "$RESULT" | grep -qi "plan"; then
    pass "Bash validator blocks command substitution bypass"
else
    fail "Command substitution bypass" "exit 2 with plan error" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 8.2: Block glob expansion bypass attempt
echo "Test 8.2: Block glob expansion bypass"
HOOK_INPUT='{"tool_name": "Bash", "tool_input": {"command": "echo test > .humanize/rlcr/*/plan.md"}}'
set +e
RESULT=$(echo "$HOOK_INPUT" | "$PROJECT_ROOT/hooks/loop-bash-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 2 ]] && echo "$RESULT" | grep -qi "plan"; then
    pass "Bash validator blocks glob expansion bypass"
else
    fail "Glob expansion bypass" "exit 2 with plan error" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 8.3: Block brace expansion bypass attempt
echo "Test 8.3: Block brace expansion bypass"
HOOK_INPUT='{"tool_name": "Bash", "tool_input": {"command": "tee .humanize/rlcr/{a,b,c}/plan.md"}}'
set +e
RESULT=$(echo "$HOOK_INPUT" | "$PROJECT_ROOT/hooks/loop-bash-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 2 ]] && echo "$RESULT" | grep -qi "plan"; then
    pass "Bash validator blocks brace expansion bypass"
else
    fail "Brace expansion bypass" "exit 2 with plan error" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 8.4: Block piped command bypass attempt
echo "Test 8.4: Block piped command bypass"
HOOK_INPUT='{"tool_name": "Bash", "tool_input": {"command": "cat input.txt | tee .humanize/rlcr/2024-01-01_12-00-00/plan.md"}}'
set +e
RESULT=$(echo "$HOOK_INPUT" | "$PROJECT_ROOT/hooks/loop-bash-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 2 ]] && echo "$RESULT" | grep -qi "plan"; then
    pass "Bash validator blocks piped command bypass"
else
    fail "Piped command bypass" "exit 2 with plan error" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 8.5: Block backtick command substitution bypass
echo "Test 8.5: Block backtick command substitution bypass"
HOOK_INPUT='{"tool_name": "Bash", "tool_input": {"command": "echo test > .humanize/rlcr/`echo test`/plan.md"}}'
set +e
RESULT=$(echo "$HOOK_INPUT" | "$PROJECT_ROOT/hooks/loop-bash-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 2 ]] && echo "$RESULT" | grep -qi "plan"; then
    pass "Bash validator blocks backtick substitution bypass"
else
    fail "Backtick substitution bypass" "exit 2 with plan error" "exit $EXIT_CODE, output: $RESULT"
fi

echo ""
echo "=== Test: YAML Quote Parsing ==="
echo ""

# Test 8.6: Hook correctly parses quoted start_branch (strips quotes)
echo "Test 8.6: Hook correctly strips quotes from start_branch"
setup_test_loop
# Create state with quoted branch name
cat > "$LOOP_DIR/state.md" << EOF
---
current_round: 0
max_iterations: 42
plan_file: "plans/test-plan.md"
plan_tracked: false
start_branch: "$DEFAULT_BRANCH"
---
EOF
set +e
RESULT=$(echo '{}' | "$PROJECT_ROOT/hooks/loop-plan-file-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
# Should pass (no output, exit 0) - quotes should be stripped and branch should match current
if [[ $EXIT_CODE -eq 0 ]] && [[ -z "$RESULT" ]]; then
    pass "Hook correctly strips quotes from start_branch"
else
    fail "Quote stripping from start_branch" "exit 0, no output" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 8.7: Hook detects branch mismatch with quoted value
echo "Test 8.7: Hook detects branch mismatch with quoted start_branch"
setup_test_loop
cat > "$LOOP_DIR/state.md" << 'EOF'
---
current_round: 0
max_iterations: 42
plan_file: "plans/test-plan.md"
plan_tracked: false
start_branch: "different-branch"
---
EOF
set +e
RESULT=$(echo '{}' | "$PROJECT_ROOT/hooks/loop-plan-file-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
# Should block due to branch mismatch (current is main, state says different-branch)
if [[ $EXIT_CODE -eq 0 ]] && echo "$RESULT" | grep -q "branch"; then
    pass "Hook detects branch mismatch with quoted start_branch"
else
    fail "Branch mismatch detection with quotes" "block with branch error" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 8.8: Stop hook correctly parses both quoted fields
echo "Test 8.8: Stop hook parses quoted plan_file and start_branch"
setup_test_loop
cat > "$LOOP_DIR/state.md" << EOF
---
current_round: 0
max_iterations: 42
plan_file: "plans/test-plan.md"
plan_tracked: false
start_branch: "$DEFAULT_BRANCH"
---
EOF
# Create summary to get past that check
cat > "$LOOP_DIR/round-0-summary.md" << 'SUMEOF'
# Summary
Work done.
SUMEOF
# Create goal tracker
cat > "$LOOP_DIR/goal-tracker.md" << 'GTEOF'
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
GTEOF
set +e
RESULT=$(echo '{}' | "$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh" 2>&1)
EXIT_CODE=$?
set -e
# Should NOT fail on YAML parsing - if it fails, should be for other reasons (codex missing, etc)
if ! echo "$RESULT" | grep -qi "yaml\|parse error\|invalid.*field"; then
    pass "Stop hook parses quoted plan_file and start_branch"
else
    fail "Stop hook YAML parsing" "no YAML parse errors" "output: $RESULT"
fi

# Test 8.9: Hook handles plan_file path with hyphens correctly
echo "Test 8.9: Hook handles plan_file with hyphens in path"
setup_test_loop
mkdir -p "$TEST_DIR/my-plans"
cat > "$TEST_DIR/my-plans/test-plan.md" << 'EOF'
# Test Plan
## Goal
Test the RLCR loop
## Requirements
- Requirement 1
EOF
cp "$TEST_DIR/my-plans/test-plan.md" "$LOOP_DIR/plan.md"
cat > "$LOOP_DIR/state.md" << EOF
---
current_round: 0
max_iterations: 42
plan_file: "my-plans/test-plan.md"
plan_tracked: false
start_branch: "$DEFAULT_BRANCH"
---
EOF
set +e
RESULT=$(echo '{}' | "$PROJECT_ROOT/hooks/loop-plan-file-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]] && [[ -z "$RESULT" ]]; then
    pass "Hook handles plan_file with hyphens in path"
else
    fail "Plan file path with hyphens" "exit 0, no output" "exit $EXIT_CODE, output: $RESULT"
fi

# Restore for remaining tests
setup_test_loop

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

# Test 12: Stop hook detects tracked file modifications (Fix #3 - Race condition)
echo "Test 12: Stop hook detects tracked plan file modifications"
cd "$TEST_DIR"
rm -rf tracked-stop-test 2>/dev/null || true
mkdir -p tracked-stop-test
cd tracked-stop-test
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "init" > init.txt
git add init.txt
git -c commit.gpgsign=false commit -q -m "Initial"
# Get the default branch name for this new repo
TEST12_BRANCH=$(git rev-parse --abbrev-ref HEAD)
# Create tracked plan file
cat > tracked-plan.md << 'EOF'
# Tracked Plan
## Goal
Test tracked file
## Requirements
- Requirement 1
EOF
git add tracked-plan.md
git -c commit.gpgsign=false commit -q -m "Add plan"
# Create loop directory
TRACKED_LOOP_DIR="$PWD/.humanize/rlcr/2024-01-01_12-00-00"
mkdir -p "$TRACKED_LOOP_DIR"
cp tracked-plan.md "$TRACKED_LOOP_DIR/plan.md"
cat > "$TRACKED_LOOP_DIR/state.md" << EOF
---
current_round: 0
max_iterations: 42
plan_file: tracked-plan.md
plan_tracked: true
start_branch: $TEST12_BRANCH
---
EOF
cat > "$TRACKED_LOOP_DIR/round-0-summary.md" << 'EOF'
# Summary
Work done.
EOF
cat > "$TRACKED_LOOP_DIR/goal-tracker.md" << 'EOF'
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
# Now modify the tracked plan file (simulate race condition)
echo "# Modified" >> tracked-plan.md
export CLAUDE_PROJECT_DIR="$PWD"
set +e
RESULT=$(echo '{}' | "$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh" 2>&1)
EXIT_CODE=$?
set -e
# Should detect modification via git status
if echo "$RESULT" | grep -q '"decision"' && echo "$RESULT" | grep -qi "plan.*modif\|uncommitted"; then
    pass "Stop hook detects tracked plan file modifications"
else
    fail "Stop hook tracked file detection" "block with modification error" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 13: Stop hook returns JSON block for outdated schema (Fix #5)
echo "Test 13: Stop hook returns JSON block for outdated schema"
cd "$TEST_DIR"
setup_test_loop
export CLAUDE_PROJECT_DIR="$TEST_DIR"
# Create state without plan_tracked (old schema)
cat > "$LOOP_DIR/state.md" << 'EOF'
---
current_round: 0
max_iterations: 42
plan_file: plans/test-plan.md
---
EOF
set +e
RESULT=$(echo '{}' | "$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh" 2>&1)
EXIT_CODE=$?
set -e
# Should return JSON with block decision, not silently exit
if echo "$RESULT" | grep -q '"decision".*"block"' && echo "$RESULT" | grep -qi "schema\|missing.*field\|plan_tracked"; then
    pass "Stop hook returns JSON block for outdated schema"
else
    fail "Stop hook schema blocking" "JSON block response" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 14: Stop hook blocks tracked file with committed changes (content differs from backup)
# This tests the security fix: even if git status is clean, content must match backup
echo "Test 14: Stop hook blocks tracked file with committed changes"
cd "$TEST_DIR"
rm -rf tracked-commit-test 2>/dev/null || true
mkdir -p tracked-commit-test
cd tracked-commit-test
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "init" > init.txt
git add init.txt
git -c commit.gpgsign=false commit -q -m "Initial"
# Get the default branch name for this new repo
TEST14_BRANCH=$(git rev-parse --abbrev-ref HEAD)
# Create tracked plan file
cat > tracked-plan.md << 'EOF'
# Tracked Plan
## Goal
Test tracked file
## Requirements
- Requirement 1
EOF
git add tracked-plan.md
git -c commit.gpgsign=false commit -q -m "Add plan"
# Create loop directory and backup
TRACKED_LOOP_DIR="$PWD/.humanize/rlcr/2024-01-01_12-00-00"
mkdir -p "$TRACKED_LOOP_DIR"
cp tracked-plan.md "$TRACKED_LOOP_DIR/plan.md"
cat > "$TRACKED_LOOP_DIR/state.md" << EOF
---
current_round: 0
max_iterations: 42
plan_file: tracked-plan.md
plan_tracked: true
start_branch: $TEST14_BRANCH
---
EOF
cat > "$TRACKED_LOOP_DIR/round-0-summary.md" << 'EOF'
# Summary
Work done.
EOF
cat > "$TRACKED_LOOP_DIR/goal-tracker.md" << 'EOF'
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
# Modify and COMMIT the plan file (git status will be clean)
echo "# Modified and committed" >> tracked-plan.md
git add tracked-plan.md
git -c commit.gpgsign=false commit -q -m "Modify plan"
# Verify git status is clean for the plan file
GIT_STATUS_CHECK=$(git status --porcelain tracked-plan.md)
if [[ -n "$GIT_STATUS_CHECK" ]]; then
    fail "Test 14 setup" "clean git status" "git status: $GIT_STATUS_CHECK"
else
    export CLAUDE_PROJECT_DIR="$PWD"
    set +e
    RESULT=$(echo '{}' | "$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh" 2>&1)
    EXIT_CODE=$?
    set -e
    # Should detect modification via content diff (not git status)
    if echo "$RESULT" | grep -q '"decision"' && echo "$RESULT" | grep -qi "plan.*modif"; then
        pass "Stop hook blocks tracked file with committed changes"
    else
        fail "Stop hook committed file detection" "block with modification error" "exit $EXIT_CODE, output: $RESULT"
    fi
fi

echo ""
echo "=== Test: Section-Specific Placeholder Detection ==="
echo ""

# Test 14.1: Stop hook only reports Ultimate Goal placeholder when only that is missing
echo "Test 14.1: Stop hook only reports Ultimate Goal placeholder"
cd "$TEST_DIR"
rm -rf placeholder-test-14-1 2>/dev/null || true
mkdir -p placeholder-test-14-1
cd placeholder-test-14-1
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "init" > init.txt
# Add .humanize to gitignore so it doesn't trigger uncommitted changes
echo ".humanize*" > .gitignore
git add init.txt .gitignore
git -c commit.gpgsign=false commit -q -m "Initial"
TEST_BRANCH=$(git rev-parse --abbrev-ref HEAD)
# Create gitignored plan
mkdir -p plans
echo "plans/" >> .gitignore
cat > plans/test-plan.md << 'EOF'
# Test Plan
## Goal
Test
EOF
git add .gitignore
git -c commit.gpgsign=false commit -q -m "Add gitignore"
# Create loop directory
LOOP_DIR_14_1="$PWD/.humanize/rlcr/2024-01-01_12-00-00"
mkdir -p "$LOOP_DIR_14_1"
cp plans/test-plan.md "$LOOP_DIR_14_1/plan.md"
cat > "$LOOP_DIR_14_1/state.md" << EOF
---
current_round: 0
max_iterations: 42
plan_file: "plans/test-plan.md"
plan_tracked: false
start_branch: $TEST_BRANCH
---
EOF
cat > "$LOOP_DIR_14_1/round-0-summary.md" << 'EOF'
# Summary
Work done.
EOF
# Goal tracker with ONLY Ultimate Goal placeholder (AC and Tasks are filled)
cat > "$LOOP_DIR_14_1/goal-tracker.md" << 'EOF'
# Goal Tracker
## IMMUTABLE SECTION
### Ultimate Goal
[To be extracted from plan by Claude in Round 0]
### Acceptance Criteria
- AC1: Real acceptance criterion
## MUTABLE SECTION
### Plan Version: 1 (Updated: Round 0)
#### Active Tasks
| Task | Target AC | Status | Notes |
|------|-----------|--------|-------|
| Task 1 | AC1 | in_progress | Real task |
EOF
export CLAUDE_PROJECT_DIR="$PWD"
set +e
RESULT=$(echo '{}' | "$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh" 2>&1)
EXIT_CODE=$?
set -e
# Should report Ultimate Goal missing-item line but NOT AC or Active Tasks missing-item lines
# The exact format is: **<Section>**: Still contains placeholder text
if echo "$RESULT" | grep -qF '**Ultimate Goal**: Still contains placeholder text' && \
   ! echo "$RESULT" | grep -qF '**Acceptance Criteria**: Still contains placeholder text' && \
   ! echo "$RESULT" | grep -qF '**Active Tasks**: Still contains placeholder text'; then
    pass "Stop hook only reports Ultimate Goal placeholder"
else
    fail "Section-specific Ultimate Goal" "only **Ultimate Goal**: Still contains placeholder text" "output: $RESULT"
fi

# Test 14.2: Stop hook only reports Acceptance Criteria placeholder when only that is missing
echo "Test 14.2: Stop hook only reports Acceptance Criteria placeholder"
cd "$TEST_DIR"
rm -rf placeholder-test-14-2 2>/dev/null || true
mkdir -p placeholder-test-14-2
cd placeholder-test-14-2
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "init" > init.txt
echo ".humanize*" > .gitignore
git add init.txt .gitignore
git -c commit.gpgsign=false commit -q -m "Initial"
TEST_BRANCH=$(git rev-parse --abbrev-ref HEAD)
mkdir -p plans
echo "plans/" >> .gitignore
cat > plans/test-plan.md << 'EOF'
# Test Plan
## Goal
Test
EOF
git add .gitignore
git -c commit.gpgsign=false commit -q -m "Add gitignore"
LOOP_DIR_14_2="$PWD/.humanize/rlcr/2024-01-01_12-00-00"
mkdir -p "$LOOP_DIR_14_2"
cp plans/test-plan.md "$LOOP_DIR_14_2/plan.md"
cat > "$LOOP_DIR_14_2/state.md" << EOF
---
current_round: 0
max_iterations: 42
plan_file: "plans/test-plan.md"
plan_tracked: false
start_branch: $TEST_BRANCH
---
EOF
cat > "$LOOP_DIR_14_2/round-0-summary.md" << 'EOF'
# Summary
Work done.
EOF
# Goal tracker with ONLY AC placeholder (Goal and Tasks are filled)
cat > "$LOOP_DIR_14_2/goal-tracker.md" << 'EOF'
# Goal Tracker
## IMMUTABLE SECTION
### Ultimate Goal
Implement the feature completely
### Acceptance Criteria
[To be defined by Claude in Round 0 based on the plan]
## MUTABLE SECTION
### Plan Version: 1 (Updated: Round 0)
#### Active Tasks
| Task | Target AC | Status | Notes |
|------|-----------|--------|-------|
| Task 1 | AC1 | in_progress | Real task |
EOF
export CLAUDE_PROJECT_DIR="$PWD"
set +e
RESULT=$(echo '{}' | "$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh" 2>&1)
EXIT_CODE=$?
set -e
# Should report Acceptance Criteria missing-item line but NOT Goal or Active Tasks missing-item lines
# The exact format is: **<Section>**: Still contains placeholder text
if echo "$RESULT" | grep -qF '**Acceptance Criteria**: Still contains placeholder text' && \
   ! echo "$RESULT" | grep -qF '**Ultimate Goal**: Still contains placeholder text' && \
   ! echo "$RESULT" | grep -qF '**Active Tasks**: Still contains placeholder text'; then
    pass "Stop hook only reports Acceptance Criteria placeholder"
else
    fail "Section-specific Acceptance Criteria" "only **Acceptance Criteria**: Still contains placeholder text" "output: $RESULT"
fi

# Test 14.3: Stop hook only reports Active Tasks placeholder when only that is missing
echo "Test 14.3: Stop hook only reports Active Tasks placeholder"
cd "$TEST_DIR"
rm -rf placeholder-test-14-3 2>/dev/null || true
mkdir -p placeholder-test-14-3
cd placeholder-test-14-3
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "init" > init.txt
echo ".humanize*" > .gitignore
git add init.txt .gitignore
git -c commit.gpgsign=false commit -q -m "Initial"
TEST_BRANCH=$(git rev-parse --abbrev-ref HEAD)
mkdir -p plans
echo "plans/" >> .gitignore
cat > plans/test-plan.md << 'EOF'
# Test Plan
## Goal
Test
EOF
git add .gitignore
git -c commit.gpgsign=false commit -q -m "Add gitignore"
LOOP_DIR_14_3="$PWD/.humanize/rlcr/2024-01-01_12-00-00"
mkdir -p "$LOOP_DIR_14_3"
cp plans/test-plan.md "$LOOP_DIR_14_3/plan.md"
cat > "$LOOP_DIR_14_3/state.md" << EOF
---
current_round: 0
max_iterations: 42
plan_file: "plans/test-plan.md"
plan_tracked: false
start_branch: $TEST_BRANCH
---
EOF
cat > "$LOOP_DIR_14_3/round-0-summary.md" << 'EOF'
# Summary
Work done.
EOF
# Goal tracker with ONLY Active Tasks placeholder (Goal and AC are filled)
cat > "$LOOP_DIR_14_3/goal-tracker.md" << 'EOF'
# Goal Tracker
## IMMUTABLE SECTION
### Ultimate Goal
Implement the feature completely
### Acceptance Criteria
- AC1: Real acceptance criterion
## MUTABLE SECTION
### Plan Version: 1 (Updated: Round 0)
#### Active Tasks
[To be populated by Claude based on plan]
EOF
export CLAUDE_PROJECT_DIR="$PWD"
set +e
RESULT=$(echo '{}' | "$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh" 2>&1)
EXIT_CODE=$?
set -e
# Should report Active Tasks missing-item line but NOT Goal or AC missing-item lines
# The exact format is: **<Section>**: Still contains placeholder text
if echo "$RESULT" | grep -qF '**Active Tasks**: Still contains placeholder text' && \
   ! echo "$RESULT" | grep -qF '**Ultimate Goal**: Still contains placeholder text' && \
   ! echo "$RESULT" | grep -qF '**Acceptance Criteria**: Still contains placeholder text'; then
    pass "Stop hook only reports Active Tasks placeholder"
else
    fail "Section-specific Active Tasks" "only **Active Tasks**: Still contains placeholder text" "output: $RESULT"
fi

# Test 14.4: Stop hook reports all three when all placeholders present
echo "Test 14.4: Stop hook reports all three placeholders when all missing"
cd "$TEST_DIR"
rm -rf placeholder-test-14-4 2>/dev/null || true
mkdir -p placeholder-test-14-4
cd placeholder-test-14-4
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "init" > init.txt
echo ".humanize*" > .gitignore
git add init.txt .gitignore
git -c commit.gpgsign=false commit -q -m "Initial"
TEST_BRANCH=$(git rev-parse --abbrev-ref HEAD)
mkdir -p plans
echo "plans/" >> .gitignore
cat > plans/test-plan.md << 'EOF'
# Test Plan
## Goal
Test
EOF
git add .gitignore
git -c commit.gpgsign=false commit -q -m "Add gitignore"
LOOP_DIR_14_4="$PWD/.humanize/rlcr/2024-01-01_12-00-00"
mkdir -p "$LOOP_DIR_14_4"
cp plans/test-plan.md "$LOOP_DIR_14_4/plan.md"
cat > "$LOOP_DIR_14_4/state.md" << EOF
---
current_round: 0
max_iterations: 42
plan_file: "plans/test-plan.md"
plan_tracked: false
start_branch: $TEST_BRANCH
---
EOF
cat > "$LOOP_DIR_14_4/round-0-summary.md" << 'EOF'
# Summary
Work done.
EOF
# Goal tracker with ALL placeholders
cat > "$LOOP_DIR_14_4/goal-tracker.md" << 'EOF'
# Goal Tracker
## IMMUTABLE SECTION
### Ultimate Goal
[To be extracted from plan by Claude in Round 0]
### Acceptance Criteria
[To be defined by Claude in Round 0 based on the plan]
## MUTABLE SECTION
### Plan Version: 1 (Updated: Round 0)
#### Active Tasks
[To be populated by Claude based on plan]
EOF
export CLAUDE_PROJECT_DIR="$PWD"
set +e
RESULT=$(echo '{}' | "$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh" 2>&1)
EXIT_CODE=$?
set -e
# Should report all three missing-item lines
# The exact format is: **<Section>**: Still contains placeholder text
if echo "$RESULT" | grep -qF '**Ultimate Goal**: Still contains placeholder text' && \
   echo "$RESULT" | grep -qF '**Acceptance Criteria**: Still contains placeholder text' && \
   echo "$RESULT" | grep -qF '**Active Tasks**: Still contains placeholder text'; then
    pass "Stop hook reports all three placeholders when all missing"
else
    fail "All placeholders reported" "all three **<Section>**: Still contains placeholder text lines" "output: $RESULT"
fi

echo ""
echo "=== Test: Legacy Path Handling (NEGATIVE TESTS) ==="
echo ""

# Test 15: Bash validator ALLOWS writes to legacy .humanize-loop.local (it's not a loop dir anymore)
echo "Test 15: Bash validator allows writes to legacy .humanize-loop.local"
HOOK_INPUT='{"tool_name": "Bash", "tool_input": {"command": "echo test > .humanize-loop.local/2024-01-01/plan.md"}}'
set +e
RESULT=$(echo "$HOOK_INPUT" | "$PROJECT_ROOT/hooks/loop-bash-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
# Should exit 0 (allowed) because legacy path is no longer treated as a loop directory
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Bash validator allows writes to legacy .humanize-loop.local"
else
    fail "Bash validator legacy path" "exit 0 (allowed)" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 16: Write validator ALLOWS writes to legacy .humanize-loop.local plan.md
echo "Test 16: Write validator allows writes to legacy .humanize-loop.local plan.md"
HOOK_INPUT='{"tool_name": "Write", "tool_input": {"file_path": "'$TEST_DIR'/.humanize-loop.local/2024-01-01/plan.md"}}'
set +e
RESULT=$(echo "$HOOK_INPUT" | "$PROJECT_ROOT/hooks/loop-write-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Write validator allows writes to legacy .humanize-loop.local plan.md"
else
    fail "Write validator legacy path" "exit 0 (allowed)" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 17: Edit validator ALLOWS edits to legacy .humanize-loop.local plan.md
echo "Test 17: Edit validator allows edits to legacy .humanize-loop.local plan.md"
HOOK_INPUT='{"tool_name": "Edit", "tool_input": {"file_path": "'$TEST_DIR'/.humanize-loop.local/2024-01-01/plan.md"}}'
set +e
RESULT=$(echo "$HOOK_INPUT" | "$PROJECT_ROOT/hooks/loop-edit-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Edit validator allows edits to legacy .humanize-loop.local plan.md"
else
    fail "Edit validator legacy path" "exit 0 (allowed)" "exit $EXIT_CODE, output: $RESULT"
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
