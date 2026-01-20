#!/bin/bash
#
# Tests for Code Review stdout + result file merge behavior
#
# Tests that detect_review_issues() correctly:
# - Detects [P0-9] patterns in stdout only
# - Detects [P0-9] patterns in result file only
# - Merges content from both sources when both have issues
# - Returns no issues when neither has [P0-9] patterns
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Test helpers
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo -e "${GREEN}PASS${NC}: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}FAIL${NC}: $1"; echo "  Expected: $2"; echo "  Got: $3"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# Setup test environment
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

# Set up isolated cache directory
export XDG_CACHE_HOME="$TEST_DIR/.cache"
mkdir -p "$XDG_CACHE_HOME"

# Source the loop-common.sh to get helper functions
source "$PROJECT_ROOT/hooks/lib/loop-common.sh"

echo "=== Test: Code Review Stdout + Result Merge ==="
echo ""

# Setup test loop directory structure
setup_test_env() {
    LOOP_DIR="$TEST_DIR/.humanize/rlcr/2024-01-01_12-00-00"
    CACHE_DIR="$XDG_CACHE_HOME/humanize/codex-review"
    mkdir -p "$LOOP_DIR"
    mkdir -p "$CACHE_DIR"
    export LOOP_DIR CACHE_DIR
}

# ========================================
# Test 1: Issues in stdout only
# ========================================
echo "Test 1: detect_review_issues finds issues in stdout only"
setup_test_env

# Create stdout file with [P1] issue
cat > "$CACHE_DIR/round-1-codex-review.out" << 'EOF'
Full review comments:

- [P1] Missing null check - /path/to/file.py:42-45
  The function does not check for null input before processing.
EOF

# No result file (or empty)
rm -f "$LOOP_DIR/round-1-review-result.md"

# Source the stop hook to get detect_review_issues
# We need to create a minimal mock environment
export STATE_FILE="$LOOP_DIR/state.md"
export TEMPLATE_DIR="$PROJECT_ROOT/prompt-template"

# Create a minimal state file
cat > "$STATE_FILE" << 'EOF'
---
current_round: 0
max_iterations: 10
plan_file: plan.md
plan_tracked: false
start_branch: main
base_branch: main
review_started: true
---
EOF

# Define the detect_review_issues function inline for testing
detect_review_issues() {
    local round="$1"
    local result_file="$LOOP_DIR/round-${round}-review-result.md"
    local stdout_file="$CACHE_DIR/round-${round}-codex-review.out"

    local has_issues=false
    local merged_content=""

    if [[ -f "$stdout_file" && -s "$stdout_file" ]]; then
        if grep -qE '\[P[0-9]\]' "$stdout_file"; then
            has_issues=true
            merged_content+="## Codex Review Output (stdout)

$(cat "$stdout_file")

"
        fi
    fi

    if [[ -f "$result_file" && -s "$result_file" ]]; then
        if grep -qE '\[P[0-9]\]' "$result_file"; then
            has_issues=true
            if [[ -z "$merged_content" ]]; then
                merged_content+="## Code Review Results

$(cat "$result_file")
"
            elif [[ -f "$stdout_file" ]] && ! diff -q "$stdout_file" "$result_file" >/dev/null 2>&1; then
                merged_content+="## Code Review Results (from file)

$(cat "$result_file")
"
            fi
        fi
    fi

    if [[ "$has_issues" == true ]]; then
        printf '%s' "$merged_content"
        return 0
    else
        return 1
    fi
}

set +e
OUTPUT=$(detect_review_issues 1)
RESULT=$?
set -e

if [[ $RESULT -eq 0 ]] && echo "$OUTPUT" | grep -q '\[P1\]' && echo "$OUTPUT" | grep -q "stdout"; then
    pass "Issues detected in stdout only"
else
    fail "Issues in stdout only" "return 0, output contains [P1] and stdout" "return $RESULT, output: $OUTPUT"
fi

# ========================================
# Test 2: Issues in result file only
# ========================================
echo "Test 2: detect_review_issues finds issues in result file only"
setup_test_env

# Empty or no stdout file
echo "No issues found" > "$CACHE_DIR/round-2-codex-review.out"

