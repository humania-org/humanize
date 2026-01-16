#!/bin/bash
#
# Test error scenarios for template-loader.sh
#
# These tests verify that error conditions are handled gracefully
# without crashing or producing unexpected behavior.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_ROOT/hooks/lib/template-loader.sh"

TEMPLATE_DIR=$(get_template_dir "$PROJECT_ROOT/hooks/lib")

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
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

echo "========================================"
echo "Testing Error Scenarios"
echo "========================================"
echo ""

# ========================================
# Test 1: Template file not found returns empty
# ========================================
echo "Test 1: Template file not found returns empty"
CONTENT=$(load_template "$TEMPLATE_DIR" "non-existing-file.md" 2>/dev/null)
EXIT_CODE=$?
if [[ -z "$CONTENT" && $EXIT_CODE -eq 0 ]]; then
    pass "Template not found returns empty string without error"
else
    fail "Template not found handling" "empty string, exit 0" "content='$CONTENT', exit=$EXIT_CODE"
fi

# ========================================
# Test 2: Template directory not found returns empty
# ========================================
echo ""
echo "Test 2: Template directory not found returns empty"
CONTENT=$(load_template "/non/existing/path" "block/git-push.md" 2>/dev/null)
EXIT_CODE=$?
if [[ -z "$CONTENT" && $EXIT_CODE -eq 0 ]]; then
    pass "Directory not found returns empty string without error"
else
    fail "Directory not found handling" "empty string, exit 0" "content='$CONTENT', exit=$EXIT_CODE"
fi

# ========================================
# Test 3: load_and_render with missing template returns empty
# ========================================
echo ""
echo "Test 3: load_and_render with missing template returns empty"
RESULT=$(load_and_render "$TEMPLATE_DIR" "non-existing.md" "VAR=value" 2>/dev/null)
EXIT_CODE=$?
if [[ -z "$RESULT" && $EXIT_CODE -eq 0 ]]; then
    pass "load_and_render with missing template returns empty"
else
    fail "load_and_render missing template" "empty string, exit 0" "result='$RESULT', exit=$EXIT_CODE"
fi

# ========================================
# Test 4: render_template with empty content returns empty
# ========================================
echo ""
echo "Test 4: render_template with empty content returns empty"
RESULT=$(render_template "" "VAR=value")
EXIT_CODE=$?
if [[ -z "$RESULT" && $EXIT_CODE -eq 0 ]]; then
    pass "render_template with empty content returns empty"
else
    fail "render_template empty content" "empty string, exit 0" "result='$RESULT', exit=$EXIT_CODE"
fi

# ========================================
# Test 5: Variable with special regex characters renders correctly
# ========================================
echo ""
echo "Test 5: Variable with special regex characters"
TEMPLATE="Path: {{PATH}}"
SPECIAL_VALUE="/home/user/file.md [test] (foo) *bar*"
RESULT=$(render_template "$TEMPLATE" "PATH=$SPECIAL_VALUE")
EXPECTED="Path: $SPECIAL_VALUE"
if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass "Special regex characters in value render correctly"
else
    fail "Special regex characters" "$EXPECTED" "$RESULT"
fi

# ========================================
# Test 6: Script continues with set -euo pipefail and missing template
# ========================================
echo ""
echo "Test 6: Script continues with set -euo pipefail"
# Run in isolated subshell - use || true to capture output even if subshell fails
SCRIPT_OUTPUT=$(bash -c '
set -euo pipefail
source "'"$PROJECT_ROOT"'/hooks/lib/template-loader.sh"
TEMPLATE_DIR=$(get_template_dir "'"$PROJECT_ROOT"'/hooks/lib")

# Test with missing template
REASON=$(load_and_render "$TEMPLATE_DIR" "non-existing.md" "VAR=value" 2>/dev/null)

if [[ -z "$REASON" ]]; then
    echo "EMPTY_REASON"
fi
echo "SCRIPT_COMPLETED"
' 2>&1) || true
if [[ "$SCRIPT_OUTPUT" == *"SCRIPT_COMPLETED"* ]]; then
    pass "Script continues without crashing under strict mode"
else
    fail "Strict mode handling" "SCRIPT_COMPLETED in output" "output='$SCRIPT_OUTPUT'"
fi

# ========================================
# Test 7: load_and_render_safe with missing template uses fallback
# ========================================
echo ""
echo "Test 7: load_and_render_safe uses fallback for missing template"
FALLBACK="This is the fallback message"
RESULT=$(load_and_render_safe "$TEMPLATE_DIR" "non-existing.md" "$FALLBACK" 2>/dev/null)
if [[ "$RESULT" == "$FALLBACK" ]]; then
    pass "load_and_render_safe uses fallback correctly"
else
    fail "load_and_render_safe fallback" "$FALLBACK" "$RESULT"
fi

# ========================================
# Test 8: load_and_render_safe with fallback containing variables
# ========================================
echo ""
echo "Test 8: load_and_render_safe fallback with variable substitution"
FALLBACK="Error for {{FILE}}: not found"
RESULT=$(load_and_render_safe "$TEMPLATE_DIR" "non-existing.md" "$FALLBACK" "FILE=test.md" 2>/dev/null)
EXPECTED="Error for test.md: not found"
if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass "load_and_render_safe substitutes variables in fallback"
else
    fail "load_and_render_safe fallback substitution" "$EXPECTED" "$RESULT"
fi

# ========================================
# Test 9: validate_template_dir with valid directory returns 0
# ========================================
echo ""
echo "Test 9: validate_template_dir accepts valid directory"
if validate_template_dir "$TEMPLATE_DIR" 2>/dev/null; then
    pass "validate_template_dir accepts valid directory"
else
    fail "validate_template_dir valid" "exit 0" "exit 1"
fi

# ========================================
# Test 10: validate_template_dir with invalid directory returns 1
# ========================================
echo ""
echo "Test 10: validate_template_dir rejects invalid directory"
if ! validate_template_dir "/non/existing/path" 2>/dev/null; then
    pass "validate_template_dir rejects invalid directory"
else
    fail "validate_template_dir invalid" "exit 1" "exit 0"
fi

# ========================================
# Test 11: Empty variable name in template stays as-is
# ========================================
echo ""
echo "Test 11: Empty placeholder {{}} stays as-is"
TEMPLATE="Test: {{}}"
RESULT=$(render_template "$TEMPLATE" "VAR=value")
if [[ "$RESULT" == "Test: {{}}" ]]; then
    pass "Empty placeholder stays unchanged"
else
    fail "Empty placeholder handling" "Test: {{}}" "$RESULT"
fi

# ========================================
# Test 12: Unclosed placeholder {{ stays as-is
# ========================================
echo ""
echo "Test 12: Unclosed placeholder {{ stays as-is"
TEMPLATE="Test: {{UNCLOSED"
RESULT=$(render_template "$TEMPLATE" "UNCLOSED=value")
if [[ "$RESULT" == "Test: {{UNCLOSED" ]]; then
    pass "Unclosed placeholder stays unchanged"
else
    fail "Unclosed placeholder handling" "Test: {{UNCLOSED" "$RESULT"
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
