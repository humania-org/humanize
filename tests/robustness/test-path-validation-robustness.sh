#!/bin/bash
#
# Robustness tests for path validation
#
# Tests production path validation in scripts/setup-rlcr-loop.sh by:
# - Creating test plan files with various path structures
# - Running setup-rlcr-loop.sh and checking for proper rejection/acceptance
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../test-helpers.sh"

setup_test_dir

# Create mock codex to prevent calling real codex (which is slow)
# This mock exits 0 so setup-rlcr-loop.sh would proceed, but we check for
# validation errors first. If path validation passes, the script will reach
# codex check and this mock will be used.
setup_mock_codex() {
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/codex" << 'MOCKEOF'
#!/bin/bash
# Mock codex for test-path-validation-robustness.sh
echo "Mock codex output"
exit 0
MOCKEOF
    chmod +x "$TEST_DIR/bin/codex"
    export PATH="$TEST_DIR/bin:$PATH"
}

# Initialize mock codex
setup_mock_codex

# Create a mock git repo in the test directory
cd "$TEST_DIR"
git init --quiet
git config user.email "test@test.com"
git config user.name "Test User"
git config commit.gpgsign false
echo "Initial" > README.md
git add README.md
git commit -m "Initial commit" --quiet

# Create valid plan file content (5+ lines as required by production)
create_valid_plan() {
    local file="$1"
    mkdir -p "$(dirname "$file")"
    cat > "$file" << 'EOF'
# Implementation Plan

## Goal

Build the feature.

## Tasks

1. Task one
2. Task two
EOF
}

echo "========================================"
echo "Path Validation Robustness Tests"
echo "========================================"
echo ""

# ========================================
# Helper to run production script
# ========================================

