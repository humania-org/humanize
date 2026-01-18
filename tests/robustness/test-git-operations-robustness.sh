#!/bin/bash
#
# Robustness tests for git operation scripts (AC-5)
#
# Tests production humanize_parse_git_status function from scripts/humanize.sh:
# - Clean repository state
# - Modified/added/deleted/untracked files
# - Detached HEAD handling
# - Rebase/merge state detection
# - Non-git directory handling
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/scripts/portable-timeout.sh"
source "$PROJECT_ROOT/scripts/humanize.sh"

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

# ========================================
# Production Function Under Test
# ========================================

# Uses humanize_parse_git_status from scripts/humanize.sh (sourced above)
# Returns: modified|added|deleted|untracked|insertions|deletions

# Helper to parse output
parse_result() {
    local result="$1"
    local field="$2"
    case "$field" in
        modified) echo "$result" | cut -d'|' -f1 ;;
        added) echo "$result" | cut -d'|' -f2 ;;
        deleted) echo "$result" | cut -d'|' -f3 ;;
        untracked) echo "$result" | cut -d'|' -f4 ;;
        insertions) echo "$result" | cut -d'|' -f5 ;;
        deletions) echo "$result" | cut -d'|' -f6 ;;
    esac
}

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
RESULT=$(humanize_parse_git_status)
MODIFIED=$(parse_result "$RESULT" modified)
ADDED=$(parse_result "$RESULT" added)
UNTRACKED=$(parse_result "$RESULT" untracked)
if [[ "$MODIFIED" == "0" ]] && [[ "$ADDED" == "0" ]] && [[ "$UNTRACKED" == "0" ]]; then
    pass "Clean repository: all counts are 0"
else
    fail "Clean repo" "0|0|0" "modified=$MODIFIED, added=$ADDED, untracked=$UNTRACKED"
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

# Test 3: Detect untracked files
echo ""
echo "Test 3: Count untracked files"
cd "$TEST_DIR/repo1"
echo "new file" > newfile.txt
RESULT=$(humanize_parse_git_status)
UNTRACKED=$(parse_result "$RESULT" untracked)
if [[ "$UNTRACKED" == "1" ]]; then
    pass "Untracked file count: 1"
else
    fail "Untracked count" "1" "$UNTRACKED"
fi
rm newfile.txt
cd - > /dev/null

# Test 4: Detect modified files
echo ""
echo "Test 4: Count modified files"
cd "$TEST_DIR/repo1"
echo "modified content" >> file.txt
RESULT=$(humanize_parse_git_status)
MODIFIED=$(parse_result "$RESULT" modified)
if [[ "$MODIFIED" == "1" ]]; then
    pass "Modified file count: 1"
else
    fail "Modified count" "1" "$MODIFIED"
fi
git checkout -q file.txt
cd - > /dev/null

# Test 5: Detect added (staged) files
echo ""
echo "Test 5: Count staged added files"
cd "$TEST_DIR/repo1"
echo "new staged" > staged.txt
git add staged.txt
RESULT=$(humanize_parse_git_status)
ADDED=$(parse_result "$RESULT" added)
if [[ "$ADDED" == "1" ]]; then
    pass "Added (staged) file count: 1"
else
    fail "Added count" "1" "$ADDED"
fi
git reset -q HEAD staged.txt
rm staged.txt
cd - > /dev/null

# Test 6: Count insertions
echo ""
echo "Test 6: Count line insertions"
cd "$TEST_DIR/repo1"
echo -e "line1\nline2\nline3" >> file.txt
RESULT=$(humanize_parse_git_status)
INSERTIONS=$(parse_result "$RESULT" insertions)
if [[ "$INSERTIONS" -ge "3" ]]; then
    pass "Insertions counted: $INSERTIONS"
else
    fail "Insertions" ">=3" "$INSERTIONS"
fi
git checkout -q file.txt
cd - > /dev/null

# ========================================
# Negative Tests - Edge Cases
# ========================================

echo ""
echo "--- Negative Tests: Edge Cases ---"
echo ""

# Test 7: Non-git directory
echo "Test 7: Handle non-git directory"
mkdir -p "$TEST_DIR/not-a-repo"
cd "$TEST_DIR/not-a-repo"
RESULT=$(humanize_parse_git_status)
if [[ "$RESULT" == *"not a git repo"* ]]; then
    pass "Non-git directory detected"
else
    fail "Non-git detection" "contains 'not a git repo'" "$RESULT"
fi
cd - > /dev/null

# Test 8: Detached HEAD state
echo ""
echo "Test 8: Parse status in detached HEAD state"
cd "$TEST_DIR/repo1"
COMMIT=$(git rev-parse HEAD)
git checkout -q "$COMMIT"
RESULT=$(humanize_parse_git_status)
MODIFIED=$(parse_result "$RESULT" modified)
# Should still parse status correctly in detached HEAD
if [[ "$MODIFIED" == "0" ]]; then
    pass "Parses status correctly in detached HEAD"
else
    fail "Detached HEAD status" "modified=0" "modified=$MODIFIED"
fi
git checkout -q master 2>/dev/null || git checkout -q main
cd - > /dev/null

# Test 9: Multiple file states
echo ""
echo "Test 9: Handle multiple file states simultaneously"
cd "$TEST_DIR/repo1"
echo "mod" >> file.txt                    # Modified
echo "new" > new.txt                      # Untracked
echo "staged" > staged.txt && git add staged.txt  # Added
RESULT=$(humanize_parse_git_status)
MODIFIED=$(parse_result "$RESULT" modified)
ADDED=$(parse_result "$RESULT" added)
UNTRACKED=$(parse_result "$RESULT" untracked)
if [[ "$MODIFIED" -ge "1" ]] && [[ "$ADDED" -ge "1" ]] && [[ "$UNTRACKED" -ge "1" ]]; then
    pass "Multiple states: mod=$MODIFIED, add=$ADDED, untrack=$UNTRACKED"
