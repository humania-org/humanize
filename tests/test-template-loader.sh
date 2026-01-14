#!/bin/bash
#
# Test script for template-loader.sh
#
# Run this script to verify template loading and rendering functions work correctly.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_ROOT/hooks/lib/template-loader.sh"

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
    echo "  Expected: $2"
    echo "  Got: $3"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

echo "========================================"
echo "Testing template-loader.sh"
echo "========================================"
echo ""

# ========================================
# Test 1: get_template_dir
# ========================================
echo "Test 1: get_template_dir"
TEMPLATE_DIR=$(get_template_dir "$PROJECT_ROOT/hooks/lib")
EXPECTED_DIR="$PROJECT_ROOT/prompt-template"

if [[ "$TEMPLATE_DIR" == "$EXPECTED_DIR" ]]; then
    pass "get_template_dir returns correct path"
else
    fail "get_template_dir returns wrong path" "$EXPECTED_DIR" "$TEMPLATE_DIR"
fi

# ========================================
# Test 2: load_template - existing file
# ========================================
echo ""
echo "Test 2: load_template - existing file"
CONTENT=$(load_template "$TEMPLATE_DIR" "block/git-push.md")

if [[ -n "$CONTENT" ]] && echo "$CONTENT" | grep -q "Git Push Blocked"; then
    pass "load_template loads existing file correctly"
else
    fail "load_template failed to load existing file" "Content containing 'Git Push Blocked'" "$CONTENT"
fi

# ========================================
# Test 3: load_template - non-existing file
# ========================================
echo ""
echo "Test 3: load_template - non-existing file"
CONTENT=$(load_template "$TEMPLATE_DIR" "non-existing-file.md" 2>/dev/null)

if [[ -z "$CONTENT" ]]; then
    pass "load_template returns empty for non-existing file"
else
    fail "load_template should return empty for non-existing file" "(empty)" "$CONTENT"
fi

# ========================================
# Test 4: render_template - single variable
# ========================================
echo ""
echo "Test 4: render_template - single variable"
TEMPLATE="Hello {{NAME}}, welcome!"
RESULT=$(render_template "$TEMPLATE" "NAME=World")
EXPECTED="Hello World, welcome!"

if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass "render_template replaces single variable"
else
    fail "render_template single variable replacement" "$EXPECTED" "$RESULT"
fi

# ========================================
# Test 5: render_template - multiple variables
# ========================================
echo ""
echo "Test 5: render_template - multiple variables"
TEMPLATE="Round {{ROUND}}: {{STATUS}} - Path: {{PATH}}"
RESULT=$(render_template "$TEMPLATE" "ROUND=5" "STATUS=complete" "PATH=/tmp/test")
EXPECTED="Round 5: complete - Path: /tmp/test"

if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass "render_template replaces multiple variables"
else
    fail "render_template multiple variable replacement" "$EXPECTED" "$RESULT"
fi

# ========================================
# Test 6: render_template - multiline content
# ========================================
echo ""
echo "Test 6: render_template - multiline content"
TEMPLATE="# Header
Line 1: {{VAR1}}
Line 2: {{VAR2}}
End"
RESULT=$(render_template "$TEMPLATE" "VAR1=value1" "VAR2=value2")
EXPECTED="# Header
Line 1: value1
Line 2: value2
End"

if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass "render_template handles multiline content"
else
    fail "render_template multiline handling" "$EXPECTED" "$RESULT"
fi

# ========================================
# Test 7: render_template - special characters in value
# ========================================
echo ""
echo "Test 7: render_template - special characters in value"
TEMPLATE="Path: {{PATH}}"
RESULT=$(render_template "$TEMPLATE" "PATH=/home/user/test-file.md")
EXPECTED="Path: /home/user/test-file.md"

if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass "render_template handles special characters in values"
else
    fail "render_template special characters" "$EXPECTED" "$RESULT"
fi

# ========================================
# Test 8: load_and_render - integration test
# ========================================
echo ""
echo "Test 8: load_and_render - integration test"
RESULT=$(load_and_render "$TEMPLATE_DIR" "block/wrong-round-number.md" \
    "ACTION=edit" \
    "CLAUDE_ROUND=3" \
    "FILE_TYPE=summary" \
    "CURRENT_ROUND=5" \
    "CORRECT_PATH=/tmp/round-5-summary.md")

if echo "$RESULT" | grep -q "Wrong Round Number" && \
   echo "$RESULT" | grep -q "round-3-summary.md" && \
   echo "$RESULT" | grep -q "current round is \*\*5\*\*"; then
    pass "load_and_render works correctly with real template"
else
    fail "load_and_render integration test" "Content with replaced variables" "$RESULT"
fi

# ========================================
# Test 9: render_template - variable not in template (should be no-op)
# ========================================
echo ""
echo "Test 9: render_template - unused variable"
TEMPLATE="Hello {{NAME}}"
RESULT=$(render_template "$TEMPLATE" "NAME=World" "UNUSED=ignored")
EXPECTED="Hello World"

if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass "render_template ignores unused variables"
else
    fail "render_template unused variable handling" "$EXPECTED" "$RESULT"
fi

# ========================================
# Test 10: render_template - unreplaced variable (stays as-is)
# ========================================
echo ""
echo "Test 10: render_template - unreplaced variable stays as-is"
TEMPLATE="Hello {{NAME}}, your ID is {{ID}}"
RESULT=$(render_template "$TEMPLATE" "NAME=World")
EXPECTED="Hello World, your ID is {{ID}}"

if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass "render_template keeps unreplaced variables"
else
    fail "render_template unreplaced variable" "$EXPECTED" "$RESULT"
fi

# ========================================
# Test 11: load_and_render_safe - missing template uses fallback
# ========================================
echo ""
echo "Test 11: load_and_render_safe - missing template uses fallback"
FALLBACK="Fallback message: {{VAR}}"
RESULT=$(load_and_render_safe "$TEMPLATE_DIR" "non-existing.md" "$FALLBACK" "VAR=test_value")

if echo "$RESULT" | grep -q "Fallback message: test_value"; then
    pass "load_and_render_safe uses fallback for missing template"
else
    fail "load_and_render_safe fallback" "Fallback message: test_value" "$RESULT"
fi

# ========================================
# Test 12: load_and_render_safe - existing template works normally
# ========================================
echo ""
echo "Test 12: load_and_render_safe - existing template works normally"
FALLBACK="This should not appear"
RESULT=$(load_and_render_safe "$TEMPLATE_DIR" "block/git-push.md" "$FALLBACK")

if echo "$RESULT" | grep -q "Git Push Blocked" && ! echo "$RESULT" | grep -q "should not appear"; then
    pass "load_and_render_safe uses template when available"
else
    fail "load_and_render_safe with existing template" "Git Push Blocked (not fallback)" "$RESULT"
fi

# ========================================
# Test 13: validate_template_dir - valid directory
# ========================================
echo ""
echo "Test 13: validate_template_dir - valid directory"
if validate_template_dir "$TEMPLATE_DIR" 2>/dev/null; then
    pass "validate_template_dir accepts valid directory"
else
    fail "validate_template_dir valid" "return 0" "returned non-zero"
fi

# ========================================
# Test 14: validate_template_dir - invalid directory
# ========================================
echo ""
echo "Test 14: validate_template_dir - invalid directory"
if ! validate_template_dir "/non/existing/path" 2>/dev/null; then
    pass "validate_template_dir rejects invalid directory"
else
    fail "validate_template_dir invalid" "return 1" "returned 0"
fi

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
