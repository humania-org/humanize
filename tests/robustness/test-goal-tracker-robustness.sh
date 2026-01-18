#!/bin/bash
#
# Robustness tests for goal tracker parsing (AC-3)
#
# Tests production humanize_parse_goal_tracker function from scripts/humanize.sh:
# - Standard table format
# - Mixed AC formats
# - Large AC counts
# - Special characters
# - Empty/malformed files
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source test helpers first (before humanize.sh which may use variables)
source "$SCRIPT_DIR/../test-helpers.sh"

# Source the production humanize.sh to get humanize_parse_goal_tracker function
source "$PROJECT_ROOT/scripts/humanize.sh"

setup_test_dir

echo "========================================"
echo "Goal Tracker Robustness Tests (AC-3)"
echo "========================================"
echo ""

# ========================================
# Production Function Under Test
# ========================================

# Uses humanizehumanize_parse_goal_tracker from scripts/humanize.sh (sourced above)
# The function returns: total_acs|completed_acs|active_tasks|completed_tasks|deferred_tasks|open_issues|goal_summary

# Helper to parse output
parse_result() {
    local result="$1"
    local field="$2"
    case "$field" in
        total_acs) echo "$result" | cut -d'|' -f1 ;;
        completed_acs) echo "$result" | cut -d'|' -f2 ;;
        active_tasks) echo "$result" | cut -d'|' -f3 ;;
        completed_tasks) echo "$result" | cut -d'|' -f4 ;;
        deferred_tasks) echo "$result" | cut -d'|' -f5 ;;
        open_issues) echo "$result" | cut -d'|' -f6 ;;
        goal_summary) echo "$result" | cut -d'|' -f7 ;;
    esac
}

# ========================================
# Positive Tests - Valid Goal Tracker
# ========================================

echo "--- Positive Tests: Valid Goal Tracker ---"
echo ""

# Test 1: Parse standard list format with AC items
echo "Test 1: Count AC items in standard list format"
cat > "$TEST_DIR/goal-tracker.md" << 'EOF'
# Goal Tracker

### Acceptance Criteria

- AC-1: First criterion
- AC-2: Second criterion
- AC-3: Third criterion

---

#### Active Tasks

| Task | Target AC | Status | Notes |
|------|-----------|--------|-------|
| Task 1 | AC-1 | pending | - |
| Task 2 | AC-2 | in_progress | - |
EOF

RESULT=$(humanize_parse_goal_tracker "$TEST_DIR/goal-tracker.md")
TOTAL_ACS=$(parse_result "$RESULT" total_acs)
if [[ "$TOTAL_ACS" == "3" ]]; then
    pass "Counts 3 AC items in list format"
else
    fail "Standard AC count" "3" "$TOTAL_ACS"
fi

# Test 2: Parse AC items in table format
echo ""
echo "Test 2: Count AC items in table format"
cat > "$TEST_DIR/goal-tracker-table.md" << 'EOF'
# Goal Tracker

### Acceptance Criteria

| AC-1 | Feature A works |
| AC-2 | Feature B works |
| AC-3 | Tests pass |

---

#### Active Tasks

| Task | Target AC | Status | Notes |
|------|-----------|--------|-------|
| Task 1 | AC-1 | pending | - |
EOF

RESULT=$(humanize_parse_goal_tracker "$TEST_DIR/goal-tracker-table.md")
TOTAL_ACS=$(parse_result "$RESULT" total_acs)
if [[ "$TOTAL_ACS" == "3" ]]; then
    pass "Counts 3 AC items in table format"
else
    fail "Table AC count" "3" "$TOTAL_ACS"
fi

# Test 3: Count active tasks correctly
echo ""
echo "Test 3: Count active tasks (excluding completed/deferred)"
cat > "$TEST_DIR/goal-tracker-tasks.md" << 'EOF'
# Goal Tracker

### Acceptance Criteria

- AC-1: First
- AC-2: Second

---

#### Active Tasks

| Task | Target AC | Status | Notes |
|------|-----------|--------|-------|
| Task 1 | AC-1 | pending | - |
| Task 2 | AC-1 | in_progress | - |
| Task 3 | AC-2 | completed | - |
| Task 4 | AC-2 | deferred | - |

### Completed and Verified

| AC | Task | Completed Round | Verified Round | Evidence |
|----|------|-----------------|----------------|----------|
EOF

RESULT=$(humanize_parse_goal_tracker "$TEST_DIR/goal-tracker-tasks.md")
ACTIVE_TASKS=$(parse_result "$RESULT" active_tasks)
# 4 total rows - 1 completed - 1 deferred = 2 active
if [[ "$ACTIVE_TASKS" == "2" ]]; then
    pass "Counts 2 active tasks (excluding completed/deferred)"
else
    fail "Active task count" "2" "$ACTIVE_TASKS"
fi

# Test 4: Count completed tasks in Completed section
echo ""
echo "Test 4: Count completed tasks in Completed section"
cat > "$TEST_DIR/goal-tracker-completed.md" << 'EOF'
# Goal Tracker

### Acceptance Criteria

- AC-1: First
- AC-2: Second

---

#### Active Tasks

| Task | Target AC | Status | Notes |
|------|-----------|--------|-------|
| (none) | - | - | - |

### Completed and Verified

| AC | Task | Completed Round | Verified Round | Evidence |
|----|------|-----------------|----------------|----------|
| AC-1 | Task 1 | 1 | 2 | tests pass |
| AC-1 | Task 2 | 1 | 2 | deployed |
| AC-2 | Task 3 | 2 | 3 | verified |

### Explicitly Deferred
EOF

RESULT=$(humanize_parse_goal_tracker "$TEST_DIR/goal-tracker-completed.md")
COMPLETED_TASKS=$(parse_result "$RESULT" completed_tasks)
COMPLETED_ACS=$(parse_result "$RESULT" completed_acs)
if [[ "$COMPLETED_TASKS" == "3" ]]; then
    pass "Counts 3 completed task rows"
else
    fail "Completed task count" "3" "$COMPLETED_TASKS"
fi

# Test 5: Count unique completed ACs
echo ""
echo "Test 5: Count unique completed ACs"
# Using same file from Test 4
if [[ "$COMPLETED_ACS" == "2" ]]; then
    pass "Counts 2 unique completed ACs (AC-1 and AC-2)"
else
    fail "Unique completed AC count" "2" "$COMPLETED_ACS"
fi

# Test 6: Extract goal summary
echo ""
echo "Test 6: Extract goal summary from Ultimate Goal section"
cat > "$TEST_DIR/goal-tracker-goal.md" << 'EOF'
# Goal Tracker

### Ultimate Goal

Build a comprehensive testing framework for shell scripts.

### Acceptance Criteria

- AC-1: Tests pass

---
EOF

RESULT=$(humanize_parse_goal_tracker "$TEST_DIR/goal-tracker-goal.md")
GOAL=$(parse_result "$RESULT" goal_summary)
if [[ "$GOAL" == *"comprehensive testing"* ]]; then
    pass "Extracts goal summary correctly"
else
    fail "Goal summary" "contains 'comprehensive testing'" "$GOAL"
fi

# ========================================
# Negative Tests - Edge Cases
# ========================================

echo ""
echo "--- Negative Tests: Edge Cases ---"
echo ""

# Test 7: Non-existent file returns defaults
echo "Test 7: Non-existent file returns default values"
RESULT=$(humanize_parse_goal_tracker "$TEST_DIR/nonexistent.md")
if [[ "$RESULT" == "0|0|0|0|0|0|No goal tracker" ]]; then
    pass "Returns default values for non-existent file"
else
    fail "Non-existent file" "0|0|0|0|0|0|No goal tracker" "$RESULT"
fi

# Test 8: Empty file returns zeros
echo ""
echo "Test 8: Empty file returns zero counts"
: > "$TEST_DIR/goal-tracker-empty.md"
RESULT=$(humanize_parse_goal_tracker "$TEST_DIR/goal-tracker-empty.md")
TOTAL_ACS=$(parse_result "$RESULT" total_acs)
if [[ "$TOTAL_ACS" == "0" ]]; then
    pass "Returns 0 total_acs for empty file"
else
    fail "Empty file AC count" "0" "$TOTAL_ACS"
fi

# Test 9: Large AC counts (60 items)
echo ""
echo "Test 9: Handle large AC counts (60 items)"
{
    echo "# Goal Tracker"
    echo ""
    echo "### Acceptance Criteria"
    echo ""
    for i in $(seq 1 60); do
        echo "- AC-$i: Criterion number $i"
    done
    echo ""
    echo "---"
} > "$TEST_DIR/goal-tracker-large.md"

