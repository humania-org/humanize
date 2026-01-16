#!/bin/bash
#
# Tests for plan file validation in setup-rlcr-loop.sh
#
# Tests:
# - Absolute path rejection
# - Relative path within project
# - Symlink rejection
# - Submodule rejection
# - Git repo validation
# - Plan file tracking status validation
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

setup_test_repo() {
    cd "$TEST_DIR"

    # Only init git if not already initialized
    if [[ ! -d ".git" ]]; then
        git init -q
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "initial" > init.txt
        git add init.txt
        git commit -q -m "Initial commit"

        # Create test plan files
        mkdir -p plans
        cat > plans/test-plan.md << 'EOF'
# Test Plan

## Goal
Test the RLCR loop functionality

## Requirements
- Requirement 1
- Requirement 2
- Requirement 3
EOF

        # Add plans/ to gitignore (default behavior)
        echo "plans/" >> .gitignore
        git add .gitignore
        git commit -q -m "Add gitignore"
    fi
}

# Mock codex command if not available
mock_codex() {
    if ! command -v codex &>/dev/null; then
        mkdir -p "$TEST_DIR/bin"
        cat > "$TEST_DIR/bin/codex" << 'EOF'
#!/bin/bash
echo "mock codex"
EOF
        chmod +x "$TEST_DIR/bin/codex"
        export PATH="$TEST_DIR/bin:$PATH"
    fi
}

echo "=== Test: Plan File Path Validation ==="
echo ""

# Test 1: Absolute path should fail
setup_test_repo
mock_codex

echo "Test 1: Reject absolute path"
set +e
RESULT=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" "/absolute/path/plan.md" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -ne 0 ]] && echo "$RESULT" | grep -q "relative path"; then
    pass "Absolute path rejected"
else
    fail "Absolute path rejection" "exit 1 with relative path error" "$RESULT"
fi

# Test 2: Non-existent file should fail
echo "Test 2: Reject non-existent file"
set +e
RESULT=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" "nonexistent.md" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -ne 0 ]] && echo "$RESULT" | grep -q "not found"; then
    pass "Non-existent file rejected"
else
    fail "Non-existent file rejection" "exit 1 with not found error" "$RESULT"
fi

# Test 2.5: Non-existent directory should fail with clear error
echo "Test 2.5: Reject non-existent parent directory"
set +e
RESULT=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" "nonexistent-dir/plan.md" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -ne 0 ]] && echo "$RESULT" | grep -q "directory not found"; then
    pass "Non-existent parent directory rejected with clear error"
else
    fail "Non-existent parent directory rejection" "exit 1 with directory not found error" "$RESULT"
fi

# Test 2.6: Path with spaces should fail
echo "Test 2.6: Reject path with spaces"
mkdir -p "$TEST_DIR/path with spaces"
cat > "$TEST_DIR/path with spaces/plan.md" << 'EOF'
# Plan
## Goal
Test spaces
## Requirements
- Requirement 1
- Requirement 2
EOF
set +e
RESULT=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" "path with spaces/plan.md" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -ne 0 ]] && echo "$RESULT" | grep -q "cannot contain spaces"; then
    pass "Path with spaces rejected"
else
    fail "Path with spaces rejection" "exit 1 with spaces error" "$RESULT"
fi

# Test 2.7: Filename with spaces should fail
echo "Test 2.7: Reject filename with spaces"
cat > "$TEST_DIR/plan with spaces.md" << 'EOF'
# Plan
## Goal
Test spaces
## Requirements
- Requirement 1
- Requirement 2
EOF
set +e
RESULT=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" "plan with spaces.md" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -ne 0 ]] && echo "$RESULT" | grep -q "cannot contain spaces"; then
    pass "Filename with spaces rejected"
else
    fail "Filename with spaces rejection" "exit 1 with spaces error" "$RESULT"
fi

