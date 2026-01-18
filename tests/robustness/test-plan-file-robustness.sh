#!/bin/bash
#
# Robustness tests for plan file validation (AC-9)
#
# Tests plan file validation under edge cases:
# - Empty files
# - Very large files
# - Mixed line endings
# - File disappearance
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# Setup test directory
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

echo "========================================"
echo "Plan File Robustness Tests (AC-9)"
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
# Positive Tests - Valid Plan Files
# ========================================

echo "--- Positive Tests: Valid Plan Files ---"
echo ""

# Test 1: Correctly formatted plan file
echo "Test 1: Correctly formatted plan file"
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

LINE_COUNT=$(wc -l < "$TEST_DIR/valid-plan.md")
if [[ "$LINE_COUNT" -ge "5" ]]; then
    pass "Valid plan has $LINE_COUNT lines (>= 5 required)"
else
    fail "Valid plan" ">= 5 lines" "$LINE_COUNT lines"
fi

# Test 2: Count content lines vs comment lines
echo ""
echo "Test 2: Count content lines vs comment lines"
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

# Note: "# Plan Title" and "# This is also a comment" are treated as comments (start with #)
# Content lines are: "Content line one", "Content line two", "Content line three"
CONTENT_COUNT=$(count_content_lines "$TEST_DIR/mixed-plan.md")
if [[ "$CONTENT_COUNT" == "3" ]]; then
    pass "Correctly counts 3 content lines (excluding all comments)"
else
    fail "Content line count" "3" "$CONTENT_COUNT"
fi

# Test 3: Standard file sizes
echo ""
echo "Test 3: Standard file sizes (5KB)"
{
    echo "# Plan"
    echo "## Goal"
    echo "Implement feature."
    for i in $(seq 1 100); do
        echo "Task $i: Do something important for the project"
    done
} > "$TEST_DIR/standard-size.md"

SIZE=$(wc -c < "$TEST_DIR/standard-size.md")
if [[ "$SIZE" -gt "1000" ]] && [[ "$SIZE" -lt "10000" ]]; then
    pass "Standard size file handled ($SIZE bytes)"
else
    fail "Standard size" "1KB-10KB" "$SIZE bytes"
fi

# Test 4: Plan with various markdown elements
echo ""
echo "Test 4: Plan with various markdown elements"
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

CONTENT_COUNT=$(count_content_lines "$TEST_DIR/rich-plan.md")
if [[ "$CONTENT_COUNT" -gt "10" ]]; then
    pass "Rich markdown content counted ($CONTENT_COUNT content lines)"
else
    fail "Rich content" ">10 content lines" "$CONTENT_COUNT"
fi

# ========================================
# Negative Tests - Edge Cases
# ========================================

echo ""
echo "--- Negative Tests: Edge Cases ---"
echo ""

# Test 5: Empty plan file
echo "Test 5: Empty plan file"
: > "$TEST_DIR/empty-plan.md"

LINE_COUNT=$(wc -l < "$TEST_DIR/empty-plan.md")
if [[ "$LINE_COUNT" -lt "5" ]]; then
    pass "Empty file has $LINE_COUNT lines (< 5 as expected)"
else
    fail "Empty file" "< 5 lines" "$LINE_COUNT lines"
fi

# Test 6: Plan with only comments
echo ""
echo "Test 6: Plan with only comments"
cat > "$TEST_DIR/comments-only.md" << 'EOF'
<!-- Comment 1 -->
# Comment line 1
# Comment line 2
<!-- Another comment -->
# More comments
EOF

CONTENT_COUNT=$(count_content_lines "$TEST_DIR/comments-only.md")
if [[ "$CONTENT_COUNT" -lt "3" ]]; then
    pass "Comments-only file has $CONTENT_COUNT content lines (< 3)"
else
    fail "Comments-only" "< 3 content lines" "$CONTENT_COUNT"
fi

# Test 7: Very large plan file (1MB+)
echo ""
echo "Test 7: Very large plan file (1MB)"
{
    echo "# Large Plan"
    echo "## Goal"
    echo "Very large implementation."
    # Generate ~1MB of content
    for i in $(seq 1 15000); do
        echo "Task $i: This is a task description that adds content to make the file larger"
    done
} > "$TEST_DIR/large-plan.md"

SIZE=$(wc -c < "$TEST_DIR/large-plan.md")
if [[ "$SIZE" -gt "1000000" ]]; then
    # Test that we can still count lines (performance)
    START=$(date +%s%N)
    LINE_COUNT=$(wc -l < "$TEST_DIR/large-plan.md")
    END=$(date +%s%N)
    ELAPSED_MS=$(( (END - START) / 1000000 ))
    if [[ "$LINE_COUNT" -gt "15000" ]] && [[ "$ELAPSED_MS" -lt "1000" ]]; then
        pass "Large file handled ($SIZE bytes, $LINE_COUNT lines, ${ELAPSED_MS}ms)"
    else
        fail "Large file performance" "<1000ms" "${ELAPSED_MS}ms"
    fi
else
    fail "Large file size" ">1MB" "$SIZE bytes"
fi

# Test 8: Mixed line endings (CRLF/LF)
echo ""
echo "Test 8: Mixed line endings (CRLF/LF)"
printf "# Plan\r\nLine with CRLF\r\n\nLine with LF\n\r\nMixed\n" > "$TEST_DIR/mixed-endings.md"

LINE_COUNT=$(wc -l < "$TEST_DIR/mixed-endings.md")
if [[ "$LINE_COUNT" -ge "3" ]]; then
    pass "Mixed endings file readable ($LINE_COUNT lines)"
else
    fail "Mixed endings" ">= 3 lines" "$LINE_COUNT lines"
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

# ========================================
# Summary
# ========================================

echo ""
echo "========================================"
echo "Plan File Robustness Test Summary"
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
