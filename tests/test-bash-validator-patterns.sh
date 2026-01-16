#!/bin/bash
#
# Test script for command_modifies_file function in loop-common.sh
#
# Tests the regex patterns used to detect file modification commands
# to ensure proper blocking of file writes via Bash.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_ROOT/hooks/lib/loop-common.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
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
    echo "  Command: $2"
    echo "  Expected: $3"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# Assert that a command SHOULD be detected as modifying the target file
assert_modifies() {
    local command="$1"
    local pattern="${2:-goal-tracker\\.md}"
    local command_lower
    command_lower=$(to_lower "$command")

    if command_modifies_file "$command_lower" "$pattern"; then
        pass "Correctly detected modification: $command"
    else
        fail "Should detect modification" "$command" "should match pattern"
    fi
}

# Assert that a command should NOT be detected as modifying the target file
assert_not_modifies() {
    local command="$1"
    local pattern="${2:-goal-tracker\\.md}"
    local command_lower
    command_lower=$(to_lower "$command")

    if command_modifies_file "$command_lower" "$pattern"; then
        fail "Should NOT detect modification" "$command" "should not match pattern"
    else
        pass "Correctly ignored: $command"
    fi
}

echo "========================================"
echo "Testing command_modifies_file patterns"
echo "========================================"
echo ""

# ========================================
# Test Group 1: Redirection operators (> >>)
# ========================================
echo "Test Group 1: Redirection operators"
echo ""

assert_modifies "echo x > goal-tracker.md"
assert_modifies "echo x >> goal-tracker.md"
assert_modifies "cat foo >> goal-tracker.md"
assert_modifies "printf 'text' > goal-tracker.md"
assert_modifies "echo 'data' > /path/to/goal-tracker.md"
assert_modifies "ECHO X > GOAL-TRACKER.MD"

# ========================================
# Test Group 2: tee command
# ========================================
echo ""
echo "Test Group 2: tee command"
echo ""

assert_modifies "tee goal-tracker.md"
assert_modifies "tee -a goal-tracker.md"
assert_modifies "echo x | tee goal-tracker.md"
assert_modifies "echo x | tee -a goal-tracker.md"
assert_modifies "cat file | tee /path/to/goal-tracker.md"

# ========================================
# Test Group 3: In-place editors (sed, awk, perl)
# ========================================
echo ""
echo "Test Group 3: In-place editors"
echo ""

assert_modifies "sed -i 's/x/y/' goal-tracker.md"
assert_modifies "sed -i.bak 's/x/y/' goal-tracker.md"
assert_modifies "sed -i '' 's/x/y/' goal-tracker.md"
assert_modifies "awk -i inplace '{print}' goal-tracker.md"
assert_modifies "perl -i -pe 's/x/y/' goal-tracker.md"
assert_modifies "perl -pie 's/x/y/' goal-tracker.md"

# ========================================
# Test Group 4: File operations (mv, cp, rm)
# ========================================
echo ""
echo "Test Group 4: File operations"
echo ""

assert_modifies "mv temp.md goal-tracker.md"
assert_modifies "cp backup.md goal-tracker.md"
assert_modifies "rm goal-tracker.md"
assert_modifies "rm -f goal-tracker.md"
assert_modifies "rm -rf goal-tracker.md"
assert_modifies "mv /tmp/new.md /path/to/goal-tracker.md"

# ========================================
# Test Group 5: Other modifiers (dd, truncate, exec)
# ========================================
echo ""
echo "Test Group 5: Other modifiers"
echo ""

assert_modifies "dd if=/dev/zero of=goal-tracker.md"
assert_modifies "truncate -s 0 goal-tracker.md"
assert_modifies "exec 3> goal-tracker.md"
assert_modifies "printf '%s' data > goal-tracker.md"

# ========================================
# Test Group 6: Commands that should NOT be caught
# ========================================
echo ""
echo "Test Group 6: Commands that should NOT be caught (false positives)"
echo ""

assert_not_modifies "cat goal-tracker.md"
assert_not_modifies "grep goal goal-tracker.md"
assert_not_modifies "head -10 goal-tracker.md"
assert_not_modifies "tail -10 goal-tracker.md"
assert_not_modifies "wc -l goal-tracker.md"
assert_not_modifies "less goal-tracker.md"
assert_not_modifies "echo goal-tracker.md"
assert_not_modifies "ls goal-tracker.md"
assert_not_modifies "file goal-tracker.md"
assert_not_modifies "stat goal-tracker.md"
assert_not_modifies "diff goal-tracker.md other.md"

# ========================================
# Test Group 7: Edge cases
# ========================================
echo ""
echo "Test Group 7: Edge cases"
echo ""

# Filename in different positions
assert_modifies "> goal-tracker.md"
assert_modifies "echo test >goal-tracker.md"

# Multiple source files to single destination
# Note: "cp file1.md file2.md goal-tracker.md" (multiple sources) is NOT detected
# because the pattern expects "cp src dest" format. This is a known limitation.
# The more common "cp src goal-tracker.md" case IS detected.

# With variables (should still match the literal pattern)
assert_not_modifies 'echo x > $FILE'
assert_not_modifies "cat file.md | grep pattern"

# ========================================
# Test Group 8: State file patterns
# ========================================
echo ""
echo "Test Group 8: State file patterns"
echo ""

assert_modifies "echo x > state.md" "state\\.md"
assert_modifies "sed -i 's/round: 0/round: 99/' state.md" "state\\.md"
assert_not_modifies "cat state.md" "state\\.md"

# ========================================
# Test Group 9: Summary file patterns
# ========================================
echo ""
echo "Test Group 9: Summary file patterns"
echo ""

assert_modifies "echo x > round-5-summary.md" "round-[0-9]+-summary\\.md"
assert_modifies "cat data >> round-10-summary.md" "round-[0-9]+-summary\\.md"
assert_not_modifies "cat round-5-summary.md" "round-[0-9]+-summary\\.md"

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
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo ""
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi
