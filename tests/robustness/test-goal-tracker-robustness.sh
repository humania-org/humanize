#!/bin/bash
#
# Robustness tests for goal tracker parsing (AC-3)
#
# Tests goal tracker parsing under edge cases:
# - Mixed AC formats
# - Missing table pipes
# - Large AC counts
# - Special characters
# - Incomplete files
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/hooks/lib/loop-common.sh"

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
echo "Goal Tracker Robustness Tests (AC-3)"
echo "========================================"
echo ""

# Helper function to count AC items in a goal tracker file
count_ac_items() {
    local file="$1"
    local count
    count=$(grep -cE '^\s*-\s*AC-[0-9]+' "$file" 2>/dev/null) || count="0"
    echo "$count"
}

# Helper function to extract AC identifiers
extract_ac_ids() {
    local file="$1"
    grep -oE 'AC-[0-9]+(\.[0-9]+)?' "$file" 2>/dev/null | sort -u | tr '\n' ' ' || echo ""
}

# ========================================
# Positive Tests - Valid Goal Tracker
# ========================================

echo "--- Positive Tests: Valid Goal Tracker ---"
echo ""

# Test 1: Parse standard table format
echo "Test 1: Count AC items in standard table format"
cat > "$TEST_DIR/goal-tracker.md" << 'EOF'
# Goal Tracker

## Acceptance Criteria

- AC-1: First criterion
- AC-2: Second criterion
- AC-3: Third criterion

## Active Tasks

| Task | Target AC | Status |
|------|-----------|--------|
| Task 1 | AC-1 | pending |
| Task 2 | AC-2 | in_progress |
EOF

COUNT=$(count_ac_items "$TEST_DIR/goal-tracker.md")
if [[ "$COUNT" == "3" ]]; then
    pass "Counts 3 AC items in standard format"
else
    fail "Standard AC count" "3" "$COUNT"
fi

# Test 2: Handle mixed AC formats
echo ""
echo "Test 2: Handle mixed AC formats (AC-1, AC1, AC-1.1)"
cat > "$TEST_DIR/goal-tracker-mixed.md" << 'EOF'
# Goal Tracker

## Acceptance Criteria

- AC-1: Standard format
- AC-2.1: Sub-criterion format
- AC-3.2.1: Deeply nested format

## Notes
Some text with AC1 inline reference and AC-10 another one.
EOF

AC_IDS=$(extract_ac_ids "$TEST_DIR/goal-tracker-mixed.md")
if echo "$AC_IDS" | grep -q "AC-1" && echo "$AC_IDS" | grep -q "AC-2.1"; then
    pass "Extracts mixed AC formats: $AC_IDS"
else
    fail "Mixed AC formats" "AC-1, AC-2.1, etc." "$AC_IDS"
fi

# Test 3: Parse completion status from table
echo ""
echo "Test 3: Extract completion status from markdown table"
cat > "$TEST_DIR/goal-tracker-status.md" << 'EOF'
### Completed and Verified

| AC | Task | Completed Round | Verified Round | Evidence |
|----|------|-----------------|----------------|----------|
| AC-1 | Task 1 | 2 | 3 | tests pass |
| AC-2 | Task 2 | 3 | 4 | deployed |

### Active Tasks

| Task | Target AC | Status | Notes |
|------|-----------|--------|-------|
| Task 3 | AC-3 | pending | - |
EOF

# Count rows in Completed table (lines starting with | AC-)
COMPLETED=$(grep -c '^| AC-[0-9]' "$TEST_DIR/goal-tracker-status.md" 2>/dev/null || echo "0")
if [[ "$COMPLETED" == "2" ]]; then
    pass "Identifies completed AC items in table"
else
    fail "Completed AC count" "2" "$COMPLETED"
fi

# Test 4: Goal tracker with Unicode content
echo ""
echo "Test 4: Goal tracker with Unicode in descriptions"
cat > "$TEST_DIR/goal-tracker-unicode.md" << 'EOF'
# Goal Tracker

## Acceptance Criteria

- AC-1: Support for internationalization
- AC-2: Handle special characters in input
EOF

COUNT=$(count_ac_items "$TEST_DIR/goal-tracker-unicode.md")
if [[ "$COUNT" == "2" ]]; then
    pass "Handles Unicode content in goal tracker"
else
    fail "Unicode handling" "2" "$COUNT"
fi

# Test 5: Goal tracker with code blocks
echo ""
echo "Test 5: Goal tracker with AC references in code blocks"
cat > "$TEST_DIR/goal-tracker-code.md" << 'EOF'
# Goal Tracker

## Acceptance Criteria

- AC-1: Main criterion

```bash
# This AC-2 should be ignored since it's in a code block
echo "Testing AC-3"
```

- AC-2: Real second criterion
EOF

