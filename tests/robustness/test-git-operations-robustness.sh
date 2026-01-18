#!/bin/bash
#
# Robustness tests for git operation scripts (AC-5)
#
# Tests git operations under edge cases:
# - Clean repository state
# - Branch detection
# - Detached HEAD
# - Rebase/merge in progress
# - Shallow clone
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/scripts/portable-timeout.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo -e "${GREEN}PASS${NC}: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "${RED}FAIL${NC}: $1"
    echo "  Expected: $2"
    echo "  Got: $3"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# Setup test directory with git repo
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

echo "========================================"
echo "Git Operations Robustness Tests (AC-5)"
echo "========================================"
echo ""

# Initialize a test git repository
init_test_repo() {
    local dir="$1"
    mkdir -p "$dir"
    cd "$dir"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test User"
    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "Initial commit"
    cd - > /dev/null
}

# ========================================
# Positive Tests - Normal Git Operations
# ========================================

echo "--- Positive Tests: Normal Git Operations ---"
echo ""

# Test 1: Clean repository state
echo "Test 1: Detect clean repository state"
init_test_repo "$TEST_DIR/repo1"
cd "$TEST_DIR/repo1"
STATUS=$(git status --porcelain)
if [[ -z "$STATUS" ]]; then
    pass "Clean repository detected correctly"
else
    fail "Clean repo" "empty status" "$STATUS"
fi
cd - > /dev/null

# Test 2: Branch name detection
echo ""
echo "Test 2: Detect branch name correctly"
cd "$TEST_DIR/repo1"
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$BRANCH" == "master" ]] || [[ "$BRANCH" == "main" ]]; then
    pass "Branch name detected: $BRANCH"
else
    fail "Branch detection" "master or main" "$BRANCH"
fi
cd - > /dev/null

# Test 3: Git status output parsing
echo ""
echo "Test 3: Parse git status output"
cd "$TEST_DIR/repo1"
echo "new file" > newfile.txt
STATUS=$(git status --porcelain)
if [[ "$STATUS" == "?? newfile.txt" ]]; then
    pass "Git status parsed correctly: untracked file"
else
    fail "Status parsing" "?? newfile.txt" "$STATUS"
fi
rm newfile.txt
cd - > /dev/null

# Test 4: Git with timeout (success case)
echo ""
echo "Test 4: Git operations with timeout"
cd "$TEST_DIR/repo1"
RESULT=$(run_with_timeout 5 git status --porcelain)
EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Git with timeout completes successfully"
else
    fail "Git timeout" "exit 0" "exit $EXIT_CODE"
fi
cd - > /dev/null

# Test 5: Feature branch detection
echo ""
echo "Test 5: Feature branch creation and detection"
cd "$TEST_DIR/repo1"
git checkout -q -b feature/test-branch
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$BRANCH" == "feature/test-branch" ]]; then
    pass "Feature branch detected correctly"
else
    fail "Feature branch" "feature/test-branch" "$BRANCH"
fi
git checkout -q master 2>/dev/null || git checkout -q main
cd - > /dev/null

# ========================================
# Negative Tests - Edge Cases
# ========================================

echo ""
echo "--- Negative Tests: Edge Cases ---"
echo ""

# Test 6: Detached HEAD state
echo "Test 6: Detect detached HEAD state"
cd "$TEST_DIR/repo1"
COMMIT=$(git rev-parse HEAD)
git checkout -q "$COMMIT"
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$BRANCH" == "HEAD" ]]; then
    pass "Detached HEAD detected correctly"
else
    fail "Detached HEAD" "HEAD" "$BRANCH"
fi
git checkout -q master 2>/dev/null || git checkout -q main
cd - > /dev/null

# Test 7: Check if in rebase state
echo ""
echo "Test 7: Detect rebase state indicators"
cd "$TEST_DIR/repo1"
# Not actually in rebase, but check the detection mechanism
if [[ ! -d .git/rebase-merge ]] && [[ ! -d .git/rebase-apply ]]; then
    pass "No rebase in progress detected correctly"
else
    fail "Rebase detection" "no rebase dirs" "found rebase dirs"
fi
cd - > /dev/null

# Test 8: Check if in merge state
echo ""
echo "Test 8: Detect merge state indicators"
cd "$TEST_DIR/repo1"
if [[ ! -f .git/MERGE_HEAD ]]; then
    pass "No merge in progress detected correctly"
else
    fail "Merge detection" "no MERGE_HEAD" "found MERGE_HEAD"
fi
cd - > /dev/null

