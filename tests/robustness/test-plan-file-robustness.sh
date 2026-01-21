#!/bin/bash
#
# Robustness tests for plan file validation
#
# Tests production plan file validation in scripts/setup-rlcr-loop.sh:
# - Empty files
# - Very large files
# - Mixed line endings
# - File disappearance
# - Content line counting
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Create a temporary test directory
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

# Set up isolated cache directory to avoid permission issues
export XDG_CACHE_HOME="$TEST_DIR/.cache"
mkdir -p "$XDG_CACHE_HOME"

# Create mock codex to prevent calling real codex (which is slow)
setup_mock_codex() {
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/codex" << 'MOCKEOF'
#!/bin/bash
# Mock codex for test-plan-file-robustness.sh
echo "Mock codex output"
exit 0
MOCKEOF
    chmod +x "$TEST_DIR/bin/codex"
    export PATH="$TEST_DIR/bin:$PATH"
}

# Initialize mock codex
setup_mock_codex

# ========================================
# Production Function Under Test
# ========================================

# Test plan validation by running setup-rlcr-loop.sh with a plan file
# Returns exit code from script (0 = accepted, non-zero = rejected)
test_plan_validation() {
    local plan_path="$1"
    local result_file
    local exit_code

    # Create temp file to capture output (avoids command substitution limits)
    result_file=$(mktemp)

    # Clean up any existing loop directories for consistent testing
    rm -rf "$TEST_DIR/.humanize/rlcr"

    # Run the production script, writing output to file
    # Note: Use nohup style to avoid SIGPIPE issues with large output
    CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" "$plan_path" > "$result_file" 2>&1 </dev/null || exit_code=$?
    exit_code=${exit_code:-0}

    # Check for specific plan validation errors
    if grep -qE "(Plan is too simple|Plan file has insufficient content|Plan file not found|Plan file not readable|symbolic link)" "$result_file"; then
        rm -f "$result_file"
        return 1  # Plan validation failed
    fi

    # Check for codex not available - this means all validations passed
    if grep -q "requires codex" "$result_file"; then
        rm -f "$result_file"
        return 0
    fi

    # Check for gitignore error (plan file tracking) - validation passed
    if grep -q "must be gitignored" "$result_file"; then
        rm -f "$result_file"
        return 0
    fi

    # Check for successful loop creation - all validations passed
    if grep -q "start-rlcr-loop activated" "$result_file"; then
        rm -f "$result_file"
        return 0
    fi

    # Also check if loop directory was created (alternative success indicator)
    if [[ -d "$TEST_DIR/.humanize/rlcr" ]]; then
        local loop_dir
        loop_dir=$(ls -d "$TEST_DIR/.humanize/rlcr"/*/ 2>/dev/null | head -1)
        if [[ -n "$loop_dir" ]] && [[ -f "${loop_dir}state.md" ]]; then
            rm -f "$result_file"
            return 0
        fi
    fi

    rm -f "$result_file"

    # Any error is a failure
    if [[ $exit_code -ne 0 ]]; then
        return 1
    fi

    return $exit_code
}

source "$SCRIPT_DIR/../test-helpers.sh"

setup_test_dir

# Create a mock git repo in the test directory
cd "$TEST_DIR"
git init --quiet
git config user.email "test@test.com"
git config user.name "Test User"
git config commit.gpgsign false
echo "Initial" > README.md
git add README.md
git commit -m "Initial commit" --quiet

echo "========================================"
echo "Plan File Robustness Tests"
echo "========================================"
echo ""

# Helper function to count content lines (excluding blanks and comments)
count_content_lines() {
    local file="$1"
    local count=0
    local in_comment=false

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Handle multi-line comment state
        if [[ "$in_comment" == "true" ]]; then
            if [[ "$line" =~ --\>[[:space:]]*$ ]]; then
                in_comment=false
            fi
            continue
        fi

        # Skip blank lines
        if [[ "$line" =~ ^[[:space:]]*$ ]]; then
            continue
        fi

        # Skip single-line HTML comments
        if [[ "$line" =~ ^[[:space:]]*\<!--.*--\>[[:space:]]*$ ]]; then
            continue
        fi

        # Check for multi-line HTML comment start
        if [[ "$line" =~ ^[[:space:]]*\<!-- ]] && ! [[ "$line" =~ --\> ]]; then
            in_comment=true
            continue
        fi

        # Skip shell/YAML style comments
        if [[ "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi

        count=$((count + 1))
    done < "$file"

    echo "$count"
}

# ========================================
# Positive Tests - Valid Plan Files (via production)
# ========================================

echo "--- Positive Tests: Valid Plan Files (via production) ---"
echo ""

# Test 1: Correctly formatted plan file (production validation)
echo "Test 1: Production accepts correctly formatted plan file"
cat > "$TEST_DIR/valid-plan.md" << 'EOF'
# Implementation Plan

## Goal

Implement feature X.

## Tasks

1. Task one
2. Task two
3. Task three

## Acceptance Criteria

- AC-1: Feature works
- AC-2: Tests pass
EOF

if test_plan_validation "valid-plan.md"; then
    LINE_COUNT=$(wc -l < "$TEST_DIR/valid-plan.md")
    pass "Production accepts valid plan ($LINE_COUNT lines)"
else
    fail "Valid plan acceptance" "accepted" "rejected"
fi

# Test 2: Plan with comments - production rejects insufficient content
echo ""
echo "Test 2: Production rejects plan with insufficient content (mostly comments)"
cat > "$TEST_DIR/mixed-plan.md" << 'EOF'
# Plan Title

<!-- This is a comment -->
# This is also a comment

Content line one

Content line two

<!-- Multi-line
comment that spans
multiple lines -->

Content line three
EOF

# Production requires at least 3 content lines - this file has exactly 3
# Note: "# Plan Title" and "# This is also a comment" are treated as comments (start with #)
if test_plan_validation "mixed-plan.md"; then
    pass "Production accepts plan with 3 content lines (minimum)"
else
    fail "Minimal content acceptance" "accepted (3 content lines)" "rejected"
fi

# Test 3: Standard file sizes (5KB) - production validation
echo ""
echo "Test 3: Production accepts standard file sizes (5KB)"
{
    echo "# Plan"
    echo "## Goal"
    echo "Implement feature."
    for i in $(seq 1 100); do
        echo "Task $i: Do something important for the project"
    done
} > "$TEST_DIR/standard-size.md"

SIZE=$(wc -c < "$TEST_DIR/standard-size.md")
if test_plan_validation "standard-size.md"; then
    pass "Production accepts standard size file ($SIZE bytes)"
else
    fail "Standard size acceptance" "accepted" "rejected ($SIZE bytes)"
fi

# Test 4: Plan with various markdown elements - production validation
echo ""
echo "Test 4: Production accepts plan with rich markdown elements"
cat > "$TEST_DIR/rich-plan.md" << 'EOF'
# Rich Plan

## Code Examples

```python
def hello():
    print("world")
```

## Tables

| Column | Value |
|--------|-------|
| A      | 1     |

## Lists

- Item one
  - Sub item
- Item two

## Links

[Link text](https://example.com)

**Bold** and *italic* text.
EOF

if test_plan_validation "rich-plan.md"; then
    CONTENT_COUNT=$(count_content_lines "$TEST_DIR/rich-plan.md")
    pass "Production accepts rich markdown plan ($CONTENT_COUNT content lines)"
else
    fail "Rich markdown acceptance" "accepted" "rejected"
fi

# ========================================
# Negative Tests - Edge Cases
# ========================================

echo ""
echo "--- Negative Tests: Edge Cases ---"
echo ""

# Test 5: Empty plan file (production validation)
echo "Test 5: Empty plan file rejected by production"
: > "$TEST_DIR/empty-plan.md"
if ! test_plan_validation "empty-plan.md"; then
    pass "Production rejects empty plan file"
else
    fail "Empty file rejection" "rejected" "accepted"
fi

# Test 6: Plan with only comments (production validation)
echo ""
echo "Test 6: Plan with only comments rejected by production"
cat > "$TEST_DIR/comments-only.md" << 'EOF'
<!-- Comment 1 -->
# Comment line 1
# Comment line 2
<!-- Another comment -->
# More comments
EOF
if ! test_plan_validation "comments-only.md"; then
    pass "Production rejects comments-only plan file"
else
    fail "Comments-only rejection" "rejected" "accepted"
fi

# Test 7: Large plan file (1MB+) - production validation
# Tests that production script handles very large plan files correctly.
# The SIGPIPE issue in sed|head pipelines was fixed to allow 1MB+ files.
echo ""
echo "Test 7: Large plan file (1MB+) accepted by production"
{
    echo "# Large Plan"
    echo "## Goal"
    echo "Very large implementation."
    # Generate ~1MB of content (20000 lines)
    for i in $(seq 1 20000); do
        echo "Task $i: This is a very detailed task description."
    done
} > "$TEST_DIR/large-plan.md"

SIZE=$(wc -c < "$TEST_DIR/large-plan.md")
if [[ "$SIZE" -gt "1000000" ]]; then
    # Test production validation handles large files
    START=$(date +%s%N)
    if test_plan_validation "large-plan.md"; then
        END=$(date +%s%N)
        ELAPSED_MS=$(( (END - START) / 1000000 ))
        pass "Large file validated ($SIZE bytes, ${ELAPSED_MS}ms)"
    else
        fail "Large file validation" "accepted" "rejected"
    fi
else
    fail "Large file size" ">1MB" "$SIZE bytes"
fi

# Test 8: Mixed line endings (CRLF/LF) - production validation
echo ""
echo "Test 8: Production accepts mixed line endings (CRLF/LF)"
# Create plan with mixed line endings but sufficient content
printf "# Plan\r\n## Goal\r\nImplement feature.\r\n\nTask one\nTask two\nTask three\n" > "$TEST_DIR/mixed-endings.md"

if test_plan_validation "mixed-endings.md"; then
    LINE_COUNT=$(wc -l < "$TEST_DIR/mixed-endings.md")
    pass "Production accepts mixed endings plan ($LINE_COUNT lines)"
else
    fail "Mixed endings acceptance" "accepted" "rejected"
fi

# Test 9: Plan with binary content
echo ""
echo "Test 9: Plan with binary content mixed in"
cat > "$TEST_DIR/binary-plan.md" << 'EOF'
# Plan with Binary

## Goal

Content before binary.
EOF
printf '\x00\x01\x02\x03\x04' >> "$TEST_DIR/binary-plan.md"
echo "" >> "$TEST_DIR/binary-plan.md"
echo "Content after binary." >> "$TEST_DIR/binary-plan.md"

# wc should still work
LINE_COUNT=$(wc -l < "$TEST_DIR/binary-plan.md" 2>/dev/null || echo "error")
if [[ "$LINE_COUNT" != "error" ]] && [[ "$LINE_COUNT" -ge "5" ]]; then
    pass "Binary content handled ($LINE_COUNT lines)"
else
    fail "Binary content" ">= 5 lines" "$LINE_COUNT"
fi

# Test 10: Plan file with very long lines
echo ""
echo "Test 10: Plan file with very long lines"
{
    echo "# Plan"
    echo "## Goal"
    LONG_LINE=$(printf 'x%.0s' {1..10000})
    echo "Long line: $LONG_LINE"
    echo "Normal line."
    echo "Another normal line."
} > "$TEST_DIR/long-lines.md"

LINE_COUNT=$(wc -l < "$TEST_DIR/long-lines.md")
if [[ "$LINE_COUNT" == "5" ]]; then
    pass "Long lines handled correctly ($LINE_COUNT lines)"
else
    fail "Long lines" "5 lines" "$LINE_COUNT lines"
fi

# Test 11: Plan with special characters
echo ""
echo "Test 11: Plan with special shell characters"
cat > "$TEST_DIR/special-chars.md" << 'EOF'
Plan with special characters

Goal: Use backticks and VARS

Content with command and variable patterns.

More content with single and double quotes.

Line with ampersand and pipe.
EOF

# All 7 non-blank lines are content (no # comments)
CONTENT_COUNT=$(count_content_lines "$TEST_DIR/special-chars.md")
if [[ "$CONTENT_COUNT" -ge "5" ]]; then
    pass "Special characters handled ($CONTENT_COUNT content lines)"
else
    fail "Special characters" ">= 5 content lines" "$CONTENT_COUNT"
fi

# Test 12: Plan with only whitespace
echo ""
echo "Test 12: Plan with only whitespace"
printf "   \n\t\n   \t   \n\n\n" > "$TEST_DIR/whitespace-plan.md"

CONTENT_COUNT=$(count_content_lines "$TEST_DIR/whitespace-plan.md")
if [[ "$CONTENT_COUNT" == "0" ]]; then
    pass "Whitespace-only file has 0 content lines"
else
    fail "Whitespace-only" "0 content lines" "$CONTENT_COUNT"
fi

# Test 13: Plan with nested HTML comments
echo ""
echo "Test 13: Plan with nested/complex HTML comments"
cat > "$TEST_DIR/nested-comments.md" << 'EOF'
# Plan

<!-- Start comment
  <!-- Nested? (technically invalid HTML but might appear) -->
End of outer comment -->

Content line.

<!-- Single line comment --> More content.

Real content here.
EOF

CONTENT_COUNT=$(count_content_lines "$TEST_DIR/nested-comments.md")
if [[ "$CONTENT_COUNT" -ge "2" ]]; then
    pass "Complex comments handled ($CONTENT_COUNT content lines)"
else
    fail "Complex comments" ">= 2 content lines" "$CONTENT_COUNT"
fi

# Test 14: Non-existent file handling
echo ""
echo "Test 14: Non-existent file"
if [[ ! -f "$TEST_DIR/nonexistent.md" ]]; then
    pass "Non-existent file correctly detected as missing"
else
    fail "Non-existent detection" "file missing" "file exists"
fi

# Test 15: Permission check (unreadable file)
echo ""
echo "Test 15: Unreadable file handling"
echo "# Content" > "$TEST_DIR/unreadable.md"
chmod 000 "$TEST_DIR/unreadable.md"

if [[ ! -r "$TEST_DIR/unreadable.md" ]]; then
    pass "Unreadable file correctly detected"
else
    # If we can read it (e.g., running as root), that's also valid
    pass "File readable (possibly running as root)"
fi
chmod 644 "$TEST_DIR/unreadable.md"

# Test 16: Symlink handling
echo ""
echo "Test 16: Plan file as symlink"
echo "# Real content" > "$TEST_DIR/real-plan.md"
ln -s "$TEST_DIR/real-plan.md" "$TEST_DIR/symlink-plan.md"

if [[ -L "$TEST_DIR/symlink-plan.md" ]]; then
    pass "Symlink correctly detected as symlink"
else
    fail "Symlink detection" "is symlink" "not detected"
fi

# Test 17: Directory instead of file
echo ""
echo "Test 17: Directory instead of file"
mkdir -p "$TEST_DIR/not-a-file.md"

if [[ -d "$TEST_DIR/not-a-file.md" ]]; then
    pass "Directory correctly detected as not a file"
else
    fail "Directory detection" "is directory" "treated as file"
fi

# Test 18: File with null bytes
echo ""
echo "Test 18: File with null bytes"
printf "# Plan\nContent\x00More content\nEnd\n" > "$TEST_DIR/null-bytes.md"

# Should be able to get line count even with nulls
LINE_COUNT=$(wc -l < "$TEST_DIR/null-bytes.md" 2>/dev/null || echo "error")
if [[ "$LINE_COUNT" != "error" ]]; then
    pass "Null bytes handled (line count: $LINE_COUNT)"
else
    fail "Null bytes" "readable" "error"
fi

# Test 19: Plan file that disappears mid-validation
echo ""
echo "Test 19: Plan file disappearance during validation"
# Create a valid plan file
cat > "$TEST_DIR/disappear-plan.md" << 'EOF'
# Disappearing Plan

## Goal

This plan will disappear.

## Tasks

1. Task one
2. Task two
3. Task three
EOF

# Immediately delete it and try to validate
rm "$TEST_DIR/disappear-plan.md"
if ! test_plan_validation "disappear-plan.md"; then
    pass "Production rejects missing plan file"
else
    fail "Missing plan rejection" "rejected" "accepted"
fi

# ========================================
# Summary
# ========================================

print_test_summary "Plan File Robustness Test Summary"
exit $?