RESULT=$(humanize_parse_goal_tracker "$TEST_DIR/goal-tracker-large.md")
TOTAL_ACS=$(parse_result "$RESULT" total_acs)
if [[ "$TOTAL_ACS" == "60" ]]; then
    pass "Handles 60 AC items without overflow"
else
    fail "Large AC count" "60" "$TOTAL_ACS"
fi

# Test 10: Special characters in AC descriptions
echo ""
echo "Test 10: Special characters in AC descriptions"
cat > "$TEST_DIR/goal-tracker-special.md" << 'EOF'
# Goal Tracker

### Acceptance Criteria

- AC-1: Handle $PATH variable expansion
- AC-2: Support `backticks` and "quotes"
- AC-3: Process <angle> & brackets

---
EOF

RESULT=$(humanize_parse_goal_tracker "$TEST_DIR/goal-tracker-special.md")
TOTAL_ACS=$(parse_result "$RESULT" total_acs)
if [[ "$TOTAL_ACS" == "3" ]]; then
    pass "Handles special characters in descriptions"
else
    fail "Special characters" "3" "$TOTAL_ACS"
fi

# Test 11: Missing table pipes (malformed)
echo ""
echo "Test 11: Malformed file without proper sections"
cat > "$TEST_DIR/goal-tracker-malformed.md" << 'EOF'
# Goal Tracker

Acceptance Criteria

AC-1 First criterion
AC-2 Second criterion

Active Tasks
Task 1 AC-1 pending
EOF

RESULT=$(humanize_parse_goal_tracker "$TEST_DIR/goal-tracker-malformed.md")
TOTAL_ACS=$(parse_result "$RESULT" total_acs)
# Without proper ### headers, counts should be 0 (graceful handling)
if [[ "$TOTAL_ACS" == "0" ]]; then
    pass "Returns 0 for malformed file without proper headers"
else
    fail "Malformed file" "0" "$TOTAL_ACS"
fi

# Test 12: Truncated file (incomplete markdown)
echo ""
echo "Test 12: Truncated/incomplete goal tracker"
cat > "$TEST_DIR/goal-tracker-truncated.md" << 'EOF'
# Goal Tracker

### Acceptance Criteria

- AC-1: First criterion
- AC-2: Sec
EOF

RESULT=$(humanize_parse_goal_tracker "$TEST_DIR/goal-tracker-truncated.md")
TOTAL_ACS=$(parse_result "$RESULT" total_acs)
# Should still count the AC items that are parseable
if [[ "$TOTAL_ACS" -ge "1" ]]; then
    pass "Handles truncated file gracefully (found $TOTAL_ACS AC items)"
else
    fail "Truncated file" ">=1" "$TOTAL_ACS"
fi

# Test 13: Binary content mixed in
echo ""
echo "Test 13: File with binary content"
cat > "$TEST_DIR/goal-tracker-binary.md" << 'EOF'
# Goal Tracker

### Acceptance Criteria

- AC-1: Normal criterion
EOF
printf '\x00\x01\x02\x03' >> "$TEST_DIR/goal-tracker-binary.md"
echo "" >> "$TEST_DIR/goal-tracker-binary.md"
echo "- AC-2: After binary" >> "$TEST_DIR/goal-tracker-binary.md"
echo "" >> "$TEST_DIR/goal-tracker-binary.md"
echo "---" >> "$TEST_DIR/goal-tracker-binary.md"

RESULT=$(humanize_parse_goal_tracker "$TEST_DIR/goal-tracker-binary.md")
TOTAL_ACS=$(parse_result "$RESULT" total_acs)
if [[ "$TOTAL_ACS" -ge "1" ]]; then
    pass "Handles binary content gracefully (found $TOTAL_ACS AC items)"
else
    fail "Binary content" ">=1" "$TOTAL_ACS"
fi

# Test 14: Count open issues
echo ""
echo "Test 14: Count open issues"
cat > "$TEST_DIR/goal-tracker-issues.md" << 'EOF'
# Goal Tracker

### Acceptance Criteria

- AC-1: Test

---

#### Active Tasks

| Task | Target AC | Status | Notes |
|------|-----------|--------|-------|

### Completed and Verified

### Explicitly Deferred

### Open Issues

| Issue | Discovered Round | Blocking AC | Resolution Path |
|-------|-----------------|-------------|-----------------|
| Bug in parser | 1 | AC-1 | Fix regex |
| Missing test | 2 | AC-2 | Add test |

EOF