# Test path validation by running setup-rlcr-loop.sh with a plan file path
# Returns exit code from script (0 = accepted, non-zero = rejected)
test_path_validation() {
    local plan_path="$1"
    local result
    local exit_code

    # Clean up any existing RLCR loop in TEST_DIR to avoid "loop already active" errors
    rm -rf "$TEST_DIR/.humanize/rlcr" 2>/dev/null || true

    # Run the production script (will fail after path validation
    # because codex isn't available, but we capture validation errors)
    result=$(CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" "$plan_path" 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}

    # Check for specific path/content validation errors
    # These patterns match error messages from setup-rlcr-loop.sh
    if echo "$result" | grep -qE "(Plan file (path|must|cannot|not found|not readable)|Plan is too simple|Plan file has insufficient content|symbolic link|directory not found)"; then
        return 1  # Path/content validation failed
    fi

    # Check for codex not available - this means all validations passed
    if echo "$result" | grep -q "requires codex"; then
        return 0
    fi

    # Check for gitignore error (plan file tracking) - path validation passed
    if echo "$result" | grep -q "must be gitignored"; then
        return 0
    fi

    # Any other error is a failure
    if [[ $exit_code -ne 0 ]]; then
        return 1
    fi

    return $exit_code
}

# ========================================
# Positive Tests - Valid Paths
# ========================================

echo "--- Positive Tests: Valid Paths ---"
echo ""

# Test 1: Normal relative path
echo "Test 1: Validate normal relative paths"
create_valid_plan "$TEST_DIR/docs/plan.md"
if test_path_validation "docs/plan.md"; then
    pass "Accepts normal relative path"
else
    fail "Normal relative path" "accepted" "rejected"
fi

# Test 2: Simple filename in root
echo ""
echo "Test 2: Simple filename in project root"
create_valid_plan "$TEST_DIR/plan.md"
if test_path_validation "plan.md"; then
    pass "Accepts simple filename"
else
    fail "Simple filename" "accepted" "rejected"
fi

# Test 3: Path with dash and underscore
echo ""
echo "Test 3: Path with dash and underscore"
create_valid_plan "$TEST_DIR/my-plan_v2.md"
if test_path_validation "my-plan_v2.md"; then
    pass "Accepts dash and underscore"
else
    fail "Dash/underscore path" "accepted" "rejected"
fi

# Test 4: Nested directory path
echo ""
echo "Test 4: Nested directory path"
create_valid_plan "$TEST_DIR/a/b/c/plan.md"
if test_path_validation "a/b/c/plan.md"; then
    pass "Accepts nested directory path"
else
    fail "Nested path" "accepted" "rejected"
fi

# Test 5: Path with dots in filename
echo ""
echo "Test 5: Path with dots in filename"
create_valid_plan "$TEST_DIR/plan.v1.2.md"
if test_path_validation "plan.v1.2.md"; then
    pass "Accepts dots in filename"
else
    fail "Dots in filename" "accepted" "rejected"
fi

# ========================================
# Negative Tests - Invalid Paths
# ========================================

echo ""
echo "--- Negative Tests: Invalid Paths (Should Reject) ---"
echo ""

# Test 6: Absolute path rejection
echo "Test 6: Reject absolute paths"
create_valid_plan "$TEST_DIR/absolute.md"
if ! test_path_validation "/tmp/absolute.md"; then
    pass "Rejects absolute path"
else
    fail "Absolute path rejection" "rejected" "accepted"
fi

# Test 7: Path with spaces
echo ""
echo "Test 7: Reject paths with spaces"
mkdir -p "$TEST_DIR/path with spaces"
create_valid_plan "$TEST_DIR/path with spaces/plan.md"
if ! test_path_validation "path with spaces/plan.md"; then
    pass "Rejects path with spaces"
else
    fail "Spaces in path" "rejected" "accepted"
fi

# Test 8: Path with semicolon (command injection)
echo ""
echo "Test 8: Reject paths with semicolon"
if ! test_path_validation "plan;rm.md"; then
    pass "Rejects semicolon in path"
else
    fail "Semicolon rejection" "rejected" "accepted"
fi

# Test 9: Path with pipe
echo ""
echo "Test 9: Reject paths with pipe"
if ! test_path_validation "plan|cat.md"; then
    pass "Rejects pipe in path"
else
    fail "Pipe rejection" "rejected" "accepted"
fi

# Test 10: Path with dollar sign
echo ""
echo "Test 10: Reject paths with dollar sign"
if ! test_path_validation 'plan$HOME.md'; then
    pass "Rejects dollar sign in path"
else
    fail "Dollar sign rejection" "rejected" "accepted"
fi

# Test 11: Path with backticks
echo ""
echo "Test 11: Reject paths with backticks"
if ! test_path_validation 'plan`id`.md'; then
    pass "Rejects backticks in path"
else
    fail "Backticks rejection" "rejected" "accepted"
fi

# Test 12: Path with angle brackets
echo ""
echo "Test 12: Reject paths with angle brackets"
if ! test_path_validation "plan<in>.md"; then
    pass "Rejects angle brackets in path"
else
    fail "Angle brackets rejection" "rejected" "accepted"
fi

# Test 13: Path with ampersand
echo ""
echo "Test 13: Reject paths with ampersand"
if ! test_path_validation "plan&bg.md"; then
    pass "Rejects ampersand in path"
else
    fail "Ampersand rejection" "rejected" "accepted"
fi

# Test 14: Path with asterisk (glob)
echo ""
echo "Test 14: Reject paths with asterisk"
if ! test_path_validation "plan*.md"; then
    pass "Rejects asterisk in path"
else
    fail "Asterisk rejection" "rejected" "accepted"
fi

# Test 15: Path with question mark
echo ""
echo "Test 15: Reject paths with question mark"
if ! test_path_validation "plan?.md"; then
    pass "Rejects question mark in path"
else
    fail "Question mark rejection" "rejected" "accepted"
fi

# Test 16: Path with backslash
echo ""
echo "Test 16: Reject paths with backslash"
if ! test_path_validation 'plan\n.md'; then
    pass "Rejects backslash in path"
else
    fail "Backslash rejection" "rejected" "accepted"
fi

# Test 17: Path with tilde
echo ""
echo "Test 17: Reject paths with tilde"
if ! test_path_validation "~user/plan.md"; then
    pass "Rejects tilde in path"
else
    fail "Tilde rejection" "rejected" "accepted"
fi

# Test 18: Path with parentheses
echo ""
echo "Test 18: Reject paths with parentheses"
if ! test_path_validation "plan(copy).md"; then
    pass "Rejects parentheses in path"
else
    fail "Parentheses rejection" "rejected" "accepted"
fi

# Test 19: Path with curly braces
echo ""
echo "Test 19: Reject paths with curly braces"
if ! test_path_validation "plan{1,2}.md"; then
    pass "Rejects curly braces in path"
else
    fail "Curly braces rejection" "rejected" "accepted"
fi

# Test 20: Path with square brackets
echo ""
echo "Test 20: Reject paths with square brackets"
if ! test_path_validation "plan[1].md"; then
    pass "Rejects square brackets in path"
else
    fail "Square brackets rejection" "rejected" "accepted"
fi

# Test 21: Path with hash
echo ""
echo "Test 21: Reject paths with hash"
if ! test_path_validation "plan#1.md"; then
    pass "Rejects hash in path"
else
    fail "Hash rejection" "rejected" "accepted"
fi

# Test 22: Path with exclamation mark
echo ""
echo "Test 22: Reject paths with exclamation mark"
if ! test_path_validation "plan!.md"; then
    pass "Rejects exclamation mark in path"
else
    fail "Exclamation rejection" "rejected" "accepted"
fi

# ========================================
# Symlink Tests
# ========================================

echo ""
echo "--- Symlink Tests ---"
echo ""

# Test 23: Reject symlink as plan file
echo "Test 23: Reject symlink as plan file"
create_valid_plan "$TEST_DIR/real-plan.md"
ln -s "$TEST_DIR/real-plan.md" "$TEST_DIR/symlink-plan.md"
if ! test_path_validation "symlink-plan.md"; then
    pass "Rejects symlink as plan file"
else
    fail "Symlink rejection" "rejected" "accepted"
fi

# Test 24: Parent directory symlink rejection
echo ""
echo "Test 24: Reject parent directory symlink"
mkdir -p "$TEST_DIR/real-dir"
create_valid_plan "$TEST_DIR/real-dir/plan.md"
ln -s "$TEST_DIR/real-dir" "$TEST_DIR/linked-dir"

# Parent directory symlinks must be rejected (security requirement)
# This prevents symlink-based path traversal attacks
if ! test_path_validation "linked-dir/plan.md"; then
    pass "Rejects parent directory symlink"
else
    fail "Parent symlink rejection" "rejected" "accepted"
fi

# Test 24a: Symlink chain detection (symlink to symlink to file)
echo ""
echo "Test 24a: Symlink chain A->B->C rejected"
ln -s "$TEST_DIR/real-dir/plan.md" "$TEST_DIR/link-b.md"
ln -s "$TEST_DIR/link-b.md" "$TEST_DIR/link-a.md"
# Both link-a.md and link-b.md are symlinks, so -L check will catch them
if ! test_path_validation "link-a.md"; then
    pass "Symlink chain rejected (file is symlink)"
else
    fail "Symlink chain rejection" "rejected" "accepted"
fi

# ========================================
# Long Path Tests
# ========================================

echo ""
echo "--- Long Path Tests ---"
echo ""

# Test 25: Long filename (255 chars)
echo "Test 25: Long filename handling"
LONG_NAME=$(printf 'x%.0s' {1..250}).md
create_valid_plan "$TEST_DIR/$LONG_NAME"
# This should work unless filesystem rejects it
if [[ -f "$TEST_DIR/$LONG_NAME" ]]; then
    if test_path_validation "$LONG_NAME"; then
        pass "Long filename accepted (${#LONG_NAME} chars)"
    else
        fail "Long filename" "accepted" "rejected"
    fi
else
    pass "Long filename test skipped (filesystem rejected)"
fi

# Test 26: Deep nested path
echo ""
echo "Test 26: Deep nested path (10 levels)"
DEEP_PATH="a/b/c/d/e/f/g/h/i/j"
mkdir -p "$TEST_DIR/$DEEP_PATH"
create_valid_plan "$TEST_DIR/$DEEP_PATH/plan.md"
if test_path_validation "$DEEP_PATH/plan.md"; then
    pass "Deep nested path accepted"
else
    fail "Deep nested path" "accepted" "rejected"
fi

# Note: Unicode/CJK/Emoji characters in paths are now ALLOWED
# User content (plan files) can use any language and characters

# ========================================
# File Content Validation Tests
# ========================================

echo ""
echo "--- Content Validation Tests ---"
echo ""

# Test 27: Empty file rejection
echo "Test 27: Reject empty plan file"
touch "$TEST_DIR/empty.md"
if ! test_path_validation "empty.md"; then
    pass "Rejects empty plan file"
else
    fail "Empty file rejection" "rejected" "accepted"
fi

# Test 28: File with only comments
echo ""
echo "Test 28: Reject file with only comments"
cat > "$TEST_DIR/comments-only.md" << 'EOF'
<!-- Comment 1 -->
# This is a comment line
# Another comment
<!-- More comments -->
# Final comment
EOF
if ! test_path_validation "comments-only.md"; then
    pass "Rejects file with only comments"
else
    fail "Comments-only rejection" "rejected" "accepted"
fi

# Test 29: File with insufficient lines
echo ""
echo "Test 29: Reject file with <5 lines"
cat > "$TEST_DIR/short.md" << 'EOF'
Line 1
Line 2
EOF
if ! test_path_validation "short.md"; then
    pass "Rejects file with <5 lines"
else
    fail "Short file rejection" "rejected" "accepted"
fi

# Test 30: Non-existent file
echo ""
echo "Test 30: Reject non-existent file"
if ! test_path_validation "nonexistent.md"; then
    pass "Rejects non-existent file"
else
    fail "Non-existent file rejection" "rejected" "accepted"
fi

# Test 31: Directory instead of file
echo ""
echo "Test 31: Reject directory instead of file"
mkdir -p "$TEST_DIR/not-a-file.md"
if ! test_path_validation "not-a-file.md"; then
    pass "Rejects directory as plan file"
else
    fail "Directory rejection" "rejected" "accepted"
fi

# ========================================
# Summary
# ========================================

print_test_summary "Path Validation Robustness Test Summary"
exit $?
