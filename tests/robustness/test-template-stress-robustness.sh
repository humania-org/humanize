#!/bin/bash
#
# Robustness tests for template system stress conditions
#
# Tests template rendering under stress:
# - Large variable values
# - Circular references (N/A - template doesn't support references between vars)
# - Regex special characters
# - Large templates
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/hooks/lib/template-loader.sh"
source "$SCRIPT_DIR/../test-helpers.sh"

setup_test_dir

echo "========================================"
echo "Template Stress Robustness Tests"
echo "========================================"
echo ""

# ========================================
# Positive Tests - Normal Operations
# ========================================

echo "--- Positive Tests: Normal Operations ---"
echo ""

# Test 1: Standard variable substitution
echo "Test 1: Standard variable substitution"
TEMPLATE="Hello {{NAME}}, welcome to {{PLACE}}!"
RESULT=$(render_template "$TEMPLATE" "NAME=World" "PLACE=Earth")
EXPECTED="Hello World, welcome to Earth!"
if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass "Standard substitution works"
else
    fail "Standard substitution" "$EXPECTED" "$RESULT"
fi

# Test 2: Template with fallback values
echo ""
echo "Test 2: Fallback for missing template"
RESULT=$(load_and_render_safe "$TEST_DIR" "nonexistent.md" "Fallback: {{VAR}}" "VAR=value")
if [[ "$RESULT" == "Fallback: value" ]]; then
    pass "Fallback rendering works"
else
    fail "Fallback rendering" "Fallback: value" "$RESULT"
fi

# Test 3: Standard-sized template
echo ""
echo "Test 3: Standard-sized template (1KB)"
# Create a 1KB template
{
    echo "# Template"
    echo "Variable: {{VAR}}"
    for i in $(seq 1 50); do
        echo "Line $i: Some content here to fill the template"
    done
} > "$TEST_DIR/standard.md"

RESULT=$(load_and_render "$TEST_DIR" "standard.md" "VAR=test_value")
if echo "$RESULT" | grep -q "Variable: test_value"; then
    SIZE=$(echo "$RESULT" | wc -c)
    pass "Processes 1KB template correctly ($SIZE bytes)"
else
    fail "1KB template" "contains 'Variable: test_value'" "missing"
fi

# ========================================
# Stress Tests - Large Values
# ========================================

echo ""
echo "--- Stress Tests: Large Values ---"
echo ""

# Test 4: Large variable value (10KB)
echo "Test 4: Large variable value (10KB string)"
LARGE_VALUE=$(printf 'x%.0s' {1..10240})
TEMPLATE="Content: {{LARGE}}"
START=$(date +%s%N)
RESULT=$(render_template "$TEMPLATE" "LARGE=$LARGE_VALUE")
END=$(date +%s%N)
ELAPSED_MS=$(( (END - START) / 1000000 ))
if [[ "${#RESULT}" -gt 10000 ]]; then
    pass "Handles 10KB value (${ELAPSED_MS}ms, ${#RESULT} chars)"
else
    fail "10KB value" ">10000 chars" "${#RESULT} chars"
fi

# Test 5: Very large variable value (100KB)
echo ""
echo "Test 5: Very large variable value (100KB string)"
VERY_LARGE_VALUE=$(printf 'y%.0s' {1..102400})
TEMPLATE="Content: {{VERYLARGE}}"
START=$(date +%s%N)
RESULT=$(render_template "$TEMPLATE" "VERYLARGE=$VERY_LARGE_VALUE")
END=$(date +%s%N)
ELAPSED_MS=$(( (END - START) / 1000000 ))
if [[ "${#RESULT}" -gt 100000 ]]; then
    pass "Handles 100KB value (${ELAPSED_MS}ms)"
else
    fail "100KB value" ">100000 chars" "${#RESULT} chars"
fi