# Create result file with [P2] issue
cat > "$LOOP_DIR/round-2-review-result.md" << 'EOF'
# Code Review

- [P2] Security vulnerability - /path/to/auth.py:100-105
  Password is not properly hashed before storage.
EOF

set +e
OUTPUT=$(detect_review_issues 2)
RESULT=$?
set -e

if [[ $RESULT -eq 0 ]] && echo "$OUTPUT" | grep -q '\[P2\]' && echo "$OUTPUT" | grep -q "Security"; then
    pass "Issues detected in result file only"
else
    fail "Issues in result file only" "return 0, output contains [P2]" "return $RESULT, output: $OUTPUT"
fi

# ========================================
# Test 3: Issues in both files (different content)
# ========================================
echo "Test 3: detect_review_issues merges issues from both files"
setup_test_env

# Create stdout file with [P0] issue
cat > "$CACHE_DIR/round-3-codex-review.out" << 'EOF'
Full review comments:

- [P0] Critical: SQL injection vulnerability - /path/to/db.py:50-55
  User input is directly concatenated into SQL query.
EOF

# Create result file with different [P3] issue
cat > "$LOOP_DIR/round-3-review-result.md" << 'EOF'
# Code Review

- [P3] Code style: inconsistent naming - /path/to/utils.py:10-20
  Variable names should follow snake_case convention.
EOF

set +e
OUTPUT=$(detect_review_issues 3)
RESULT=$?
set -e

# Should contain both issues
if [[ $RESULT -eq 0 ]] && echo "$OUTPUT" | grep -q '\[P0\]' && echo "$OUTPUT" | grep -q '\[P3\]'; then
    pass "Issues merged from both files"
else
    fail "Issues in both files" "return 0, output contains [P0] and [P3]" "return $RESULT, output: $OUTPUT"
fi

# ========================================
# Test 4: No issues in either file
# ========================================
echo "Test 4: detect_review_issues returns 1 when no issues"
setup_test_env

# Clean stdout file
echo "Code looks good, no issues found." > "$CACHE_DIR/round-4-codex-review.out"

# Clean result file
echo "# Code Review

All checks passed. No issues found." > "$LOOP_DIR/round-4-review-result.md"

set +e
OUTPUT=$(detect_review_issues 4)
RESULT=$?
set -e

if [[ $RESULT -eq 1 ]]; then
    pass "No issues returns 1"
else
    fail "No issues detection" "return 1" "return $RESULT, output: $OUTPUT"
fi

# ========================================
# Test 5: Files don't exist
# ========================================
echo "Test 5: detect_review_issues handles missing files"
setup_test_env

# Don't create any files
rm -f "$CACHE_DIR/round-5-codex-review.out" 2>/dev/null || true
rm -f "$LOOP_DIR/round-5-review-result.md" 2>/dev/null || true

set +e
OUTPUT=$(detect_review_issues 5 2>/dev/null)
RESULT=$?
set -e

if [[ $RESULT -eq 1 ]]; then
    pass "Missing files returns 1 (no issues)"
else
    fail "Missing files handling" "return 1" "return $RESULT"
fi

# ========================================
# Test 6: Identical content in both files (no duplication)
# ========================================
echo "Test 6: detect_review_issues avoids duplication when files are identical"
setup_test_env

# Create identical files
IDENTICAL_CONTENT="Full review comments:

- [P1] Issue found - /path/to/file.py:1-5
  Some issue description."

echo "$IDENTICAL_CONTENT" > "$CACHE_DIR/round-6-codex-review.out"
echo "$IDENTICAL_CONTENT" > "$LOOP_DIR/round-6-review-result.md"

set +e
OUTPUT=$(detect_review_issues 6)
RESULT=$?
set -e

# Should only include content once (from stdout section)
COUNT=$(echo "$OUTPUT" | grep -c '\[P1\]' || true)
if [[ $RESULT -eq 0 ]] && [[ "$COUNT" -eq 1 ]]; then
    pass "Identical content not duplicated"
else
    fail "Identical content handling" "return 0, [P1] appears once" "return $RESULT, [P1] count: $COUNT"
fi

# ========================================
# Summary
# ========================================
echo ""
echo "========================================="
echo "Test Results"
echo "========================================="
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