# Test 2.8: Path with shell metacharacters should fail
echo "Test 2.8: Reject path with shell metacharacters"
cat > "$TEST_DIR/plans/test-plan.md" << 'EOF'
# Plan
## Goal
Test metacharacters
## Requirements
- Requirement 1
- Requirement 2
EOF
# Test various shell metacharacters
for meta_char in ';' '&' '|' '$' '`' '<' '>' '(' ')' '{' '}' '[' ']' '!' '#' '~' '*' '?'; do
    RESULT=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" "plans/test${meta_char}plan.md" 2>&1) || true
    if ! echo "$RESULT" | grep -q "shell metacharacters"; then
        fail "Shell metacharacter rejection ($meta_char)" "error mentioning metacharacters" "$RESULT"
        break
    fi
done
pass "Path with shell metacharacters rejected"

# Test 3: Symlink should fail
echo "Test 3: Reject symbolic link"
ln -sf plans/test-plan.md "$TEST_DIR/link-plan.md"
set +e
RESULT=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" "link-plan.md" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -ne 0 ]] && echo "$RESULT" | grep -q "symbolic link"; then
    pass "Symlink rejected"
else
    fail "Symlink rejection" "exit 1 with symbolic link error" "$RESULT"
fi

# Test 3.5: Path resolution error handling (Fix #4)
echo "Test 3.5: Handle path resolution errors gracefully"
# Create a directory structure where cd might fail
mkdir -p "$TEST_DIR/permission-test"
cd "$TEST_DIR/permission-test"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "init" > init.txt
git add init.txt
git commit -q -m "Initial"
# Create a plan directory that we'll make inaccessible
mkdir -p plans
cat > plans/plan.md << 'EOF'
# Plan
## Goal
Test path resolution
## Requirements
- Requirement 1
- Requirement 2
EOF
echo "plans/" >> .gitignore
git add .gitignore
git commit -q -m "Gitignore"
# Make the plans directory unreadable (if we have permission to do so)
if chmod 000 plans 2>/dev/null; then
    set +e
    RESULT=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" "plans/plan.md" 2>&1)
    EXIT_CODE=$?
    set -e
    # Restore permissions for cleanup
    chmod 755 plans
    # Should fail with clear error about directory access
    if [[ $EXIT_CODE -ne 0 ]] && echo "$RESULT" | grep -qE "resolve|not found|directory"; then
        pass "Path resolution error handled gracefully"
    else
        fail "Path resolution error" "clear error message" "exit $EXIT_CODE, output: $RESULT"
    fi
else
    skip "Path resolution error" "cannot change permissions in test environment"
fi
cd "$TEST_DIR"

# Test 4: Plan outside project (../ escape) should fail
echo "Test 4: Reject path escaping project directory"
mkdir -p "$TEST_DIR/outside"
cat > "$TEST_DIR/outside/escape-plan.md" << 'EOF'
# Escape Plan
## Goal
Test escape
## Requirements
- Requirement 1
- Requirement 2
EOF
mkdir -p "$TEST_DIR/project"
cd "$TEST_DIR/project"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "init" > init.txt
git add init.txt
git commit -q -m "Initial"
set +e
RESULT=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" "../outside/escape-plan.md" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -ne 0 ]] && echo "$RESULT" | grep -qE "(within project|not found)"; then
    pass "Path escape rejected"
else
    fail "Path escape rejection" "exit 1 with project directory error" "$RESULT"
fi

# Test 5: Non-git repo should fail
echo "Test 5: Reject non-git repository"
# Create a completely separate directory that is NOT inside any git repo
NOGIT_DIR=$(mktemp -d)
cd "$NOGIT_DIR"
cat > plan.md << 'EOF'
# Plan
## Goal
Test non-git
## Requirements
- Requirement 1
- Requirement 2
EOF
set +e
RESULT=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" "plan.md" 2>&1)
EXIT_CODE=$?
set -e
rm -rf "$NOGIT_DIR"
cd "$TEST_DIR"
if [[ $EXIT_CODE -ne 0 ]] && echo "$RESULT" | grep -q "git repository"; then
    pass "Non-git repo rejected"
else
    fail "Non-git repo rejection" "exit 1 with git repository error" "$RESULT"
fi

