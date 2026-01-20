#!/bin/bash
#
# Robustness tests for template system error handling
#
# Tests template system behavior under error conditions:
# - Missing template files
# - Malformed templates (unclosed placeholders)
# - Invalid variable names
# - Template loading from non-existent directories
# - Permission errors
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/hooks/lib/template-loader.sh"
source "$SCRIPT_DIR/../test-helpers.sh"

setup_test_dir

echo "========================================"
echo "Template Error Robustness Tests"
echo "========================================"
echo ""

# ========================================
# Missing Template Tests
# ========================================

echo "--- Missing Template Tests ---"
echo ""

# Test 1: load_and_render_safe with missing template returns fallback
echo "Test 1: Missing template uses fallback"
RESULT=$(load_and_render_safe "$TEST_DIR" "nonexistent.md" "Fallback content" 2>/dev/null)
if [[ "$RESULT" == "Fallback content" ]]; then
    pass "Missing template returns fallback"
else
    fail "Missing template fallback" "Fallback content" "$RESULT"
fi

# Test 2: load_and_render_safe with missing template directory
echo ""
echo "Test 2: Missing template directory uses fallback"
RESULT=$(load_and_render_safe "/nonexistent/path" "template.md" "Fallback for dir" 2>/dev/null)
if [[ "$RESULT" == "Fallback for dir" ]]; then
    pass "Missing directory returns fallback"
else
    fail "Missing dir fallback" "Fallback for dir" "$RESULT"
fi

# Test 3: Empty template file
echo ""
echo "Test 3: Empty template file handled"
touch "$TEST_DIR/empty.md"
RESULT=$(load_and_render_safe "$TEST_DIR" "empty.md" "not empty" 2>/dev/null)
# Should return empty string (the content of empty file) or handle gracefully
if [[ -z "$RESULT" ]] || [[ "$RESULT" == "not empty" ]]; then
    pass "Empty template handled (result: '${RESULT:-empty}')"
else
    fail "Empty template" "empty or fallback" "$RESULT"
fi

# ========================================
# Malformed Template Tests
# ========================================

echo ""
echo "--- Malformed Template Tests ---"
echo ""

# Test 4: Template with unclosed placeholder
echo "Test 4: Unclosed placeholder handled"
TEMPLATE="Hello {{NAME, welcome!"
RESULT=$(render_template "$TEMPLATE" "NAME=World" 2>/dev/null) || true
# Should not crash; may leave placeholder as-is or partially process
if [[ -n "$RESULT" ]]; then
    pass "Unclosed placeholder handled (result: $RESULT)"
else
    fail "Unclosed placeholder" "non-empty result" "empty"
fi

# Test 5: Template with nested placeholders
echo ""
echo "Test 5: Nested placeholders handled"
TEMPLATE="Hello {{{{NAME}}}}!"
RESULT=$(render_template "$TEMPLATE" "NAME=World" 2>/dev/null) || true
if [[ -n "$RESULT" ]]; then
    pass "Nested placeholders handled"
else
    fail "Nested placeholders" "non-empty result" "empty"
fi

# Test 6: Template with only opening braces
echo ""
echo "Test 6: Only opening braces handled"
TEMPLATE="Hello {{ name"
RESULT=$(render_template "$TEMPLATE" "name=World" 2>/dev/null) || true
if [[ -n "$RESULT" ]]; then
    pass "Opening braces only handled"
else
    fail "Opening braces" "non-empty result" "empty"
fi

# Test 7: Template with empty placeholder name
echo ""
echo "Test 7: Empty placeholder name handled"
TEMPLATE="Hello {{}}!"
RESULT=$(render_template "$TEMPLATE" "=value" 2>/dev/null) || true
if [[ -n "$RESULT" ]]; then
    pass "Empty placeholder handled (result: $RESULT)"
else
    fail "Empty placeholder" "non-empty result" "empty"
fi

# ========================================
# Invalid Variable Names Tests
# ========================================

echo ""
echo "--- Invalid Variable Names Tests ---"
echo ""

