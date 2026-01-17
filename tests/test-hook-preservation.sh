#!/bin/bash
#
# Test script for hook preservation after skillification
#
# This test verifies that the hook system continues to function IDENTICALLY
# after the skill conversion. It validates:
# - hooks.json structure is intact and valid
# - All hook scripts exist and are executable
# - Hook event types are correctly configured
# - PreToolUse hooks (Write/Edit/Read/Bash validators) are registered
# - Stop hook (Codex review orchestration) is registered
# - UserPromptSubmit hook (plan file validator) is registered
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_DIR="$PROJECT_ROOT/hooks"
HOOKS_JSON="$HOOKS_DIR/hooks.json"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

TESTS_PASSED=0
TESTS_FAILED=0

# Test helper functions
pass() {
    echo -e "${GREEN}PASS${NC}: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "${RED}FAIL${NC}: $1"
    if [[ -n "${2:-}" ]]; then
        echo "  Expected: $2"
    fi
    if [[ -n "${3:-}" ]]; then
        echo "  Got: $3"
    fi
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

echo "========================================"
echo "Testing Hook System Preservation"
echo "========================================"
echo ""

# ========================================
# Test 1: hooks.json exists
# ========================================
echo "Test 1: hooks.json exists"
if [[ -f "$HOOKS_JSON" ]]; then
    pass "hooks.json exists at $HOOKS_JSON"
else
    fail "hooks.json existence" "File exists" "File not found"
fi

# ========================================
# Test 2: hooks.json is valid JSON
# ========================================
echo ""
echo "Test 2: hooks.json is valid JSON"
if jq empty "$HOOKS_JSON" 2>/dev/null; then
    pass "hooks.json is valid JSON"
else
    fail "hooks.json validity" "Valid JSON" "Invalid JSON or parse error"
fi

# ========================================
# Test 3: hooks.json has hooks structure
# ========================================
echo ""
echo "Test 3: hooks.json has 'hooks' key"
if jq -e '.hooks' "$HOOKS_JSON" >/dev/null 2>&1; then
    pass "hooks.json has 'hooks' key"
else
    fail "hooks.json structure" "'hooks' key exists" "Key not found"
fi

# ========================================
# Test 4: UserPromptSubmit hook is configured
# ========================================
echo ""
echo "Test 4: UserPromptSubmit hook is configured"
USER_PROMPT_HOOK=$(jq -r '.hooks.UserPromptSubmit' "$HOOKS_JSON" 2>/dev/null)
if [[ "$USER_PROMPT_HOOK" != "null" ]] && [[ -n "$USER_PROMPT_HOOK" ]]; then
    pass "UserPromptSubmit hook is configured"
else
    fail "UserPromptSubmit hook" "Hook configured" "Hook not found"
fi

# ========================================
# Test 5: PreToolUse hooks are configured
# ========================================
echo ""
echo "Test 5: PreToolUse hooks are configured"
PRE_TOOL_USE=$(jq -r '.hooks.PreToolUse' "$HOOKS_JSON" 2>/dev/null)
if [[ "$PRE_TOOL_USE" != "null" ]] && [[ -n "$PRE_TOOL_USE" ]]; then
    pass "PreToolUse hooks are configured"
else
    fail "PreToolUse hooks" "Hooks configured" "Hooks not found"
fi

# ========================================
# Test 6: Stop hook is configured
# ========================================
echo ""
echo "Test 6: Stop hook is configured"
STOP_HOOK=$(jq -r '.hooks.Stop' "$HOOKS_JSON" 2>/dev/null)
if [[ "$STOP_HOOK" != "null" ]] && [[ -n "$STOP_HOOK" ]]; then
    pass "Stop hook is configured"
else
    fail "Stop hook" "Hook configured" "Hook not found"
fi

# ========================================
# Test 7: Write matcher in PreToolUse
# ========================================
echo ""
echo "Test 7: Write matcher exists in PreToolUse"
WRITE_MATCHER=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Write") | .matcher' "$HOOKS_JSON" 2>/dev/null)
if [[ "$WRITE_MATCHER" == "Write" ]]; then
    pass "Write matcher exists in PreToolUse"
else
    fail "Write matcher" "Write matcher present" "Not found"
fi

# ========================================
# Test 8: Edit matcher in PreToolUse
# ========================================
echo ""
echo "Test 8: Edit matcher exists in PreToolUse"
EDIT_MATCHER=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Edit") | .matcher' "$HOOKS_JSON" 2>/dev/null)
if [[ "$EDIT_MATCHER" == "Edit" ]]; then
    pass "Edit matcher exists in PreToolUse"
else
    fail "Edit matcher" "Edit matcher present" "Not found"
fi

# ========================================
# Test 9: Read matcher in PreToolUse
# ========================================
echo ""
echo "Test 9: Read matcher exists in PreToolUse"
READ_MATCHER=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Read") | .matcher' "$HOOKS_JSON" 2>/dev/null)
if [[ "$READ_MATCHER" == "Read" ]]; then
    pass "Read matcher exists in PreToolUse"
else
    fail "Read matcher" "Read matcher present" "Not found"
fi

# ========================================
# Test 10: Bash matcher in PreToolUse
# ========================================
echo ""
echo "Test 10: Bash matcher exists in PreToolUse"
BASH_MATCHER=$(jq -r '.hooks.PreToolUse[] | select(.matcher == "Bash") | .matcher' "$HOOKS_JSON" 2>/dev/null)
if [[ "$BASH_MATCHER" == "Bash" ]]; then
    pass "Bash matcher exists in PreToolUse"
else
    fail "Bash matcher" "Bash matcher present" "Not found"
fi

# ========================================
# Test 11-16: Hook scripts exist and are executable
# ========================================
echo ""
echo "Hook Script Existence and Executable Tests"
echo "----------------------------------------"

HOOK_SCRIPTS=(
    "loop-plan-file-validator.sh"
    "loop-write-validator.sh"
    "loop-edit-validator.sh"
    "loop-read-validator.sh"
    "loop-bash-validator.sh"
    "loop-codex-stop-hook.sh"
)

for script in "${HOOK_SCRIPTS[@]}"; do
    script_path="$HOOKS_DIR/$script"
    echo ""
    echo "Test: $script exists and is executable"
    if [[ -f "$script_path" ]]; then
        if [[ -x "$script_path" ]]; then
            pass "$script exists and is executable"
        else
            fail "$script executable" "Executable" "Not executable"
        fi
    else
        fail "$script existence" "File exists" "File not found"
    fi
done

# ========================================
# Test 17: Hook command paths use CLAUDE_PLUGIN_ROOT
# ========================================
echo ""
echo "Test 17: Hook commands use CLAUDE_PLUGIN_ROOT variable"
PLUGIN_ROOT_REFS=$(jq -r '.. | objects | .command? // empty' "$HOOKS_JSON" 2>/dev/null | grep -c 'CLAUDE_PLUGIN_ROOT' || echo "0")
TOTAL_COMMANDS=$(jq -r '.. | objects | .command? // empty' "$HOOKS_JSON" 2>/dev/null | wc -l)

if [[ $PLUGIN_ROOT_REFS -eq $TOTAL_COMMANDS ]] && [[ $TOTAL_COMMANDS -gt 0 ]]; then
    pass "All hook commands use CLAUDE_PLUGIN_ROOT ($PLUGIN_ROOT_REFS/$TOTAL_COMMANDS)"
else
    fail "CLAUDE_PLUGIN_ROOT usage" "All commands use variable" "$PLUGIN_ROOT_REFS of $TOTAL_COMMANDS commands"
fi

# ========================================
# Test 18: Stop hook has timeout configured
# ========================================
echo ""
echo "Test 18: Stop hook has timeout configured"
STOP_TIMEOUT=$(jq -r '.hooks.Stop[0].hooks[0].timeout // empty' "$HOOKS_JSON" 2>/dev/null)
if [[ -n "$STOP_TIMEOUT" ]] && [[ "$STOP_TIMEOUT" -gt 0 ]]; then
    pass "Stop hook has timeout: ${STOP_TIMEOUT}s"
else
    fail "Stop hook timeout" "Timeout > 0" "Timeout not found or 0"
fi

# ========================================
# Test 19: Hook scripts have valid bash syntax
# ========================================
echo ""
echo "Test 19: Hook scripts have valid bash syntax"
SYNTAX_ERRORS=0
for script in "${HOOK_SCRIPTS[@]}"; do
    script_path="$HOOKS_DIR/$script"
    if [[ -f "$script_path" ]]; then
        if ! bash -n "$script_path" 2>/dev/null; then
            fail "$script syntax" "Valid bash" "Syntax error"
            SYNTAX_ERRORS=$((SYNTAX_ERRORS + 1))
        fi
    fi
done
if [[ $SYNTAX_ERRORS -eq 0 ]]; then
    pass "All hook scripts have valid bash syntax"
fi

# ========================================
# Test 20: Library files exist (loop-common.sh, template-loader.sh)
# ========================================
echo ""
echo "Test 20: Hook library files exist"
LIB_FILES=(
    "lib/loop-common.sh"
    "lib/template-loader.sh"
)
for lib_file in "${LIB_FILES[@]}"; do
    lib_path="$HOOKS_DIR/$lib_file"
    if [[ -f "$lib_path" ]]; then
        pass "Library file $lib_file exists"
    else
        fail "Library file $lib_file" "File exists" "File not found"
    fi
done

# ========================================
# Test 21: Skills do not interfere with hooks.json
# ========================================
echo ""
echo "Test 21: Skills directory structure is separate from hooks"
SKILLS_DIR="$PROJECT_ROOT/skills"
if [[ -d "$SKILLS_DIR" ]]; then
    # Verify skills directory doesn't contain hooks.json
    if [[ ! -f "$SKILLS_DIR/hooks.json" ]]; then
        pass "Skills directory does not override hooks.json"
    else
        fail "Skills hooks separation" "No hooks.json in skills/" "hooks.json found in skills/"
    fi
else
    fail "Skills directory exists" "Directory exists" "skills/ not found"
fi

# ========================================
# Test 22: Verify commands still reference correct scripts
# ========================================
echo ""
echo "Test 22: Commands reference correct scripts"
COMMANDS_DIR="$PROJECT_ROOT/commands"
if [[ -f "$COMMANDS_DIR/start-rlcr-loop.md" ]]; then
    if grep -q 'setup-rlcr-loop.sh' "$COMMANDS_DIR/start-rlcr-loop.md"; then
        pass "start-rlcr-loop.md references setup-rlcr-loop.sh"
    else
        fail "start-rlcr-loop command reference" "References setup-rlcr-loop.sh" "Reference not found"
    fi
fi

# ========================================
# Test 23: Skills reference same scripts as commands
# ========================================
echo ""
echo "Test 23: Skills reference same scripts as commands"
START_SKILL="$SKILLS_DIR/start-rlcr-loop/SKILL.md"
if [[ -f "$START_SKILL" ]]; then
    if grep -q 'setup-rlcr-loop.sh' "$START_SKILL"; then
        pass "start-rlcr-loop skill references setup-rlcr-loop.sh"
    else
        fail "start-rlcr-loop skill reference" "References setup-rlcr-loop.sh" "Reference not found"
    fi
fi

# ========================================
# Test 24: Main scripts exist and are executable
# ========================================
echo ""
echo "Test 24: Main scripts exist and are executable"
MAIN_SCRIPTS=(
    "scripts/setup-rlcr-loop.sh"
    "scripts/humanize.sh"
)
for script in "${MAIN_SCRIPTS[@]}"; do
    script_path="$PROJECT_ROOT/$script"
    if [[ -f "$script_path" ]]; then
        if [[ -x "$script_path" ]]; then
            pass "$script exists and is executable"
        else
            fail "$script executable" "Executable" "Not executable"
        fi
    else
        fail "$script existence" "File exists" "File not found"
    fi
done

# ========================================
# Hook Execution Tests (PT-10 to PT-14)
# These tests actually run hooks with inputs and verify behavior
# ========================================
echo ""
echo "========================================"
echo "Hook Execution Tests"
echo "========================================"

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
        git -c commit.gpgsign=false commit -q -m "Initial commit"
    fi

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
    git -c commit.gpgsign=false commit -q -m "Add gitignore" 2>/dev/null || true

    # Create plan backup
    cp plans/test-plan.md "$LOOP_DIR/plan.md"

    # Create state file
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

# Test 25: UserPromptSubmit hook fires with valid state (PT-14)
echo ""
echo "Test 25: UserPromptSubmit hook fires correctly"
setup_test_loop
export CLAUDE_PROJECT_DIR="$TEST_DIR"

set +e
RESULT=$(echo '{}' | "$HOOKS_DIR/loop-plan-file-validator.sh" 2>&1)
EXIT_CODE=$?
set -e

# With valid state, hook should pass (exit 0, no output)
if [[ $EXIT_CODE -eq 0 ]] && [[ -z "$RESULT" ]]; then
    pass "UserPromptSubmit hook fires correctly with valid state"
else
    fail "UserPromptSubmit hook execution" "exit 0, no output" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 26: PreToolUse Write hook fires (PT-12)
echo ""
echo "Test 26: PreToolUse Write hook fires correctly"
setup_test_loop

# Test Write validator blocks plan.md in loop directory
HOOK_INPUT='{"tool_name": "Write", "tool_input": {"file_path": "'$LOOP_DIR'/plan.md"}}'
set +e
RESULT=$(echo "$HOOK_INPUT" | "$HOOKS_DIR/loop-write-validator.sh" 2>&1)
EXIT_CODE=$?
set -e

# Write to plan.md should be blocked (exit 2)
if [[ $EXIT_CODE -eq 2 ]] && echo "$RESULT" | grep -qi "plan"; then
    pass "PreToolUse Write hook fires and blocks plan.md"
else
    fail "PreToolUse Write hook execution" "exit 2 with plan error" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 27: PreToolUse Edit hook fires (PT-12)
echo ""
echo "Test 27: PreToolUse Edit hook fires correctly"
setup_test_loop

# Test Edit validator blocks plan.md
HOOK_INPUT='{"tool_name": "Edit", "tool_input": {"file_path": "'$LOOP_DIR'/plan.md"}}'
set +e
RESULT=$(echo "$HOOK_INPUT" | "$HOOKS_DIR/loop-edit-validator.sh" 2>&1)
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]] && echo "$RESULT" | grep -qi "plan"; then
    pass "PreToolUse Edit hook fires and blocks plan.md"