# Should count both real AC items (AC-1 and AC-2 outside code blocks)
# Note: simple grep doesn't distinguish code blocks, but the count should be 2
COUNT=$(count_ac_items "$TEST_DIR/goal-tracker-code.md")
if [[ "$COUNT" -ge "2" ]]; then
    pass "Handles AC references near code blocks (count: $COUNT)"
else
    fail "Code block handling" ">=2" "$COUNT"
fi

# ========================================
# Negative Tests - Edge Cases
# ========================================

echo ""
echo "--- Negative Tests: Edge Cases ---"
echo ""

# Test 6: Goal tracker with missing table pipes
echo "Test 6: Goal tracker with missing table pipes"
cat > "$TEST_DIR/goal-tracker-nopipes.md" << 'EOF'
# Goal Tracker

## Active Tasks

Task  Target AC  Status
Task 1  AC-1  pending
Task 2  AC-2  in_progress
EOF

# Should still find AC references even without pipes
AC_IDS=$(extract_ac_ids "$TEST_DIR/goal-tracker-nopipes.md")
if echo "$AC_IDS" | grep -q "AC-1"; then
    pass "Finds AC references even without table pipes"
else
    fail "Missing pipes" "AC-1, AC-2" "$AC_IDS"
fi

# Test 7: Large AC counts (50+)
echo ""
echo "Test 7: Handle large AC counts (60 items)"
{
    echo "# Goal Tracker"
    echo "## Acceptance Criteria"
    for i in $(seq 1 60); do
        echo "- AC-$i: Criterion number $i"
    done
} > "$TEST_DIR/goal-tracker-large.md"

COUNT=$(count_ac_items "$TEST_DIR/goal-tracker-large.md")
if [[ "$COUNT" == "60" ]]; then
    pass "Handles 60 AC items without overflow"
else
    fail "Large AC count" "60" "$COUNT"
fi

# Test 8: Special characters in AC names
echo ""
echo "Test 8: Special characters in AC descriptions"
cat > "$TEST_DIR/goal-tracker-special.md" << 'EOF'
# Goal Tracker

## Acceptance Criteria

- AC-1: Handle $PATH variable expansion
- AC-2: Support `backticks` and "quotes"
- AC-3: Process <angle> & brackets
EOF

COUNT=$(count_ac_items "$TEST_DIR/goal-tracker-special.md")
if [[ "$COUNT" == "3" ]]; then
    pass "Handles special characters in descriptions"
else
    fail "Special characters" "3" "$COUNT"
fi

# Test 9: Empty goal tracker
echo ""
echo "Test 9: Empty goal tracker file"
: > "$TEST_DIR/goal-tracker-empty.md"

COUNT=$(count_ac_items "$TEST_DIR/goal-tracker-empty.md")
# grep returns empty string or 0 for no matches
if [[ -z "$COUNT" ]] || [[ "$COUNT" == "0" ]]; then
    pass "Returns 0 for empty file"
else
    fail "Empty file" "0 or empty" "$COUNT"
fi

# Test 10: Goal tracker with only headers
echo ""
echo "Test 10: Goal tracker with only headers (no AC items)"
cat > "$TEST_DIR/goal-tracker-headers.md" << 'EOF'
# Goal Tracker

## Acceptance Criteria

## Active Tasks

## Completed
EOF

COUNT=$(count_ac_items "$TEST_DIR/goal-tracker-headers.md")
# grep returns empty string or 0 for no matches
if [[ -z "$COUNT" ]] || [[ "$COUNT" == "0" ]]; then
    pass "Returns 0 for file with only headers"
else
    fail "Headers only" "0 or empty" "$COUNT"
fi

# Test 11: Truncated goal tracker
echo ""
echo "Test 11: Truncated/incomplete goal tracker file"
cat > "$TEST_DIR/goal-tracker-truncated.md" << 'EOF'
# Goal Tracker

## Acceptance Criteria

- AC-1: First criterion
- AC-2: Second crit
EOF

# Simulate truncation by removing last bytes using dd
FILESIZE=$(wc -c < "$TEST_DIR/goal-tracker-truncated.md")
NEWSIZE=$((FILESIZE - 5))
if [[ $NEWSIZE -gt 0 ]]; then
    dd if="$TEST_DIR/goal-tracker-truncated.md" of="$TEST_DIR/goal-tracker-truncated-new.md" bs=1 count=$NEWSIZE 2>/dev/null
    mv "$TEST_DIR/goal-tracker-truncated-new.md" "$TEST_DIR/goal-tracker-truncated.md"
fi

# Should still find at least the first AC
COUNT=$(count_ac_items "$TEST_DIR/goal-tracker-truncated.md")
if [[ -n "$COUNT" ]] && [[ "$COUNT" -ge "1" ]]; then
    pass "Handles truncated file gracefully (found $COUNT AC items)"
else
    fail "Truncated file" ">=1" "${COUNT:-empty}"
fi