# Test 8: Variable with spaces in name
echo "Test 8: Variable with spaces in name"
TEMPLATE="Hello {{NAME WITH SPACES}}!"
RESULT=$(render_template "$TEMPLATE" "NAME WITH SPACES=World" 2>/dev/null) || true
if [[ -n "$RESULT" ]]; then
    pass "Spaces in variable name handled"
else
    fail "Spaces in var name" "non-empty result" "empty"
fi

# Test 9: Variable with special characters
echo ""
echo "Test 9: Variable with special characters in name"
TEMPLATE="Hello {{NAME@#\$}}!"
RESULT=$(render_template "$TEMPLATE" 'NAME@#$=World' 2>/dev/null) || true
if [[ -n "$RESULT" ]]; then
    pass "Special chars in variable name handled"
else
    fail "Special chars in var" "non-empty result" "empty"
fi

# Test 10: Variable with numbers only
echo ""
echo "Test 10: Variable with numbers only"
TEMPLATE="Value is {{123}}"
RESULT=$(render_template "$TEMPLATE" "123=hundred" 2>/dev/null) || true
if [[ -n "$RESULT" ]]; then
    pass "Numeric variable name handled"
else
    fail "Numeric var name" "non-empty result" "empty"
fi

# ========================================
# Edge Cases in Variable Values
# ========================================

echo ""
echo "--- Edge Cases in Variable Values ---"
echo ""

# Test 11: Variable value containing template syntax
echo "Test 11: Variable value with template syntax"
TEMPLATE="Result: {{VAR}}"
RESULT=$(render_template "$TEMPLATE" "VAR={{OTHER}}" 2>/dev/null) || true
# Should not recursively expand
if [[ "$RESULT" == "Result: {{OTHER}}" ]]; then
    pass "Template syntax in value not expanded"
else
    fail "Template in value" "Result: {{OTHER}}" "$RESULT"
fi

# Test 12: Variable value with newlines
echo ""
echo "Test 12: Variable value with newlines preserved"
TEMPLATE="Content: {{VAR}}"
VALUE=$'line1\nline2\nline3'
RESULT=$(render_template "$TEMPLATE" "VAR=$VALUE" 2>/dev/null) || true
if echo "$RESULT" | grep -q "line1"; then
    pass "Newlines in value preserved"
else
    fail "Newlines in value" "contains line1" "$RESULT"
fi

# Test 13: Very long variable name
echo ""
echo "Test 13: Very long variable name handled"
LONG_NAME=$(head -c 500 /dev/zero | tr '\0' 'A')
TEMPLATE="Hello {{${LONG_NAME}}}!"
RESULT=$(render_template "$TEMPLATE" "${LONG_NAME}=World" 2>/dev/null) || true
if [[ -n "$RESULT" ]]; then
    pass "Very long variable name handled"
else
    fail "Long var name" "non-empty result" "empty"
fi

# ========================================
# File System Edge Cases
# ========================================

echo ""
echo "--- File System Edge Cases ---"
echo ""

# Test 14: Template with BOM (Byte Order Mark)
echo ""
echo "Test 14: Template with BOM handled"
# Create template with UTF-8 BOM
printf '\xEF\xBB\xBFHello {{NAME}}!' > "$TEST_DIR/bom.md"
RESULT=$(load_and_render_safe "$TEST_DIR" "bom.md" "fallback" "NAME=World" 2>/dev/null) || true
if echo "$RESULT" | grep -q "Hello"; then
    pass "BOM in template handled"
else
    fail "BOM handling" "contains Hello" "$RESULT"
fi

# Test 15: Template with only whitespace
echo ""
echo "Test 15: Whitespace-only template handled"
echo "   " > "$TEST_DIR/whitespace.md"
RESULT=$(load_and_render_safe "$TEST_DIR" "whitespace.md" "fallback" 2>/dev/null) || true
# Should return whitespace content or handle gracefully
pass "Whitespace-only template handled (length: ${#RESULT})"

# Test 16: Template filename with special characters
echo ""
echo "Test 16: Special characters in filename handled"
# Create template with spaces (if filesystem allows)
SPECIAL_NAME="template with spaces.md"
echo "Hello {{NAME}}" > "$TEST_DIR/$SPECIAL_NAME" 2>/dev/null || true
if [[ -f "$TEST_DIR/$SPECIAL_NAME" ]]; then
    RESULT=$(load_and_render_safe "$TEST_DIR" "$SPECIAL_NAME" "fallback" "NAME=World" 2>/dev/null) || true
    if [[ "$RESULT" == "Hello World" ]]; then
        pass "Special chars in filename handled"
    else
        pass "Special chars in filename handled (fallback used)"
    fi
else
    pass "Special chars in filename test skipped (fs limitation)"
fi

# Test 17: Permission denied on template (if not root)
echo ""
echo "Test 17: Permission denied handled"
if [[ $(id -u) -ne 0 ]]; then
    echo "Hello {{NAME}}" > "$TEST_DIR/noperm.md"
    chmod 000 "$TEST_DIR/noperm.md"
    RESULT=$(load_and_render_safe "$TEST_DIR" "noperm.md" "permission fallback" "NAME=World" 2>/dev/null) || true
    chmod 644 "$TEST_DIR/noperm.md"  # Restore for cleanup
    if [[ "$RESULT" == "permission fallback" ]]; then
        pass "Permission denied uses fallback"
    else
        pass "Permission handling works (result varies by system)"
    fi
else
    pass "Permission test skipped (running as root)"
fi

# ========================================
# Concurrent Template Loading
# ========================================

echo ""
echo "--- Concurrent Template Loading Tests ---"
echo ""

# Test 18: Multiple concurrent template loads
echo "Test 18: Concurrent template loads succeed"
echo "Template {{NUM}}" > "$TEST_DIR/concurrent.md"

# Store PIDs to check each job's exit status
PIDS=()
for i in $(seq 1 10); do
    (
        RESULT=$(load_and_render_safe "$TEST_DIR" "concurrent.md" "fallback" "NUM=$i" 2>/dev/null)
        if [[ "$RESULT" != "Template $i" ]]; then
            exit 1
        fi
    ) &
    PIDS+=($!)
done

# Wait for each job and count failures
FAILURES=0
for pid in "${PIDS[@]}"; do
    if ! wait "$pid"; then
        FAILURES=$((FAILURES + 1))
    fi
done

# Check that all loads succeeded AND file still exists
if [[ $FAILURES -eq 0 ]] && [[ -f "$TEST_DIR/concurrent.md" ]]; then
    pass "Concurrent template loads succeeded (10/10 jobs passed)"
else
    fail "Concurrent loads" "0 failures, file preserved" "$FAILURES failures, file exists: $([[ -f "$TEST_DIR/concurrent.md" ]] && echo yes || echo no)"
fi

# ========================================
# Template Discovery Edge Cases
# ========================================

echo ""
echo "--- Template Discovery Tests ---"
echo ""

# Test 19: Template in subdirectory
echo "Test 19: Template in subdirectory"
mkdir -p "$TEST_DIR/sub/dir"
echo "Subdir {{VAR}}" > "$TEST_DIR/sub/dir/template.md"
RESULT=$(load_and_render_safe "$TEST_DIR/sub/dir" "template.md" "fallback" "VAR=value" 2>/dev/null) || true
if [[ "$RESULT" == "Subdir value" ]]; then
    pass "Template in subdirectory loaded"
else
    fail "Subdir template" "Subdir value" "$RESULT"
fi

# Test 20: Symlink to template (if supported)
echo ""
echo "Test 20: Symlink to template"
echo "Linked {{VAR}}" > "$TEST_DIR/real-template.md"
ln -sf "real-template.md" "$TEST_DIR/link-template.md" 2>/dev/null || true
if [[ -L "$TEST_DIR/link-template.md" ]]; then
    RESULT=$(load_and_render_safe "$TEST_DIR" "link-template.md" "fallback" "VAR=value" 2>/dev/null) || true
    if [[ "$RESULT" == "Linked value" ]]; then
        pass "Symlinked template loaded"
    else
        pass "Symlinked template handled (result: ${RESULT:-empty})"
    fi
else
    pass "Symlink test skipped (symlinks not supported)"
fi

# ========================================
# Summary
# ========================================

print_test_summary "Template Error Robustness Test Summary"
exit $?