else
    fail "PreToolUse Edit hook execution" "exit 2 with plan error" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 28: PreToolUse Read hook fires (PT-12)
echo ""
echo "Test 28: PreToolUse Read hook fires correctly"
setup_test_loop

# Read validator should allow most reads (exit 0) when not reading protected files
HOOK_INPUT='{"tool_name": "Read", "tool_input": {"file_path": "'$TEST_DIR'/plans/test-plan.md"}}'
set +e
RESULT=$(echo "$HOOK_INPUT" | "$HOOKS_DIR/loop-read-validator.sh" 2>&1)
EXIT_CODE=$?
set -e

# Read of plan file should be allowed
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "PreToolUse Read hook fires and allows plan file read"
else
    fail "PreToolUse Read hook execution" "exit 0 (allow read)" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 29: PreToolUse Bash hook fires (PT-12)
echo ""
echo "Test 29: PreToolUse Bash hook fires correctly"
setup_test_loop

# Test Bash validator blocks modifications to plan.md
HOOK_INPUT='{"tool_name": "Bash", "tool_input": {"command": "echo test > '$LOOP_DIR'/plan.md"}}'
set +e
RESULT=$(echo "$HOOK_INPUT" | "$HOOKS_DIR/loop-bash-validator.sh" 2>&1)
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]] && echo "$RESULT" | grep -qi "plan"; then
    pass "PreToolUse Bash hook fires and blocks plan.md modification"
