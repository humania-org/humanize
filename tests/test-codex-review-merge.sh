#!/bin/bash
#
# Tests for Code Review log file analysis behavior
#
# Tests that detect_review_issues() correctly:
# - Detects [P0-9] patterns in first 10 characters of each line
# - Scans the ENTIRE log file (not just last N lines)
# - Extracts content from the first matching line to the end
# - Returns appropriate exit codes
#
# Algorithm being tested:
# 1. Scan the entire log file from line 1
# 2. Find the first line where [P?] (? is a digit) appears in the first 10 characters
# 3. If found: extract from that line to the end and output it
# 4. If not found: no issues, return 1
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

# Source the loop-common.sh which contains detect_review_issues
source "$PROJECT_ROOT/hooks/lib/loop-common.sh"

echo "=== Test: Code Review Log File Analysis ==="
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
# Test 1: [P?] in first 10 chars - should detect
# ========================================
echo "Test 1: detect_review_issues finds [P?] in first 10 characters"
setup_test_env

cat > "$CACHE_DIR/round-1-codex-review.log" << 'EOF'
Some debug output from codex
More debug lines
thinking about the code
- [P1] Missing null check - /path/to/file.py:42-45
  The function does not check for null input before processing.
- [P2] Another issue - /path/to/other.py:10-15
  Description of the issue.
EOF

set +e
OUTPUT=$(detect_review_issues 1 2>/dev/null)
RESULT=$?
set -e

if [[ $RESULT -eq 0 ]] && echo "$OUTPUT" | grep -q '\[P1\]' && echo "$OUTPUT" | grep -q '\[P2\]'; then
    pass "Issues detected with [P?] in first 10 chars"
else
    fail "Issues in first 10 chars" "return 0, output contains [P1] and [P2]" "return $RESULT, output: $OUTPUT"
fi

# ========================================
# Test 2: [P?] NOT in first 10 chars - should NOT detect
# ========================================
echo "Test 2: detect_review_issues ignores [P?] not in first 10 characters"
setup_test_env

cat > "$CACHE_DIR/round-2-codex-review.log" << 'EOF'
Some debug output from codex
More debug lines
This line has [P1] but not in first 10 chars - should be ignored
Another line mentioning [P2] somewhere in the middle
Final line of output
EOF

set +e
OUTPUT=$(detect_review_issues 2 2>/dev/null)
RESULT=$?
set -e

# [P?] is not in first 10 chars, so should return 1 (no issues found)
if [[ $RESULT -eq 1 ]]; then
    pass "[P?] not in first 10 chars returns 1 (no issues)"
else
    fail "[P?] position check" "return 1 (no issues)" "return $RESULT, output: $OUTPUT"
fi

# ========================================
# Test 3: No [P?] at all - should return 1
# ========================================
echo "Test 3: detect_review_issues returns 1 when no [P?] patterns"
setup_test_env

cat > "$CACHE_DIR/round-3-codex-review.log" << 'EOF'
Code review complete
No issues found
All checks passed
The code looks good
EOF

set +e
OUTPUT=$(detect_review_issues 3 2>/dev/null)
RESULT=$?
set -e

if [[ $RESULT -eq 1 ]]; then
    pass "No [P?] returns 1"
else
    fail "No issues detection" "return 1" "return $RESULT, output: $OUTPUT"
fi

# ========================================
# Test 4: Missing log file - should return 2
# ========================================
echo "Test 4: detect_review_issues returns error code 2 when log file is missing"
setup_test_env

rm -f "$CACHE_DIR/round-4-codex-review.log" 2>/dev/null || true

set +e
OUTPUT=$(detect_review_issues 4 2>/dev/null)
RESULT=$?
set -e

if [[ $RESULT -eq 2 ]]; then
    pass "Missing log file returns 2 (hard error)"
else
    fail "Missing log file handling" "return 2 (hard error)" "return $RESULT"
fi

# ========================================
# Test 5: Empty log file - should return 2
# ========================================
echo "Test 5: detect_review_issues returns error code 2 when log file is empty"
setup_test_env

touch "$CACHE_DIR/round-5-codex-review.log"

set +e
OUTPUT=$(detect_review_issues 5 2>/dev/null)
RESULT=$?
set -e

if [[ $RESULT -eq 2 ]]; then
    pass "Empty log file returns 2 (hard error)"
else
    fail "Empty log file handling" "return 2 (hard error)" "return $RESULT"
fi

# ========================================
# Test 6: Log file with >50 lines, [P?] late in file
# ========================================
echo "Test 6: detect_review_issues finds [P?] late in a long log"
setup_test_env

# Create a log file with 60 lines, [P1] at line 55
{
    for i in $(seq 1 54); do
        echo "Debug line $i - some processing output"
    done
    echo "- [P1] Bug found in the code - /path/to/file.py:100"
    for i in $(seq 56 60); do
        echo "More output line $i"
    done
} > "$CACHE_DIR/round-6-codex-review.log"

set +e
OUTPUT=$(detect_review_issues 6 2>/dev/null)
RESULT=$?
set -e

if [[ $RESULT -eq 0 ]] && echo "$OUTPUT" | grep -q '\[P1\]'; then
    pass "[P?] found late in long log"
else
    fail "[P?] late in long log" "return 0, output contains [P1]" "return $RESULT, output: $OUTPUT"
fi