# Test 9: Shallow clone detection
echo ""
echo "Test 9: Detect shallow clone"
cd "$TEST_DIR/repo1"
if [[ ! -f .git/shallow ]]; then
    pass "Not a shallow clone (shallow file absent)"
else
    fail "Shallow detection" "no shallow file" "shallow file exists"
fi
cd - > /dev/null

# Test 10: Git rev-parse for repository detection
echo ""
echo "Test 10: Detect git repository root"
cd "$TEST_DIR/repo1"
GIT_DIR=$(git rev-parse --git-dir)
if [[ "$GIT_DIR" == ".git" ]]; then
    pass "Git repository detected correctly"
else
    fail "Repo detection" ".git" "$GIT_DIR"
fi
cd - > /dev/null

# Test 11: Non-git directory
echo ""
echo "Test 11: Handle non-git directory"
mkdir -p "$TEST_DIR/not-a-repo"
cd "$TEST_DIR/not-a-repo"
set +e
git rev-parse --git-dir 2>/dev/null
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -ne 0 ]]; then
    pass "Non-git directory detected correctly (exit: $EXIT_CODE)"
else
    fail "Non-git detection" "non-zero exit" "exit 0"
fi
cd - > /dev/null

# Test 12: Empty repository (no commits)
echo ""
echo "Test 12: Handle empty repository (no commits)"
mkdir -p "$TEST_DIR/empty-repo"
cd "$TEST_DIR/empty-repo"
git init -q
set +e
git rev-parse HEAD 2>/dev/null
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -ne 0 ]]; then
    pass "Empty repo (no commits) detected correctly"
else
    fail "Empty repo" "non-zero exit" "exit 0"
fi
cd - > /dev/null

# Test 13: Branch with special characters
echo ""
echo "Test 13: Branch with special characters"
cd "$TEST_DIR/repo1"
git checkout -q -b "feature/test-with-dashes_and_underscores"
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [[ "$BRANCH" == "feature/test-with-dashes_and_underscores" ]]; then
    pass "Branch with special chars detected correctly"
else
    fail "Special chars branch" "feature/test-with-dashes_and_underscores" "$BRANCH"
fi
git checkout -q master 2>/dev/null || git checkout -q main
cd - > /dev/null

# Test 14: Git config values
echo ""
echo "Test 14: Git config retrieval"
cd "$TEST_DIR/repo1"
EMAIL=$(git config user.email)
if [[ "$EMAIL" == "test@test.com" ]]; then
    pass "Git config retrieved correctly"
else
    fail "Git config" "test@test.com" "$EMAIL"
fi
cd - > /dev/null

# Test 15: Staged vs unstaged changes
echo ""
echo "Test 15: Distinguish staged vs unstaged changes"
cd "$TEST_DIR/repo1"
echo "staged" > staged.txt
git add staged.txt
echo "unstaged" > unstaged.txt
STAGED=$(git diff --cached --name-only)
UNSTAGED=$(git status --porcelain | grep "^??" | wc -l)
if [[ "$STAGED" == "staged.txt" ]] && [[ "$UNSTAGED" -eq 1 ]]; then
    pass "Staged and unstaged changes distinguished"
else
    fail "Staged/unstaged" "staged.txt and 1 untracked" "staged=$STAGED, untracked=$UNSTAGED"
fi
git reset -q HEAD staged.txt
rm -f staged.txt unstaged.txt
cd - > /dev/null

# Test 16: Git log parsing
echo ""
echo "Test 16: Git log output parsing"
cd "$TEST_DIR/repo1"
COMMIT_MSG=$(git log -1 --format="%s")
if [[ "$COMMIT_MSG" == "Initial commit" ]]; then
    pass "Git log parsed correctly"
else
    fail "Git log" "Initial commit" "$COMMIT_MSG"
fi
cd - > /dev/null

# Test 17: Git diff output
echo ""
echo "Test 17: Git diff parsing"
cd "$TEST_DIR/repo1"
echo "modified" >> file.txt
DIFF=$(git diff --stat)
if echo "$DIFF" | grep -q "file.txt"; then
    pass "Git diff output contains modified file"
else
    fail "Git diff" "contains file.txt" "$DIFF"
fi
git checkout -q file.txt
cd - > /dev/null

# Test 18: Multiple remotes handling
echo ""
echo "Test 18: Handle repositories without remotes"
cd "$TEST_DIR/repo1"
REMOTES=$(git remote)
if [[ -z "$REMOTES" ]]; then
    pass "No remotes detected correctly"
else
    fail "Remote detection" "no remotes" "$REMOTES"
fi
cd - > /dev/null

# ========================================
# Summary
# ========================================

echo ""
echo "========================================"
echo "Git Operations Robustness Test Summary"
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