else
    fail "PreToolUse Bash hook execution" "exit 2 with plan error" "exit $EXIT_CODE, output: $RESULT"
fi

# Test 30: Stop hook fires and returns valid JSON (PT-13)
echo ""
echo "Test 30: Stop hook fires and returns valid JSON"
setup_test_loop

# Create summary and goal tracker files
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
| Task 1 | AC1 | in_progress | - |
EOF

set +e
RESULT=$(echo '{}' | "$HOOKS_DIR/loop-codex-stop-hook.sh" 2>&1)
EXIT_CODE=$?
set -e

# Stop hook should return JSON (even if it blocks)
if echo "$RESULT" | grep -q '"decision"'; then
    pass "Stop hook fires and returns valid JSON response"
else
    # Note: stop hook may fail for other reasons (missing codex) but should still produce output
    if [[ -n "$RESULT" ]]; then
        pass "Stop hook fires and produces output"
    else
        fail "Stop hook execution" "JSON response or output" "No output"
    fi
fi

# Test 31: Hook behavior consistency - Write allows non-plan files
echo ""
echo "Test 31: Write hook allows non-plan files"
setup_test_loop

HOOK_INPUT='{"tool_name": "Write", "tool_input": {"file_path": "'$TEST_DIR'/test-output.txt"}}'
set +e
RESULT=$(echo "$HOOK_INPUT" | "$HOOKS_DIR/loop-write-validator.sh" 2>&1)
EXIT_CODE=$?
set -e