# Test 6: Git repo without commits should fail
echo "Test 6: Reject git repo without commits"
# Create a completely separate directory that is NOT inside any git repo
NOCOMMIT_DIR=$(mktemp -d)
cd "$NOCOMMIT_DIR"
git init -q
cat > plan.md << 'EOF'
# Plan
## Goal
Test no commits
## Requirements
- Requirement 1
- Requirement 2
EOF
set +e
RESULT=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" "plan.md" 2>&1)
EXIT_CODE=$?
set -e
rm -rf "$NOCOMMIT_DIR"
cd "$TEST_DIR"
if [[ $EXIT_CODE -ne 0 ]] && echo "$RESULT" | grep -q "at least one commit"; then
    pass "Git repo without commits rejected"
else
    fail "Git repo without commits rejection" "exit 1 with commit error" "$RESULT"
fi

echo ""
echo "=== Test: Plan File Tracking Validation ==="
echo ""

# Test 7: Tracked file without --track-plan-file should fail
echo "Test 7: Reject tracked file without --track-plan-file"
cd "$TEST_DIR"
rm -rf tracked-test 2>/dev/null || true
mkdir -p tracked-test
cd tracked-test
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "init" > init.txt
git add init.txt
git commit -q -m "Initial"
cat > tracked-plan.md << 'EOF'
# Tracked Plan
## Goal
Test tracking
## Requirements
- Requirement 1
- Requirement 2
EOF
git add tracked-plan.md
git commit -q -m "Add plan"
set +e
RESULT=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" "tracked-plan.md" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -ne 0 ]] && echo "$RESULT" | grep -q "gitignored"; then
    pass "Tracked file without --track-plan-file rejected"
else
    fail "Tracked file rejection" "exit 1 with gitignored error" "$RESULT"
fi

# Test 8: Untracked file with --track-plan-file should fail
echo "Test 8: Reject untracked file with --track-plan-file"
cd "$TEST_DIR"
rm -rf untracked-test 2>/dev/null || true
mkdir -p untracked-test
cd untracked-test
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "init" > init.txt
git add init.txt
git commit -q -m "Initial"
mkdir -p plans
cat > plans/untracked-plan.md << 'EOF'
# Untracked Plan
## Goal
Test untracked
## Requirements
- Requirement 1
- Requirement 2
EOF
echo "plans/" >> .gitignore
git add .gitignore
git commit -q -m "Gitignore"
set +e
RESULT=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" --track-plan-file "plans/untracked-plan.md" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -ne 0 ]] && echo "$RESULT" | grep -q "tracked in git"; then
    pass "Untracked file with --track-plan-file rejected"
else
    fail "Untracked file with --track-plan-file rejection" "exit 1 with tracked error" "$RESULT"
fi

# Test 9: Modified tracked file with --track-plan-file should fail
echo "Test 9: Reject modified tracked file with --track-plan-file"
cd "$TEST_DIR"
rm -rf modified-test 2>/dev/null || true
mkdir -p modified-test
cd modified-test
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "init" > init.txt
git add init.txt
git commit -q -m "Initial"
cat > modified-plan.md << 'EOF'
# Modified Plan
## Goal
Test modified
## Requirements
- Requirement 1
- Requirement 2
EOF
git add modified-plan.md
git commit -q -m "Add plan"
echo "# Extra line" >> modified-plan.md
set +e
RESULT=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" --track-plan-file "modified-plan.md" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -ne 0 ]] && echo "$RESULT" | grep -q "clean"; then
    pass "Modified tracked file with --track-plan-file rejected"
else
    fail "Modified tracked file rejection" "exit 1 with clean error" "$RESULT"
fi

echo ""
echo "=== Test: Branch Name Validation ==="
echo ""