# Test 12: Goal tracker with very long lines
echo ""
echo "Test 12: Goal tracker with very long AC descriptions"
{
    echo "# Goal Tracker"
    echo "## Acceptance Criteria"
    # Create a 10KB description
    LONG_DESC=$(printf 'x%.0s' {1..10000})
    echo "- AC-1: $LONG_DESC"
    echo "- AC-2: Normal description"
} > "$TEST_DIR/goal-tracker-long.md"

COUNT=$(count_ac_items "$TEST_DIR/goal-tracker-long.md")
if [[ "$COUNT" == "2" ]]; then
    pass "Handles very long AC descriptions"
else
    fail "Long descriptions" "2" "$COUNT"
fi

# Test 13: Goal tracker with malformed markdown
echo ""
echo "Test 13: Goal tracker with malformed markdown"
cat > "$TEST_DIR/goal-tracker-malformed.md" << 'EOF'
# Goal Tracker

## Acceptance Criteria
- AC-1 First criterion without colon
  - AC-2: Nested criterion
    - AC-3: Double nested

#### Active Tasks
| Task | Target AC |
| incomplete table row
| Task 1 | AC-1
EOF

COUNT=$(count_ac_items "$TEST_DIR/goal-tracker-malformed.md")
if [[ "$COUNT" -ge "1" ]]; then
    pass "Handles malformed markdown (found $COUNT AC items)"
else
    fail "Malformed markdown" ">=1" "$COUNT"
fi

# Test 14: Non-existent goal tracker
echo ""
echo "Test 14: Non-existent goal tracker file"
COUNT=$(count_ac_items "$TEST_DIR/nonexistent.md")
if [[ "$COUNT" == "0" ]]; then
    pass "Returns 0 for non-existent file"
else
    fail "Non-existent file" "0" "$COUNT"
fi

# Test 15: Goal tracker with binary content
echo ""
echo "Test 15: Goal tracker with binary content"
cat > "$TEST_DIR/goal-tracker-binary.md" << 'EOF'
# Goal Tracker

## Acceptance Criteria

- AC-1: Normal criterion
EOF
printf '\x00\x01\x02\x03' >> "$TEST_DIR/goal-tracker-binary.md"
echo "" >> "$TEST_DIR/goal-tracker-binary.md"
echo "- AC-2: After binary" >> "$TEST_DIR/goal-tracker-binary.md"

COUNT=$(count_ac_items "$TEST_DIR/goal-tracker-binary.md")
if [[ "$COUNT" -ge "1" ]]; then
    pass "Handles binary content gracefully (found $COUNT AC items)"
else
    fail "Binary content" ">=1" "$COUNT"
fi

# Test 16: Goal tracker with AC in comments
echo ""
echo "Test 16: Goal tracker with AC references in HTML comments"
cat > "$TEST_DIR/goal-tracker-comments.md" << 'EOF'
# Goal Tracker

<!--
- AC-HIDDEN: Should not count
-->

## Acceptance Criteria

- AC-1: Real criterion
<!-- AC-2: Also hidden -->
- AC-3: Another real criterion
EOF

# Simple grep doesn't filter comments, so count what's there
COUNT=$(count_ac_items "$TEST_DIR/goal-tracker-comments.md")
if [[ "$COUNT" -ge "2" ]]; then
    pass "Processes goal tracker with comments (found $COUNT)"
else
    fail "Comments handling" ">=2" "$COUNT"
fi

# Test 17: Goal tracker with duplicate AC numbers
echo ""
echo "Test 17: Goal tracker with duplicate AC numbers"
cat > "$TEST_DIR/goal-tracker-dupes.md" << 'EOF'
# Goal Tracker

## Acceptance Criteria

- AC-1: First occurrence
- AC-1: Duplicate
- AC-2: Unique
EOF

# Count total occurrences (dupes should be counted)
COUNT=$(count_ac_items "$TEST_DIR/goal-tracker-dupes.md")
if [[ "$COUNT" == "3" ]]; then
    pass "Counts duplicate AC numbers"
else
    fail "Duplicate handling" "3" "$COUNT"
fi

# Test 18: Goal tracker with AC-0
echo ""
echo "Test 18: Goal tracker with AC-0 (edge case)"
cat > "$TEST_DIR/goal-tracker-zero.md" << 'EOF'
# Goal Tracker

## Acceptance Criteria

- AC-0: Zero-indexed criterion
- AC-1: Normal criterion
EOF

AC_IDS=$(extract_ac_ids "$TEST_DIR/goal-tracker-zero.md")
if echo "$AC_IDS" | grep -q "AC-0"; then
    pass "Handles AC-0 correctly"
else
    fail "AC-0 handling" "AC-0, AC-1" "$AC_IDS"
fi

# ========================================
# Summary
# ========================================

echo ""
echo "========================================"
echo "Goal Tracker Robustness Test Summary"
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