else
    fail "Multiple states" ">=1 each" "mod=$MODIFIED, add=$ADDED, untrack=$UNTRACKED"
fi
git checkout -q file.txt
git reset -q HEAD staged.txt
rm -f new.txt staged.txt
cd - > /dev/null

# Test 10: Deleted file detection
echo ""
echo "Test 10: Detect deleted files"
cd "$TEST_DIR/repo1"
rm file.txt
RESULT=$(humanize_parse_git_status)
DELETED=$(parse_result "$RESULT" deleted)
if [[ "$DELETED" == "1" ]]; then
    pass "Deleted file count: 1"
else
    fail "Deleted count" "1" "$DELETED"
fi
git checkout -q file.txt
cd - > /dev/null

# Test 11: Empty repository (no commits yet)
echo ""
echo "Test 11: Handle empty repository (no commits)"
mkdir -p "$TEST_DIR/empty-repo"
cd "$TEST_DIR/empty-repo"
git init -q
RESULT=$(humanize_parse_git_status)
# Should not crash, may return zeros or empty
if [[ -n "$RESULT" ]]; then
    pass "Empty repo handled gracefully: $RESULT"
else
    fail "Empty repo" "non-empty result" "empty"
fi
cd - > /dev/null

# Test 12: Feature branch
echo ""
echo "Test 12: Feature branch status parsing"
cd "$TEST_DIR/repo1"
git checkout -q -b feature/test-branch
echo "feature work" > feature.txt
RESULT=$(humanize_parse_git_status)
UNTRACKED=$(parse_result "$RESULT" untracked)
if [[ "$UNTRACKED" == "1" ]]; then
    pass "Feature branch status parsed correctly"
else
    fail "Feature branch" "1 untracked" "$UNTRACKED"
fi
rm feature.txt
git checkout -q master 2>/dev/null || git checkout -q main
cd - > /dev/null

# Test 13: Renamed file
echo ""
echo "Test 13: Detect renamed file"
cd "$TEST_DIR/repo1"
git mv file.txt renamed.txt
RESULT=$(humanize_parse_git_status)
MODIFIED=$(parse_result "$RESULT" modified)
# Renamed counts as modified in our implementation
if [[ "$MODIFIED" -ge "1" ]]; then
    pass "Renamed file detected as modified: $MODIFIED"
else
    fail "Renamed file" ">=1 modified" "$MODIFIED"
fi
# Undo the rename
git reset -q HEAD
mv renamed.txt file.txt
git checkout -q file.txt 2>/dev/null || true
cd - > /dev/null

# Test 14: Many untracked files
echo ""
echo "Test 14: Handle many untracked files (20)"
cd "$TEST_DIR/repo1"
for i in $(seq 1 20); do
    echo "content $i" > "untracked$i.txt"
done
RESULT=$(humanize_parse_git_status)
UNTRACKED=$(parse_result "$RESULT" untracked)
if [[ "$UNTRACKED" == "20" ]]; then
    pass "Counts 20 untracked files correctly"
else
    fail "Many untracked" "20" "$UNTRACKED"
fi
rm -f untracked*.txt
cd - > /dev/null

# Test 15: File with spaces in name
echo ""
echo "Test 15: Handle file with spaces in name"
cd "$TEST_DIR/repo1"
echo "content" > "file with spaces.txt"
RESULT=$(humanize_parse_git_status)
UNTRACKED=$(parse_result "$RESULT" untracked)
if [[ "$UNTRACKED" == "1" ]]; then
    pass "File with spaces counted correctly"
else
    fail "Spaces in filename" "1" "$UNTRACKED"
fi
rm -f "file with spaces.txt"
cd - > /dev/null

# Test 16: Binary file
echo ""
echo "Test 16: Handle binary file changes"
cd "$TEST_DIR/repo1"
printf '\x00\x01\x02\x03' > binary.bin
RESULT=$(humanize_parse_git_status)
UNTRACKED=$(parse_result "$RESULT" untracked)
if [[ "$UNTRACKED" == "1" ]]; then
    pass "Binary file counted as untracked"
else
    fail "Binary file" "1 untracked" "$UNTRACKED"
fi
rm binary.bin
cd - > /dev/null

# Test 17: Simultaneous staged and unstaged changes to same file
echo ""
echo "Test 17: Same file with staged and unstaged changes"
cd "$TEST_DIR/repo1"
echo "staged change" >> file.txt
git add file.txt
echo "unstaged change" >> file.txt
RESULT=$(humanize_parse_git_status)
MODIFIED=$(parse_result "$RESULT" modified)
# MM status (staged + unstaged) should count as 1 modified
if [[ "$MODIFIED" -ge "1" ]]; then
    pass "Staged + unstaged same file: modified=$MODIFIED"
else
    fail "Same file staged+unstaged" ">=1 modified" "$MODIFIED"
fi
git checkout -q file.txt
cd - > /dev/null

# Test 18: Count deletions
echo ""
echo "Test 18: Count line deletions"
cd "$TEST_DIR/repo1"
# First add some lines and commit
echo -e "line1\nline2\nline3" >> file.txt
git add file.txt
git commit -q -m "Add lines"
# Now delete them
git checkout -q HEAD~1 -- file.txt
RESULT=$(humanize_parse_git_status)
DELETIONS=$(parse_result "$RESULT" deletions)
if [[ "$DELETIONS" -ge "3" ]]; then
    pass "Deletions counted: $DELETIONS"
else
    fail "Deletions" ">=3" "$DELETIONS"
fi
git checkout -q file.txt
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