# ========================================
# Test 7: Log file with >50 lines, [P?] early in file - should detect
# ========================================
echo "Test 7: detect_review_issues finds [P?] early in a long log (full file scan)"
setup_test_env

# Create a log file with 70 lines, [P1] at line 5 (early in the file)
# This tests that we scan the full file, not just the last N lines
{
    for i in $(seq 1 4); do
        echo "Debug line $i"
    done
    echo "- [P1] This is early in the file - /path/to/file.py:1"
    for i in $(seq 6 70); do
        echo "More output line $i - no issues here"
    done
} > "$CACHE_DIR/round-7-codex-review.log"

set +e
OUTPUT=$(detect_review_issues 7 2>/dev/null)
RESULT=$?
set -e

# [P1] is at line 5 - full file scan should find it
if [[ $RESULT -eq 0 ]] && echo "$OUTPUT" | grep -q '\[P1\]'; then
    pass "[P?] early in file detected (full scan)"
else
    fail "[P?] early in file" "return 0, output contains [P1]" "return $RESULT, output: $OUTPUT"
fi

# ========================================
# Test 8: Multiple [P?] lines - first one is the start of extraction
# ========================================
echo "Test 8: detect_review_issues extracts from first [P?] line to end"
setup_test_env

cat > "$CACHE_DIR/round-8-codex-review.log" << 'EOF'
Debug output line 1
Debug output line 2
- [P0] Critical issue - /path/to/critical.py:10
  This is a critical bug.
- [P2] Minor issue - /path/to/minor.py:20
  This is a minor issue.
Final debug line
EOF

set +e
OUTPUT=$(detect_review_issues 8 2>/dev/null)
RESULT=$?
set -e

# Should extract from [P0] line to the end, including [P2] and final line
if [[ $RESULT -eq 0 ]] && echo "$OUTPUT" | grep -q '\[P0\]' && echo "$OUTPUT" | grep -q '\[P2\]' && echo "$OUTPUT" | grep -q "Final debug"; then
    pass "Extraction from first [P?] to end works"
else
    fail "Multi-issue extraction" "return 0, contains [P0], [P2], and final line" "return $RESULT, output: $OUTPUT"
fi

# ========================================
# Test 9: [P?] exactly at position 0 (first char)
# ========================================
echo "Test 9: detect_review_issues finds [P?] at very start of line"
setup_test_env

cat > "$CACHE_DIR/round-9-codex-review.log" << 'EOF'
Debug output
[P3] Issue at start of line - /path/to/file.py:5
  Description of the issue.
EOF

set +e
OUTPUT=$(detect_review_issues 9 2>/dev/null)
RESULT=$?
set -e

if [[ $RESULT -eq 0 ]] && echo "$OUTPUT" | grep -q '\[P3\]'; then
    pass "[P?] at position 0 detected"
else
    fail "[P?] at position 0" "return 0, output contains [P3]" "return $RESULT, output: $OUTPUT"
fi

# ========================================
# Test 10: [P?] with dash prefix (common format)
# ========================================
echo "Test 10: detect_review_issues finds [P?] with dash prefix"
setup_test_env

cat > "$CACHE_DIR/round-10-codex-review.log" << 'EOF'
Review started
Analyzing files...
- [P1] Security vulnerability - /path/to/auth.py:50
  Password stored in plain text.
EOF

set +e
OUTPUT=$(detect_review_issues 10 2>/dev/null)
RESULT=$?
set -e

# "- [P1]" - the [P1] starts at position 2, which is within first 10 chars
if [[ $RESULT -eq 0 ]] && echo "$OUTPUT" | grep -q '\[P1\]'; then
    pass "[P?] with dash prefix detected"
else
    fail "[P?] with dash prefix" "return 0, output contains [P1]" "return $RESULT, output: $OUTPUT"
fi

# ========================================
# Test 11: Result file is created when issues found
# ========================================
echo "Test 11: detect_review_issues creates result file when issues found"
setup_test_env

cat > "$CACHE_DIR/round-11-codex-review.log" << 'EOF'
Debug line
- [P2] Test issue - /file.py:1
  Issue description
EOF

# Ensure result file doesn't exist
rm -f "$LOOP_DIR/round-11-review-result.md" 2>/dev/null || true

set +e
OUTPUT=$(detect_review_issues 11 2>/dev/null)
RESULT=$?
set -e

# Check that result file was created
if [[ $RESULT -eq 0 ]] && [[ -f "$LOOP_DIR/round-11-review-result.md" ]]; then
    pass "Result file created when issues found"
else
    fail "Result file creation" "return 0, result file exists" "return $RESULT, file exists: $(test -f "$LOOP_DIR/round-11-review-result.md" && echo yes || echo no)"
fi

# ========================================
# Test 12: Exactly 50 lines, [P?] on line 1
# ========================================
echo "Test 12: detect_review_issues handles exactly 50 lines"
setup_test_env

{
    echo "- [P1] First line issue - /file.py:1"
    for i in $(seq 2 50); do
        echo "Line $i content"
    done
} > "$CACHE_DIR/round-12-codex-review.log"

set +e
OUTPUT=$(detect_review_issues 12 2>/dev/null)
RESULT=$?
set -e

if [[ $RESULT -eq 0 ]] && echo "$OUTPUT" | grep -q '\[P1\]'; then
    pass "Exactly 50 lines handled correctly"
else
    fail "Exactly 50 lines" "return 0, output contains [P1]" "return $RESULT, output: $OUTPUT"
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
