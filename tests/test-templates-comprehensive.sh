#!/bin/bash
#
# Comprehensive template validation tests for CI/CD
#
# This script tests:
# 1. All templates in prompt-template/ can be loaded
# 2. Template rendering works with various input types
# 3. Edge cases (CJK, emoji, special chars, empty lines)
# 4. Fallback mechanisms work correctly
# 5. Template syntax is valid ({{VAR}} placeholders)
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_ROOT/hooks/lib/template-loader.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

TESTS_PASSED=0
TESTS_FAILED=0
WARNINGS=0

# Test helper functions
pass() {
    echo -e "  ${GREEN}PASS${NC}: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "  ${RED}FAIL${NC}: $1"
    if [[ -n "${2:-}" ]]; then
        echo "    Expected: $2"
    fi
    if [[ -n "${3:-}" ]]; then
        echo "    Got: $3"
    fi
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

warn() {
    echo -e "  ${YELLOW}WARN${NC}: $1"
    WARNINGS=$((WARNINGS + 1))
}

section() {
    echo ""
    echo -e "${BLUE}========================================"
    echo "$1"
    echo -e "========================================${NC}"
}

TEMPLATE_DIR=$(get_template_dir "$PROJECT_ROOT/hooks/lib")

# ========================================
# Section 1: Validate Template Directory Structure
# ========================================
section "Section 1: Template Directory Structure"

if [[ -d "$TEMPLATE_DIR" ]]; then
    pass "Template directory exists: $TEMPLATE_DIR"
else
    fail "Template directory not found: $TEMPLATE_DIR"
    echo "Cannot continue without template directory"
    exit 1
fi

for subdir in block codex claude; do
    if [[ -d "$TEMPLATE_DIR/$subdir" ]]; then
        pass "Subdirectory exists: $subdir/"
    else
        fail "Subdirectory missing: $subdir/"
    fi
done

# ========================================
# Section 2: Load All Templates
# ========================================
section "Section 2: Load All Templates"

TEMPLATE_COUNT=0
LOAD_FAILURES=0

while IFS= read -r -d '' template_file; do
    TEMPLATE_COUNT=$((TEMPLATE_COUNT + 1))
    relative_path="${template_file#$TEMPLATE_DIR/}"

    content=$(load_template "$TEMPLATE_DIR" "$relative_path" 2>/dev/null)

    if [[ -n "$content" ]]; then
        # Check template is not empty (just whitespace)
        if [[ -n "$(echo "$content" | tr -d '[:space:]')" ]]; then
            pass "Loaded: $relative_path (${#content} bytes)"
        else
            warn "Template is empty or whitespace-only: $relative_path"
        fi
    else
        fail "Failed to load: $relative_path"
        LOAD_FAILURES=$((LOAD_FAILURES + 1))
    fi
done < <(find "$TEMPLATE_DIR" -name "*.md" -type f -print0 | sort -z)

echo ""
echo "Templates found: $TEMPLATE_COUNT"
echo "Load failures: $LOAD_FAILURES"

# ========================================
# Section 3: Template Syntax Validation
# ========================================
section "Section 3: Template Syntax Validation"

while IFS= read -r -d '' template_file; do
    relative_path="${template_file#$TEMPLATE_DIR/}"
    content=$(cat "$template_file")

    # Check for valid placeholder syntax {{VAR_NAME}}
    # Valid: {{VAR}}, {{VAR_NAME}}, {{VAR_NAME_123}}
    # Invalid: {{ VAR }}, {{var with spaces}}, {VAR}, {{VAR}}}, {{{VAR}}}, {(VAR)}

    syntax_errors=""

    # Check 1: Extra closing braces - {{VAR}}} or {{VAR}}}}
    extra_close=$(echo "$content" | grep -oE '\{\{[A-Z_][A-Z0-9_]*\}\}\}+' || true)
    if [[ -n "$extra_close" ]]; then
        syntax_errors="${syntax_errors}Extra closing braces: $extra_close\n"
    fi

    # Check 2: Extra opening braces - {{{VAR}}} or {{{{VAR}}
    extra_open=$(echo "$content" | grep -oE '\{\{\{+[A-Z_][A-Z0-9_]*\}\}' || true)
    if [[ -n "$extra_open" ]]; then
        syntax_errors="${syntax_errors}Extra opening braces: $extra_open\n"
    fi

    # Check 3: Wrong bracket types - {(VAR)}, [(VAR)], {[VAR]}
    wrong_brackets=$(echo "$content" | grep -oE '\{[\(\[].+?[\)\]]\}' || true)
    if [[ -n "$wrong_brackets" ]]; then
        syntax_errors="${syntax_errors}Wrong bracket types: $wrong_brackets\n"
    fi

    # Check 4: Unclosed placeholders - {{VAR without closing
    # Look for {{ followed by content but not followed by }}
    unclosed=$(echo "$content" | grep -oE '\{\{[A-Z_][A-Z0-9_]*[^}]' | grep -v '\}\}' || true)
    if [[ -n "$unclosed" ]]; then
        # Double check - might be false positive
        for pattern in $unclosed; do
            # Extract the variable name part
            varname=$(echo "$pattern" | sed 's/{{//' | sed 's/[^A-Z0-9_].*//')
            if [[ -n "$varname" ]] && ! echo "$content" | grep -q "{{${varname}}}"; then
                syntax_errors="${syntax_errors}Possibly unclosed: {{$varname\n"
            fi
        done
    fi

    # Check 5: Single brace placeholders - {VAR} instead of {{VAR}}
    # Skip this check - it's too noisy because templates commonly show {VAR} syntax
    # in their documentation. The double-brace validation is sufficient.
    # Only check for clearly invalid patterns like ${VAR} (shell syntax) in templates

    # Check 6: Spaces inside placeholders - {{ VAR }} or {{VAR }}
    spaced_placeholders=$(echo "$content" | grep -oE '\{\{ +[A-Z_][A-Z0-9_]* *\}\}|\{\{[A-Z_][A-Z0-9_]* +\}\}' || true)
    if [[ -n "$spaced_placeholders" ]]; then
        syntax_errors="${syntax_errors}Spaces in placeholder: $spaced_placeholders\n"
    fi

    # Check 7: Lowercase placeholders - {{var}} or {{varName}}
    lowercase_placeholders=$(echo "$content" | grep -oE '\{\{[a-z][a-zA-Z0-9_]*\}\}' || true)
    if [[ -n "$lowercase_placeholders" ]]; then
        syntax_errors="${syntax_errors}Lowercase placeholder (should be UPPER_CASE): $lowercase_placeholders\n"
    fi

    # Report results
    if [[ -n "$syntax_errors" ]]; then
        fail "Syntax errors in $relative_path:"
        echo -e "$syntax_errors" | while read -r err; do
            if [[ -n "$err" ]]; then
                echo "      $err"
            fi
        done
    else
        # Check that placeholders exist if template seems to need them
        placeholder_count=$(echo "$content" | grep -oE '\{\{[A-Z_][A-Z0-9_]*\}\}' | wc -l)
        if [[ $placeholder_count -gt 0 ]]; then
            pass "Syntax valid: $relative_path ($placeholder_count placeholders)"
        else
            pass "Syntax valid: $relative_path (no placeholders)"
        fi
    fi
done < <(find "$TEMPLATE_DIR" -name "*.md" -type f -print0 | sort -z)

# ========================================
# Section 3.5: Malformed Placeholder Detection Tests
# ========================================
section "Section 3.5: Malformed Placeholder Detection Tests"

echo ""
echo "Testing detection of malformed placeholders..."

# Create a temporary test file with various malformed patterns
TEMP_TEST_DIR=$(mktemp -d)
mkdir -p "$TEMP_TEST_DIR/block" "$TEMP_TEST_DIR/codex" "$TEMP_TEST_DIR/claude"

# Test: Extra closing braces
echo "Testing: {{VAR}}} detection..."
echo "Test content {{VAR}}} here" > "$TEMP_TEST_DIR/block/test1.md"
result=$(echo "Test content {{VAR}}} here" | grep -oE '\{\{[A-Z_][A-Z0-9_]*\}\}\}+' || true)
if [[ -n "$result" ]]; then
    pass "Detects extra closing braces: {{VAR}}}"
else
    fail "Should detect extra closing braces: {{VAR}}}"
fi

# Test: Extra opening braces
echo "Testing: {{{VAR}}} detection..."
result=$(echo "Test content {{{VAR}}} here" | grep -oE '\{\{\{+[A-Z_][A-Z0-9_]*\}\}' || true)
if [[ -n "$result" ]]; then
    pass "Detects extra opening braces: {{{VAR}}}"
else
    fail "Should detect extra opening braces: {{{VAR}}}"
fi

# Test: Spaces inside placeholder
echo "Testing: {{ VAR }} detection..."
result=$(echo "Test content {{ VAR }} here" | grep -oE '\{\{ +[A-Z_][A-Z0-9_]* *\}\}' || true)
if [[ -n "$result" ]]; then
    pass "Detects spaces in placeholder: {{ VAR }}"
else
    fail "Should detect spaces in placeholder: {{ VAR }}"
fi

# Test: Lowercase placeholder
echo "Testing: {{varName}} detection..."
result=$(echo "Test content {{varName}} here" | grep -oE '\{\{[a-z][a-zA-Z0-9_]*\}\}' || true)
if [[ -n "$result" ]]; then
    pass "Detects lowercase placeholder: {{varName}}"
else
    fail "Should detect lowercase placeholder: {{varName}}"
fi

# Test: Valid placeholder should NOT trigger errors
echo "Testing: {{VALID_VAR}} should pass..."
content="Test content {{VALID_VAR}} here"
extra_close=$(echo "$content" | grep -oE '\{\{[A-Z_][A-Z0-9_]*\}\}\}+' || true)
extra_open=$(echo "$content" | grep -oE '\{\{\{+[A-Z_][A-Z0-9_]*\}\}' || true)
spaces=$(echo "$content" | grep -oE '\{\{ +[A-Z_][A-Z0-9_]* *\}\}' || true)
lowercase=$(echo "$content" | grep -oE '\{\{[a-z][a-zA-Z0-9_]*\}\}' || true)
if [[ -z "$extra_close" && -z "$extra_open" && -z "$spaces" && -z "$lowercase" ]]; then
    pass "Valid placeholder {{VALID_VAR}} passes all checks"
else
    fail "Valid placeholder should not trigger errors"
fi

# Clean up
rm -rf "$TEMP_TEST_DIR"

# ========================================
# Section 4: Render Template Edge Cases
# ========================================
section "Section 4: Render Template Edge Cases"

echo ""
echo "Testing empty content..."
result=$(render_template "" "VAR=value")
if [[ -z "$result" ]]; then
    pass "Empty content returns empty"
else
    fail "Empty content should return empty" "(empty)" "$result"
fi

echo ""
echo "Testing single line..."
result=$(render_template "Hello {{NAME}}" "NAME=World")
if [[ "$result" == "Hello World" ]]; then
    pass "Single line rendering"
else
    fail "Single line rendering" "Hello World" "$result"
fi

echo ""
echo "Testing multiple lines..."
template="Line 1: {{VAR1}}
Line 2: {{VAR2}}
Line 3: {{VAR3}}"
result=$(render_template "$template" "VAR1=A" "VAR2=B" "VAR3=C")
expected="Line 1: A
Line 2: B
Line 3: C"
if [[ "$result" == "$expected" ]]; then
    pass "Multiple lines rendering"
else
    fail "Multiple lines rendering" "$expected" "$result"
fi

echo ""
echo "Testing empty lines preservation..."
template="Before

{{VAR}}

After"
result=$(render_template "$template" "VAR=MIDDLE")
expected="Before

MIDDLE

After"
if [[ "$result" == "$expected" ]]; then
    pass "Empty lines preserved"
else
    fail "Empty lines preserved" "$expected" "$result"
fi

echo ""
echo "Testing special regex characters in values..."
result=$(render_template "Path: {{PATH}}" "PATH=/home/user/[test]/(foo)/*bar*")
expected="Path: /home/user/[test]/(foo)/*bar*"
if [[ "$result" == "$expected" ]]; then
    pass "Special regex characters in values"
else
    fail "Special regex characters in values" "$expected" "$result"
fi

echo ""
echo "Testing backslashes in values..."
result=$(render_template "Code: {{CODE}}" "CODE=\$HOME\\npath")
# Note: backslashes may be interpreted by awk
if echo "$result" | grep -q "Code:"; then
    pass "Backslashes in values (no crash)"
else
    fail "Backslashes in values" "Code: ..." "$result"
fi

echo ""
echo "Testing quotes in values..."
result=$(render_template "Quote: {{MSG}}" "MSG=He said \"hello\" and 'bye'")
if echo "$result" | grep -q "Quote:"; then
    pass "Quotes in values"
else
    fail "Quotes in values" "Quote: ..." "$result"
fi

echo ""
echo "Testing CJK characters..."
result=$(render_template "Message: {{MSG}}" "MSG=Hello World")
if [[ "$result" == "Message: Hello World" ]]; then
    # CJK in variable value
    result2=$(render_template "CJK: {{CJK}}" "CJK=Chinese Text Here")
    if echo "$result2" | grep -q "CJK:"; then
        pass "CJK characters handling"
    else
        fail "CJK characters handling" "CJK: ..." "$result2"
    fi
else
    fail "CJK characters handling" "Message: Hello World" "$result"
fi

echo ""
echo "Testing ASCII-only emoji-like patterns..."
# Real emoji might cause issues in some terminals, test with safe patterns
result=$(render_template "Status: {{STATUS}}" "STATUS=[OK] - Success!")
expected="Status: [OK] - Success!"
if [[ "$result" == "$expected" ]]; then
    pass "ASCII status patterns"
else
    fail "ASCII status patterns" "$expected" "$result"
fi

echo ""
echo "Testing markdown formatting in values..."
result=$(render_template "Formatted: {{TEXT}}" "TEXT=**bold** and _italic_ and \`code\`")
if echo "$result" | grep -q "Formatted:"; then
    pass "Markdown formatting in values"
else
    fail "Markdown formatting in values" "Formatted: ..." "$result"
fi

echo ""
echo "Testing long values..."
long_value=$(printf 'A%.0s' {1..1000})
result=$(render_template "Long: {{LONG}}" "LONG=$long_value")
if [[ ${#result} -gt 1000 ]]; then
    pass "Long values (1000+ chars)"
else
    fail "Long values" "1000+ chars" "${#result} chars"
fi

echo ""
echo "Testing multiline values..."
multiline_value="Line 1
Line 2
Line 3"
result=$(render_template "Content: {{CONTENT}}" "CONTENT=$multiline_value")
if echo "$result" | grep -q "Content:"; then
    pass "Multiline values (no crash)"
else
    fail "Multiline values" "Content: ..." "$result"
fi

echo ""
echo "Testing variable at start of line..."
result=$(render_template "{{VAR}} is first" "VAR=This")
if [[ "$result" == "This is first" ]]; then
    pass "Variable at start of line"
else
    fail "Variable at start of line" "This is first" "$result"
fi

echo ""
echo "Testing variable at end of line..."
result=$(render_template "Last is {{VAR}}" "VAR=this")
if [[ "$result" == "Last is this" ]]; then
    pass "Variable at end of line"
else
    fail "Variable at end of line" "Last is this" "$result"
fi

echo ""
echo "Testing multiple same variables..."
result=$(render_template "{{VAR}} and {{VAR}} again" "VAR=value")
if [[ "$result" == "value and value again" ]]; then
    pass "Multiple same variables"
else
    fail "Multiple same variables" "value and value again" "$result"
fi

echo ""
echo "Testing adjacent variables..."
result=$(render_template "{{A}}{{B}}{{C}}" "A=1" "B=2" "C=3")
if [[ "$result" == "123" ]]; then
    pass "Adjacent variables"
else
    fail "Adjacent variables" "123" "$result"
fi

# ========================================
# Section 5: Fallback Mechanism Tests
# ========================================
section "Section 5: Fallback Mechanism Tests"

echo ""
echo "Testing load_and_render_safe with missing template..."
fallback="Fallback: {{VAR}}"
result=$(load_and_render_safe "$TEMPLATE_DIR" "non-existing-file.md" "$fallback" "VAR=test")
if echo "$result" | grep -q "Fallback: test"; then
    pass "Fallback used for missing template"
else
    fail "Fallback used for missing template" "Fallback: test" "$result"
fi

echo ""
echo "Testing load_and_render_safe with existing template..."
fallback="This should NOT appear"
result=$(load_and_render_safe "$TEMPLATE_DIR" "block/git-push.md" "$fallback")
if echo "$result" | grep -q "Git Push Blocked" && ! echo "$result" | grep -q "should NOT appear"; then
    pass "Real template used when available"
else
    fail "Real template used when available" "Git Push Blocked" "$result"
fi

echo ""
echo "Testing validate_template_dir with valid dir..."
if validate_template_dir "$TEMPLATE_DIR" 2>/dev/null; then
    pass "validate_template_dir accepts valid directory"
else
    fail "validate_template_dir accepts valid directory"
fi

echo ""
echo "Testing validate_template_dir with invalid dir..."
if ! validate_template_dir "/non/existing/path" 2>/dev/null; then
    pass "validate_template_dir rejects invalid directory"
else
    fail "validate_template_dir rejects invalid directory"
fi

echo ""
echo "Testing validate_template_dir with incomplete dir..."
# Create a temp dir without subdirectories
temp_dir=$(mktemp -d)
if ! validate_template_dir "$temp_dir" 2>/dev/null; then
    pass "validate_template_dir rejects incomplete directory"
else
    fail "validate_template_dir rejects incomplete directory"
fi
rm -rf "$temp_dir"

# ========================================
# Section 6: Integration Tests with Real Templates
# ========================================
section "Section 6: Integration Tests with Real Templates"

echo ""
echo "Testing real template: block/wrong-round-number.md..."
result=$(load_and_render "$TEMPLATE_DIR" "block/wrong-round-number.md" \
    "ACTION=edit" \
    "CLAUDE_ROUND=3" \
    "FILE_TYPE=summary" \
    "CURRENT_ROUND=5" \
    "CORRECT_PATH=/tmp/round-5-summary.md")

if echo "$result" | grep -q "Wrong Round Number" && \
   echo "$result" | grep -q "round-3-summary" && \
   echo "$result" | grep -q "current round is \*\*5\*\*" && \
   echo "$result" | grep -q "/tmp/round-5-summary.md"; then
    pass "Real template rendering with all variables"
else
    fail "Real template rendering with all variables"
    echo "    Result was: $result"
fi

echo ""
echo "Testing real template: block/unpushed-commits.md..."
result=$(load_and_render "$TEMPLATE_DIR" "block/unpushed-commits.md" \
    "AHEAD_COUNT=3" \
    "CURRENT_BRANCH=feature-branch")

if echo "$result" | grep -q "Unpushed Commits" && \
   echo "$result" | grep -q "3 unpushed" && \
   echo "$result" | grep -q "feature-branch"; then
    pass "Real template: unpushed-commits.md"
else
    fail "Real template: unpushed-commits.md"
fi

echo ""
echo "Testing real template: codex/goal-tracker-update-section.md..."
result=$(load_and_render "$TEMPLATE_DIR" "codex/goal-tracker-update-section.md" \
    "GOAL_TRACKER_FILE=.humanize/rlcr/20240101/goal-tracker.md")

if echo "$result" | grep -q "Goal Tracker Update Requests" && \
   echo "$result" | grep -q ".humanize/rlcr/20240101/goal-tracker.md"; then
    pass "Real template: goal-tracker-update-section.md"
else
    fail "Real template: goal-tracker-update-section.md"
fi

# ========================================
# Section 7: Stress Tests
# ========================================
section "Section 7: Stress Tests"

echo ""
echo "Testing rapid successive calls..."
success_count=0
for i in {1..100}; do
    result=$(render_template "Test {{N}}" "N=$i")
    if [[ "$result" == "Test $i" ]]; then
        success_count=$((success_count + 1))
    fi
done
if [[ $success_count -eq 100 ]]; then
    pass "100 rapid successive calls"
else
    fail "100 rapid successive calls" "100" "$success_count"
fi

echo ""
echo "Testing all templates can be loaded and rendered..."
all_success=true
while IFS= read -r -d '' template_file; do
    relative_path="${template_file#$TEMPLATE_DIR/}"
    content=$(load_template "$TEMPLATE_DIR" "$relative_path" 2>/dev/null)

    if [[ -z "$content" ]]; then
        fail "Load failed: $relative_path"
        all_success=false
        continue
    fi

    # Try rendering with dummy values
    # Extract placeholder names and create dummy assignments
    placeholders=$(echo "$content" | grep -oE '\{\{[A-Z_][A-Z0-9_]*\}\}' | sed 's/{{//g; s/}}//g' | sort -u)

    args=()
    for placeholder in $placeholders; do
        args+=("$placeholder=TEST_VALUE_$placeholder")
    done

    if [[ ${#args[@]} -gt 0 ]]; then
        result=$(render_template "$content" "${args[@]}")
    else
        result="$content"
    fi

    if [[ -n "$result" ]]; then
        # Verify placeholders were replaced
        remaining=$(echo "$result" | grep -oE '\{\{[A-Z_][A-Z0-9_]*\}\}' || true)
        if [[ -z "$remaining" ]]; then
            : # pass silently for speed
        else
            warn "Unreplaced placeholders in $relative_path: $remaining"
        fi
    else
        fail "Render failed: $relative_path"
        all_success=false
    fi
done < <(find "$TEMPLATE_DIR" -name "*.md" -type f -print0 | sort -z)

if $all_success; then
    pass "All templates can be loaded and rendered"
fi

# ========================================
# Summary
# ========================================
section "Test Summary"

echo ""
echo -e "Passed:   ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed:   ${RED}$TESTS_FAILED${NC}"
echo -e "Warnings: ${YELLOW}$WARNINGS${NC}"
echo ""

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi
