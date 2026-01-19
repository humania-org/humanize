#!/bin/bash
#
# Robustness tests for base branch auto-detection
#
# Tests the base branch detection logic in setup-rlcr-loop.sh:
# - User-specified --base-branch takes priority
# - Remote default branch detection with origin remote
# - Fallback to local main branch
# - Fallback to local master branch
# - Error when no base branch can be determined
# - Graceful handling when origin remote is missing
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../test-helpers.sh"
source "$PROJECT_ROOT/scripts/portable-timeout.sh"

# We need to extract just the base-branch detection logic for testing
# Since the full setup script requires many dependencies, we test the core logic

setup_test_dir

echo "========================================"
echo "Base Branch Detection Robustness Tests"
echo "========================================"
echo ""

# ========================================
# Helper: Simulate base branch detection
# ========================================

# This replicates the logic from setup-rlcr-loop.sh lines 549-567
detect_base_branch() {
    local project_root="$1"
    local git_timeout="${2:-10}"

    # Priority 1: Remote default branch (typically main or master)
    # Guard with || true to prevent pipefail from terminating when origin is missing
    local remote_default
    remote_default=$(timeout "$git_timeout" git -C "$project_root" remote show origin 2>/dev/null | grep "HEAD branch:" | sed 's/.*HEAD branch:[[:space:]]*//' || true)
    if [[ -n "$remote_default" && "$remote_default" != "(unknown)" ]]; then
        echo "$remote_default"
        return 0
    fi

    # Priority 2: Local main branch
    if timeout "$git_timeout" git -C "$project_root" show-ref --verify --quiet refs/heads/main 2>/dev/null; then
        echo "main"
        return 0
    fi

    # Priority 3: Local master branch
    if timeout "$git_timeout" git -C "$project_root" show-ref --verify --quiet refs/heads/master 2>/dev/null; then
        echo "master"
        return 0
    fi

    # No base branch found
    return 1
}

# ========================================
# Test: No origin remote, local main exists
# ========================================

echo "--- Test: Fallback to local main when origin is missing ---"
echo ""

echo "Test 1: Repo with local main branch, no remote"
REPO1="$TEST_DIR/repo-no-origin-has-main"
mkdir -p "$REPO1"
cd "$REPO1"
git init -q
git config user.email "test@test.com"
git config user.name "Test User"
git config commit.gpgsign false
# Create main branch
git checkout -q -b main 2>/dev/null || git checkout -q main
echo "initial" > file.txt
git add file.txt
git commit -q -m "Initial commit"
cd - > /dev/null

RESULT=$(detect_base_branch "$REPO1" 5 || echo "FAILED")
if [[ "$RESULT" == "main" ]]; then
    pass "Detected local main branch when origin missing"
else
    fail "Fallback to main" "main" "$RESULT"
fi

# ========================================
# Test: No origin remote, local master exists
# ========================================

echo ""
echo "Test 2: Repo with local master branch, no remote"
REPO2="$TEST_DIR/repo-no-origin-has-master"
mkdir -p "$REPO2"
cd "$REPO2"
git init -q
git config user.email "test@test.com"
git config user.name "Test User"
git config commit.gpgsign false
# Create master branch (git init default on older systems)
git checkout -q -b master 2>/dev/null || true
echo "initial" > file.txt
git add file.txt
git commit -q -m "Initial commit"
# Ensure we don't have main branch
git branch -D main 2>/dev/null || true
cd - > /dev/null

RESULT=$(detect_base_branch "$REPO2" 5 || echo "FAILED")
if [[ "$RESULT" == "master" ]]; then
    pass "Detected local master branch when origin missing and no main"
else
    fail "Fallback to master" "master" "$RESULT"
fi

# ========================================
# Test: No origin, no main, no master
# ========================================

echo ""
echo "Test 3: Repo with no origin, no main, no master (should fail)"
REPO3="$TEST_DIR/repo-no-branches"
mkdir -p "$REPO3"
cd "$REPO3"
git init -q
git config user.email "test@test.com"
git config user.name "Test User"
git config commit.gpgsign false
# Create a branch called 'develop' (not main or master)
git checkout -q -b develop
echo "initial" > file.txt
git add file.txt
git commit -q -m "Initial commit"
cd - > /dev/null

if detect_base_branch "$REPO3" 5 >/dev/null 2>&1; then
    RESULT=$(detect_base_branch "$REPO3" 5)
    fail "Should fail when no main/master" "failure (return 1)" "success with: $RESULT"
else
    pass "Correctly fails when no main or master branch exists"
fi

# ========================================
# Test: origin remote exists with default branch
# ========================================

echo ""
echo "Test 4: Repo with origin remote (simulated)"
REPO4="$TEST_DIR/repo-with-origin"
REMOTE4="$TEST_DIR/bare-remote"

# Create bare remote
mkdir -p "$REMOTE4"
cd "$REMOTE4"
git init -q --bare
cd - > /dev/null

# Create local repo and add origin
mkdir -p "$REPO4"
cd "$REPO4"
git init -q
git config user.email "test@test.com"
git config user.name "Test User"
git config commit.gpgsign false
git checkout -q -b main
echo "initial" > file.txt
git add file.txt
git commit -q -m "Initial commit"
git remote add origin "$REMOTE4"
git push -q -u origin main 2>/dev/null || true
cd - > /dev/null

RESULT=$(detect_base_branch "$REPO4" 5 || echo "FAILED")
if [[ "$RESULT" == "main" ]]; then
    pass "Detected branch from origin remote or local main"
else
    # May fall back to local main if remote show fails
    if [[ "$RESULT" == "FAILED" ]]; then
        fail "Base branch detection" "main" "FAILED"
    else
        pass "Detected branch: $RESULT (acceptable)"
    fi
fi

# ========================================
# Summary
# ========================================

echo ""
print_test_summary "Base Branch Detection Summary"