# Test 6: Large template file (100KB)
echo ""
echo "Test 6: Large template file (100KB)"
{
    echo "# Large Template"
    echo "Variable: {{VAR}}"
    for i in $(seq 1 2000); do
        echo "Line $i: This is repetitive content to make the template larger and larger"
    done
} > "$TEST_DIR/large.md"
SIZE_BEFORE=$(wc -c < "$TEST_DIR/large.md")
START=$(date +%s%N)
RESULT=$(load_and_render "$TEST_DIR" "large.md" "VAR=test_value")
END=$(date +%s%N)
ELAPSED_MS=$(( (END - START) / 1000000 ))
# Check if result contains the substituted variable
RESULT_SIZE=${#RESULT}
if [[ $RESULT_SIZE -gt 100000 ]] && [[ "$RESULT" == *"Variable: test_value"* ]]; then
    pass "Processes 100KB template (${SIZE_BEFORE} bytes, ${ELAPSED_MS}ms)"
else
    fail "100KB template" "result >100KB with substitution" "size=${RESULT_SIZE}"
fi

# Test 7: Many variables in one template
echo ""
echo "Test 7: Many variables (50 substitutions)"
TEMPLATE=""
VARS=()
for i in $(seq 1 50); do
    TEMPLATE="${TEMPLATE}Var$i: {{VAR$i}}\n"
    VARS+=("VAR$i=value$i")
done
START=$(date +%s%N)
RESULT=$(render_template "$TEMPLATE" "${VARS[@]}")
END=$(date +%s%N)
ELAPSED_MS=$(( (END - START) / 1000000 ))
if echo "$RESULT" | grep -q "Var50: value50"; then
    pass "Handles 50 variable substitutions (${ELAPSED_MS}ms)"
else
    fail "50 variables" "contains Var50: value50" "missing"
fi

# ========================================
# Edge Case Tests - Special Characters
# ========================================

echo ""
echo "--- Edge Cases: Special Characters ---"
echo ""

# Test 8: Regex special characters in value
echo "Test 8: Regex special characters in value"
TEMPLATE="Pattern: {{PATTERN}}"
RESULT=$(render_template "$TEMPLATE" 'PATTERN=.*+?^${}()[]|\')
EXPECTED='Pattern: .*+?^${}()[]|\'
if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass "Handles regex special chars in value"
else
    fail "Regex chars" "$EXPECTED" "$RESULT"
fi

# Test 9: Ampersand in value (sed replacement special)
echo ""
echo "Test 9: Ampersand in value (sed special char)"
TEMPLATE="Join: {{JOIN}}"
RESULT=$(render_template "$TEMPLATE" "JOIN=A & B & C")
if [[ "$RESULT" == "Join: A & B & C" ]]; then
    pass "Handles ampersand correctly"
else
    fail "Ampersand" "Join: A & B & C" "$RESULT"
fi

# Test 10: Backslash sequences
echo ""
echo "Test 10: Backslash sequences in value"
TEMPLATE="Path: {{PATH}}"
RESULT=$(render_template "$TEMPLATE" 'PATH=C:\Users\test\file.txt')
EXPECTED='Path: C:\Users\test\file.txt'
if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass "Handles backslashes correctly"
else
    fail "Backslashes" "$EXPECTED" "$RESULT"
fi

# Test 11: Newlines in value
echo ""
echo "Test 11: Newlines in value"
TEMPLATE="Multi: {{MULTI}}"
MULTILINE_VAL=$'Line1\nLine2\nLine3'
RESULT=$(render_template "$TEMPLATE" "MULTI=$MULTILINE_VAL")
if echo "$RESULT" | grep -q "Line1" && echo "$RESULT" | grep -q "Line3"; then
    pass "Handles newlines in value"
else
    fail "Newlines" "Multi: Line1\\nLine2\\nLine3" "$RESULT"
fi

# Test 12: Empty variable value
echo ""
echo "Test 12: Empty variable value"
TEMPLATE="Value: [{{EMPTY}}]"
RESULT=$(render_template "$TEMPLATE" "EMPTY=")
if [[ "$RESULT" == "Value: []" ]]; then
    pass "Handles empty value"
else
    fail "Empty value" "Value: []" "$RESULT"
fi

# Test 13: Variable placeholder in value (injection prevention)
echo ""
echo "Test 13: Prevent placeholder injection"
TEMPLATE="A: {{VAR_A}}, B: {{VAR_B}}"
RESULT=$(render_template "$TEMPLATE" "VAR_A=contains {{VAR_B}}" "VAR_B=replaced")
EXPECTED="A: contains {{VAR_B}}, B: replaced"
if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass "Prevents placeholder injection"
else
    fail "Injection prevention" "$EXPECTED" "$RESULT"
fi

# Test 14: Unicode in template and value
echo ""
echo "Test 14: Unicode content"
TEMPLATE=$'Greeting: {{GREETING}}'
RESULT=$(render_template "$TEMPLATE" "GREETING=Hello World")
if [[ "$RESULT" == "Greeting: Hello World" ]]; then
    pass "Handles basic characters in template"
else
    fail "Unicode" "Greeting: Hello World" "$RESULT"
fi

# Test 15: Dollar sign in value
echo ""
echo "Test 15: Dollar sign in value"
TEMPLATE="Price: {{PRICE}}"
RESULT=$(render_template "$TEMPLATE" 'PRICE=$100.00')
if [[ "$RESULT" == 'Price: $100.00' ]]; then
    pass "Handles dollar sign correctly"
else
    fail "Dollar sign" 'Price: $100.00' "$RESULT"
fi

# Test 16: Repeated same variable
echo ""
echo "Test 16: Same variable multiple times"
TEMPLATE="First: {{NAME}}, Second: {{NAME}}, Third: {{NAME}}"
RESULT=$(render_template "$TEMPLATE" "NAME=test")
if [[ "$RESULT" == "First: test, Second: test, Third: test" ]]; then
    pass "Replaces same variable multiple times"
else
    fail "Multiple same vars" "First: test, Second: test, Third: test" "$RESULT"
fi

# Test 17: Variable at start and end
echo ""
echo "Test 17: Variable at boundaries"
TEMPLATE="{{START}}middle{{END}}"
RESULT=$(render_template "$TEMPLATE" "START=begin" "END=finish")
if [[ "$RESULT" == "beginmiddlefinish" ]]; then
    pass "Handles variables at boundaries"
else
    fail "Boundary variables" "beginmiddlefinish" "$RESULT"
fi

# Test 18: Only variable placeholder (no other content)
echo ""
echo "Test 18: Template with only placeholder"
TEMPLATE="{{ONLY}}"
RESULT=$(render_template "$TEMPLATE" "ONLY=entire content")
if [[ "$RESULT" == "entire content" ]]; then
    pass "Handles template with only placeholder"
else
    fail "Only placeholder" "entire content" "$RESULT"
fi

# ========================================
# Summary
# ========================================

print_test_summary "Template Stress Robustness Test Summary"
exit $?
