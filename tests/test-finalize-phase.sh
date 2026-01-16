#!/bin/bash
#
# Tests for Finalize Phase feature
#
# Tests:
# - T-POS-1: COMPLETE triggers Finalize entry
# - T-POS-2: Finalize Phase completion flow
# - T-POS-3: Finalized-state detected as active loop
# - T-POS-4: Finalize summary file writable
# - T-POS-5: Normal RLCR rounds unaffected
# - T-NEG-1: Max iterations skips Finalize
# - T-NEG-2: Finalize still requires git clean
# - T-NEG-3: Finalize still requires summary
# - T-NEG-4: Finalize still requires todos complete
# - T-NEG-5: Finalized-state file protected
# - T-NEG-6: Complete-state not detected as active
# - T-NEG-7: Finalize phase does not trigger Codex
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Test helpers
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

pass() { echo -e "${GREEN}PASS${NC}: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}FAIL${NC}: $1"; echo "  Expected: $2"; echo "  Got: $3"; TESTS_FAILED=$((TESTS_FAILED + 1)); }
skip() { echo -e "${YELLOW}SKIP${NC}: $1 - $2"; TESTS_SKIPPED=$((TESTS_SKIPPED + 1)); }

# Setup test environment
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

# Source the loop-common.sh to get helper functions
source "$PROJECT_ROOT/hooks/lib/loop-common.sh"

echo "=== Test: Finalize Phase Feature ==="
echo ""

# ========================================
# Test T-POS-3: Finalized-state detected as active loop
# ========================================
echo "T-POS-3: finalized-state.md detected as active loop"
cd "$TEST_DIR"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "init" > init.txt
git add init.txt
git -c commit.gpgsign=false commit -q -m "Initial"

LOOP_DIR="$TEST_DIR/.humanize/rlcr/2024-01-01_12-00-00"
mkdir -p "$LOOP_DIR"

# Create finalized-state.md (Finalize Phase in progress)
cat > "$LOOP_DIR/finalized-state.md" << 'EOF'
---
current_round: 5
max_iterations: 42
plan_file: plan.md
plan_tracked: false
start_branch: main
---
EOF

export CLAUDE_PROJECT_DIR="$TEST_DIR"

ACTIVE_LOOP=$(find_active_loop "$TEST_DIR/.humanize/rlcr")
if [[ -n "$ACTIVE_LOOP" ]]; then
    pass "finalized-state.md detected as active loop"
else
    fail "finalized-state.md detection" "active loop found" "no active loop"
fi

# ========================================
# Test T-NEG-6: complete-state.md NOT detected as active loop
# ========================================
echo "T-NEG-6: complete-state.md not detected as active loop"
rm -f "$LOOP_DIR/finalized-state.md"
cat > "$LOOP_DIR/complete-state.md" << 'EOF'
---
current_round: 5
max_iterations: 42
---
EOF

ACTIVE_LOOP=$(find_active_loop "$TEST_DIR/.humanize/rlcr")
if [[ -z "$ACTIVE_LOOP" ]]; then
    pass "complete-state.md not detected as active loop"
else
    fail "complete-state.md detection" "no active loop" "$ACTIVE_LOOP"
fi

# ========================================
# Test: is_finalized_state_file_path helper function
# ========================================
echo "Test: is_finalized_state_file_path helper function"
if is_finalized_state_file_path "finalized-state.md"; then
    pass "is_finalized_state_file_path matches finalized-state.md"
else
    fail "is_finalized_state_file_path" "true" "false"
fi

if is_finalized_state_file_path "state.md"; then
    fail "is_finalized_state_file_path on state.md" "false" "true"
else
    pass "is_finalized_state_file_path does not match state.md"
fi

if is_finalized_state_file_path "/path/to/loop/finalized-state.md"; then
    pass "is_finalized_state_file_path matches full path"
else
    fail "is_finalized_state_file_path full path" "true" "false"
fi

# ========================================
# Test: is_finalize_summary_path helper function
# ========================================
echo "Test: is_finalize_summary_path helper function"
if is_finalize_summary_path "finalize-summary.md"; then
    pass "is_finalize_summary_path matches finalize-summary.md"