RESULT=$(humanize_parse_goal_tracker "$TEST_DIR/goal-tracker-issues.md")
OPEN_ISSUES=$(parse_result "$RESULT" open_issues)
if [[ "$OPEN_ISSUES" == "2" ]]; then
    pass "Counts 2 open issues"
else
    fail "Open issues count" "2" "$OPEN_ISSUES"
fi

# Test 15: Count deferred tasks
echo ""
echo "Test 15: Count deferred tasks"
cat > "$TEST_DIR/goal-tracker-deferred.md" << 'EOF'
# Goal Tracker

### Acceptance Criteria

- AC-1: Test

---

### Explicitly Deferred

| Task | Original AC | Deferred Since | Justification | When to Reconsider |
|------|-------------|----------------|---------------|-------------------|
| Task A | AC-1 | Round 1 | Not needed now | Phase 2 |
| Task B | AC-2 | Round 2 | Blocked | After fix |

### Open Issues
EOF

RESULT=$(humanize_parse_goal_tracker "$TEST_DIR/goal-tracker-deferred.md")
DEFERRED_TASKS=$(parse_result "$RESULT" deferred_tasks)
if [[ "$DEFERRED_TASKS" == "2" ]]; then
    pass "Counts 2 deferred tasks"
else
    fail "Deferred tasks count" "2" "$DEFERRED_TASKS"
fi

# Test 16: File with only headers (no content)
echo ""
echo "Test 16: File with only section headers"
cat > "$TEST_DIR/goal-tracker-headers.md" << 'EOF'
# Goal Tracker

### Ultimate Goal

### Acceptance Criteria

---

#### Active Tasks

| Task | Target AC | Status | Notes |
|------|-----------|--------|-------|

### Completed and Verified

| AC | Task | Completed Round | Verified Round | Evidence |
|----|------|-----------------|----------------|----------|

### Explicitly Deferred

### Open Issues
EOF

RESULT=$(humanize_parse_goal_tracker "$TEST_DIR/goal-tracker-headers.md")
TOTAL_ACS=$(parse_result "$RESULT" total_acs)
ACTIVE_TASKS=$(parse_result "$RESULT" active_tasks)
if [[ "$TOTAL_ACS" == "0" ]] && [[ "$ACTIVE_TASKS" == "0" ]]; then
    pass "Returns zeros for file with only headers"
else
    fail "Headers only" "0 ACs, 0 active" "ACs=$TOTAL_ACS, active=$ACTIVE_TASKS"
fi

# Test 17: Mixed AC format (AC-1, **AC-2**, AC-3.1)
echo ""
echo "Test 17: Mixed AC formats with bold and sub-numbering"
cat > "$TEST_DIR/goal-tracker-mixed.md" << 'EOF'
# Goal Tracker

### Acceptance Criteria

- AC-1: Standard format
- **AC-2**: Bold format
- AC-3.1: Sub-criterion format (not counted - different pattern)

---
EOF

RESULT=$(humanize_parse_goal_tracker "$TEST_DIR/goal-tracker-mixed.md")
TOTAL_ACS=$(parse_result "$RESULT" total_acs)
# The regex matches AC-1 and **AC-2** but not AC-3.1 (has decimal)
if [[ "$TOTAL_ACS" -ge "2" ]]; then
    pass "Handles mixed AC formats (found $TOTAL_ACS)"
else
    fail "Mixed formats" ">=2" "$TOTAL_ACS"
fi

# Test 18: Very long goal summary (truncation)
echo ""
echo "Test 18: Very long goal summary truncation"
{
    echo "# Goal Tracker"
    echo ""
    echo "### Ultimate Goal"
    echo ""
    LONG_GOAL=$(printf 'x%.0s' {1..100})
    echo "This is a very long goal: $LONG_GOAL"
    echo ""
    echo "### Acceptance Criteria"
    echo "---"
} > "$TEST_DIR/goal-tracker-longgoal.md"

RESULT=$(humanize_parse_goal_tracker "$TEST_DIR/goal-tracker-longgoal.md")
GOAL=$(parse_result "$RESULT" goal_summary)
GOAL_LEN=${#GOAL}
# Goal summary should be truncated to 60 chars
if [[ "$GOAL_LEN" -le "60" ]]; then
    pass "Goal summary truncated to 60 chars (got $GOAL_LEN)"
else
    fail "Goal truncation" "<=60 chars" "$GOAL_LEN chars"
fi

# ========================================
# Summary
# ========================================

print_test_summary "Goal Tracker Robustness Test Summary"
exit $?