# Test 9.5: Reject branch names with YAML-unsafe characters (Fix #2)
# Note: Git itself may reject some of these characters, which is fine
# We test that either git rejects it OR our script rejects it
echo "Test 9.5: Reject branch with colon (YAML-unsafe)"
cd "$TEST_DIR"
rm -rf branch-test 2>/dev/null || true
mkdir -p branch-test
cd branch-test
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "init" > init.txt
git add init.txt
git commit -q -m "Initial"
# Get the default branch name for this repo (main or master)
BRANCH_TEST_DEFAULT=$(git rev-parse --abbrev-ref HEAD)
mkdir -p plans
cat > plans/plan.md << 'EOF'
# Plan
## Goal
Test branch validation
## Requirements
- Requirement 1
- Requirement 2
EOF
echo "plans/" >> .gitignore
git add .gitignore
git commit -q -m "Gitignore"
# Try to create branch with colon (YAML-unsafe) - git may reject this
if git checkout -q -b "feature:test" 2>/dev/null; then
    set +e
    RESULT=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" "plans/plan.md" 2>&1)
    EXIT_CODE=$?
    set -e
    if [[ $EXIT_CODE -ne 0 ]] && echo "$RESULT" | grep -q "YAML-unsafe"; then
        pass "Branch with colon rejected"
    else
        fail "Branch with colon rejection" "exit 1 with YAML-unsafe error" "$RESULT"
    fi
    git checkout -q "$BRANCH_TEST_DEFAULT" 2>/dev/null || true
else
    # Git itself rejected the branch name, which is also fine
    pass "Branch with colon rejected (by git)"
fi

# Test 9.6: Reject branch names with hash (YAML comment)
echo "Test 9.6: Reject branch with hash (YAML comment)"
git checkout -q "$BRANCH_TEST_DEFAULT" 2>/dev/null || true
# Try to create a branch with hash - some git versions may not allow this
if git checkout -q -b "test#comment" 2>/dev/null; then
    set +e
    RESULT=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" "plans/plan.md" 2>&1)
    EXIT_CODE=$?
    set -e
    if [[ $EXIT_CODE -ne 0 ]] && echo "$RESULT" | grep -q "YAML-unsafe"; then
        pass "Branch with hash rejected"
    else
        fail "Branch with hash rejection" "exit 1 with YAML-unsafe error" "$RESULT"
    fi
    git checkout -q "$BRANCH_TEST_DEFAULT" 2>/dev/null || true
else
    pass "Branch with hash rejected (by git)"
fi

# Test 9.7: Reject branch names with quotes
echo "Test 9.7: Reject branch with quotes (YAML-unsafe)"
git checkout -q "$BRANCH_TEST_DEFAULT" 2>/dev/null || true
if git checkout -q -b 'test"quote' 2>/dev/null; then
    set +e
    RESULT=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" "plans/plan.md" 2>&1)
    EXIT_CODE=$?
    set -e
    if [[ $EXIT_CODE -ne 0 ]] && echo "$RESULT" | grep -q "YAML-unsafe"; then
        pass "Branch with quotes rejected"
    else
        fail "Branch with quotes rejection" "exit 1 with YAML-unsafe error" "$RESULT"
    fi
    git checkout -q "$BRANCH_TEST_DEFAULT" 2>/dev/null || true
else
    pass "Branch with quotes rejected (by git)"
fi

echo ""
echo "=== Test: CLI Options ==="
echo ""

# Test 10: --plan-file option works
echo "Test 10: --plan-file option"
cd "$TEST_DIR"
setup_test_repo
mock_codex
set +e
# This should fail validation (not actually run), but pass CLI parsing
RESULT=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" --plan-file "plans/test-plan.md" 2>&1)
EXIT_CODE=$?
set -e
# Should get past CLI parsing - either run or fail on some validation
if ! echo "$RESULT" | grep -q "requires a file path"; then
    pass "--plan-file option accepted"
else
    fail "--plan-file option" "option accepted" "$RESULT"
fi

# Test 11: Both --plan-file and positional should fail
echo "Test 11: Reject both --plan-file and positional"
set +e
RESULT=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" --plan-file "plans/a.md" "plans/b.md" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -ne 0 ]] && echo "$RESULT" | grep -q "Cannot specify both"; then
    pass "Both --plan-file and positional rejected"
else
    fail "Both options rejection" "exit 1 with both error" "$RESULT"
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