else
    fail "is_finalize_summary_path" "true" "false"
fi

if is_finalize_summary_path "round-0-summary.md"; then
    fail "is_finalize_summary_path on round-N-summary.md" "false" "true"
else
    pass "is_finalize_summary_path does not match round-N-summary.md"
fi

if is_finalize_summary_path "/path/to/loop/finalize-summary.md"; then
    pass "is_finalize_summary_path matches full path"
else
    fail "is_finalize_summary_path full path" "true" "false"
fi

# ========================================
# Test T-POS-5: state.md still detected (normal rounds unaffected)
# ========================================
echo "T-POS-5: Normal RLCR rounds unaffected (state.md still detected)"
rm -f "$LOOP_DIR/complete-state.md"
cat > "$LOOP_DIR/state.md" << 'EOF'
---
current_round: 3
max_iterations: 42
plan_file: plan.md
plan_tracked: false
start_branch: main
---
EOF

ACTIVE_LOOP=$(find_active_loop "$TEST_DIR/.humanize/rlcr")
if [[ -n "$ACTIVE_LOOP" ]]; then
    pass "state.md still detected as active loop (normal rounds)"
else
    fail "state.md detection" "active loop found" "no active loop"
fi

# ========================================
# Test: finalized-state.md takes precedence when both exist
# ========================================
echo "Test: finalized-state.md takes precedence when both state files exist"
# This shouldn't happen in practice, but test robustness
cat > "$LOOP_DIR/finalized-state.md" << 'EOF'
---
current_round: 5
max_iterations: 42
plan_file: plan.md
plan_tracked: false
start_branch: main
---
EOF

ACTIVE_LOOP=$(find_active_loop "$TEST_DIR/.humanize/rlcr")
if [[ -n "$ACTIVE_LOOP" ]]; then
    pass "Loop detected when both state.md and finalized-state.md exist"
else
    fail "Both state files" "active loop found" "no active loop"
fi

rm -f "$LOOP_DIR/finalized-state.md"

# ========================================
# Test: Newer directory with finalized-state.md takes precedence
# ========================================
echo "Test: Newer directory with finalized-state.md takes precedence"
NEWER_LOOP_DIR="$TEST_DIR/.humanize/rlcr/2024-01-02_12-00-00"
mkdir -p "$NEWER_LOOP_DIR"
cat > "$NEWER_LOOP_DIR/finalized-state.md" << 'EOF'
---
current_round: 8
max_iterations: 42
plan_file: new-plan.md
plan_tracked: false
start_branch: main
---
EOF

ACTIVE_LOOP=$(find_active_loop "$TEST_DIR/.humanize/rlcr")
if [[ "$ACTIVE_LOOP" == "$NEWER_LOOP_DIR" ]]; then
    pass "Newer directory with finalized-state.md takes precedence"
else
    fail "Newer directory precedence" "$NEWER_LOOP_DIR" "$ACTIVE_LOOP"
fi

# ========================================
# Test: finalized_state_file_blocked_message function exists
# ========================================
echo "Test: finalized_state_file_blocked_message function exists"
if type finalized_state_file_blocked_message &>/dev/null; then
    pass "finalized_state_file_blocked_message function exists"
else
    fail "finalized_state_file_blocked_message" "function defined" "function not found"
fi

# ========================================
# Test: finalized_state_file_blocked_message returns message
# ========================================
echo "Test: finalized_state_file_blocked_message returns message"
MSG=$(finalized_state_file_blocked_message 2>&1)
if [[ -n "$MSG" ]] && echo "$MSG" | grep -qi "finalized"; then
    pass "finalized_state_file_blocked_message returns appropriate message"
else
    fail "finalized_state_file_blocked_message message" "message containing 'finalized'" "$MSG"
fi

echo ""
echo "========================================="
echo "Test Results"
echo "========================================="
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
echo -e "Skipped: ${YELLOW}$TESTS_SKIPPED${NC}"
echo ""

exit $TESTS_FAILED