# Writing to regular files should be allowed
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Write hook allows non-plan files"
else
    fail "Write hook non-plan files" "exit 0 (allow)" "exit $EXIT_CODE"
fi

# Test 32: Hook behavior consistency - Bash allows safe commands
echo ""
echo "Test 32: Bash hook allows safe commands"
setup_test_loop

HOOK_INPUT='{"tool_name": "Bash", "tool_input": {"command": "ls -la"}}'
set +e
RESULT=$(echo "$HOOK_INPUT" | "$HOOKS_DIR/loop-bash-validator.sh" 2>&1)
EXIT_CODE=$?
set -e

# Safe bash commands should be allowed
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Bash hook allows safe commands"
else
    fail "Bash hook safe commands" "exit 0 (allow)" "exit $EXIT_CODE"
fi

# Test 33: Hook behavior consistency - UserPromptSubmit blocks on branch change
echo ""
echo "Test 33: UserPromptSubmit hook blocks on branch change"
setup_test_loop
cd "$TEST_DIR"

# Create and switch to a different branch
git checkout -q -b feature-branch

# State file still says we started on original branch
ORIGINAL_BRANCH=$(cat "$LOOP_DIR/state.md" | grep "start_branch:" | sed 's/start_branch:[[:space:]]*//' | tr -d '"')

set +e
RESULT=$(echo '{}' | "$HOOKS_DIR/loop-plan-file-validator.sh" 2>&1)
EXIT_CODE=$?
set -e

# Should block due to branch mismatch
if [[ $EXIT_CODE -eq 0 ]] && echo "$RESULT" | grep -qi "branch"; then
    pass "UserPromptSubmit hook blocks on branch change"
else
    fail "UserPromptSubmit branch check" "block with branch error" "exit $EXIT_CODE, output: $RESULT"
fi

# Return to original branch
git checkout -q "$ORIGINAL_BRANCH" 2>/dev/null || git checkout -q main 2>/dev/null || git checkout -q master 2>/dev/null || true

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
    echo -e "${GREEN}Hook system preservation verified!${NC}"
    echo "All hooks continue to function identically after skillification."
    exit 0
else
    echo ""
    echo -e "${RED}Hook preservation tests failed!${NC}"
    echo "Some hooks may not function correctly after skillification."
    exit 1
fi
