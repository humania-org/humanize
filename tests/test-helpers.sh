#!/bin/bash
#
# Shared test helper functions for all test scripts
#
# Usage: source "$SCRIPT_DIR/test-helpers.sh" (from tests/)
# Usage: source "$SCRIPT_DIR/../test-helpers.sh" (from tests/robustness/)
#

# ========================================
# Colors
# ========================================

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_YELLOW='\033[1;33m'
readonly TEST_NC='\033[0m'

# ========================================
# Test Counters
# ========================================

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# ========================================
# Test Result Functions
# ========================================

pass() {
    echo -e "${TEST_GREEN}PASS${TEST_NC}: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "${TEST_RED}FAIL${TEST_NC}: $1"
    if [[ $# -ge 2 ]]; then
        echo "  Expected: $2"
    fi
    if [[ $# -ge 3 ]]; then
        echo "  Got: $3"
    fi
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

skip() {
    echo -e "${TEST_YELLOW}SKIP${TEST_NC}: $1"
    if [[ $# -ge 2 ]]; then
        echo "  Reason: $2"
    fi
    TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
}

# ========================================
# Summary Function
# ========================================

print_test_summary() {
    local title="${1:-Test Summary}"
    echo ""
    echo "========================================"
    echo "$title"
    echo "========================================"
    echo -e "Passed: ${TEST_GREEN}$TESTS_PASSED${TEST_NC}"
    echo -e "Failed: ${TEST_RED}$TESTS_FAILED${TEST_NC}"
    if [[ $TESTS_SKIPPED -gt 0 ]]; then
        echo -e "Skipped: ${TEST_YELLOW}$TESTS_SKIPPED${TEST_NC}"
    fi
    echo ""

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${TEST_GREEN}All tests passed!${TEST_NC}"
        return 0
    else
        echo -e "${TEST_RED}Some tests failed!${TEST_NC}"
        return 1
    fi
}

# ========================================
# Test Directory Setup
# ========================================

# Create a temporary test directory with automatic cleanup
# Sets TEST_DIR variable
setup_test_dir() {
    TEST_DIR=$(mktemp -d)
    trap "rm -rf $TEST_DIR" EXIT
}

# Create a mock git repository in a directory
# Usage: init_test_git_repo "$dir"
init_test_git_repo() {
    local dir="$1"
    mkdir -p "$dir"
    cd "$dir"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test User"
    git config commit.gpgsign false
    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "Initial commit"
    cd - > /dev/null
}
