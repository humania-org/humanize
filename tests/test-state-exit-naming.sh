#!/bin/bash
#
# Tests for state.md rename on exit
#
# Tests:
# - complete-state.md on COMPLETE
# - stop-state.md on STOP
# - maxiter-state.md on max iterations
# - cancel-state.md on cancel
# - unexpected-state.md on schema error
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

echo "=== Test: State Exit Naming Conventions ==="
echo ""

# Test 1: Only state.md indicates active loop
echo "Test 1: Only state.md indicates active loop"
cd "$TEST_DIR"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "init" > init.txt
git add init.txt
git commit -q -m "Initial"

LOOP_DIR="$TEST_DIR/.humanize/rlcr/2024-01-01_12-00-00"
mkdir -p "$LOOP_DIR"

# Create completed state (should not be detected as active)
cat > "$LOOP_DIR/complete-state.md" << 'EOF'
---
current_round: 5
max_iterations: 42
plan_file: plan.md
plan_tracked: false
start_branch: main
---
EOF

export CLAUDE_PROJECT_DIR="$TEST_DIR"

# Source the loop-common.sh to get find_active_loop
source "$PROJECT_ROOT/hooks/lib/loop-common.sh"

ACTIVE_LOOP=$(find_active_loop "$TEST_DIR/.humanize/rlcr")
if [[ -z "$ACTIVE_LOOP" ]]; then
    pass "complete-state.md not detected as active loop"
else
    fail "complete-state.md detection" "no active loop" "$ACTIVE_LOOP"
fi

# Test 2: state.md IS detected as active loop
echo "Test 2: state.md is detected as active loop"
cat > "$LOOP_DIR/state.md" << 'EOF'
---
current_round: 0
max_iterations: 42
plan_file: plan.md
plan_tracked: false
start_branch: main
---
EOF

ACTIVE_LOOP=$(find_active_loop "$TEST_DIR/.humanize/rlcr")
if [[ -n "$ACTIVE_LOOP" ]]; then
    pass "state.md detected as active loop"
else
    fail "state.md detection" "active loop found" "no active loop"
fi

# Test 3: cancel-state.md not detected as active
echo "Test 3: cancel-state.md not detected as active loop"
rm -f "$LOOP_DIR/state.md"
cat > "$LOOP_DIR/cancel-state.md" << 'EOF'
---
current_round: 3
max_iterations: 42
---
EOF

ACTIVE_LOOP=$(find_active_loop "$TEST_DIR/.humanize/rlcr")
if [[ -z "$ACTIVE_LOOP" ]]; then
    pass "cancel-state.md not detected as active loop"
else
    fail "cancel-state.md detection" "no active loop" "$ACTIVE_LOOP"
fi

# Test 4: unexpected-state.md not detected as active
echo "Test 4: unexpected-state.md not detected as active loop"
cat > "$LOOP_DIR/unexpected-state.md" << 'EOF'
---
current_round: 2
---
EOF

ACTIVE_LOOP=$(find_active_loop "$TEST_DIR/.humanize/rlcr")
if [[ -z "$ACTIVE_LOOP" ]]; then
    pass "unexpected-state.md not detected as active loop"
else
    fail "unexpected-state.md detection" "no active loop" "$ACTIVE_LOOP"
fi

# Test 5: maxiter-state.md not detected as active
echo "Test 5: maxiter-state.md not detected as active loop"
cat > "$LOOP_DIR/maxiter-state.md" << 'EOF'
---
current_round: 42
max_iterations: 42
---
EOF

ACTIVE_LOOP=$(find_active_loop "$TEST_DIR/.humanize/rlcr")
if [[ -z "$ACTIVE_LOOP" ]]; then
    pass "maxiter-state.md not detected as active loop"
else
    fail "maxiter-state.md detection" "no active loop" "$ACTIVE_LOOP"
fi

# Test 6: stop-state.md not detected as active
echo "Test 6: stop-state.md not detected as active loop"
cat > "$LOOP_DIR/stop-state.md" << 'EOF'
---
current_round: 9
max_iterations: 42
---
EOF

ACTIVE_LOOP=$(find_active_loop "$TEST_DIR/.humanize/rlcr")
if [[ -z "$ACTIVE_LOOP" ]]; then
    pass "stop-state.md not detected as active loop"
else
    fail "stop-state.md detection" "no active loop" "$ACTIVE_LOOP"
fi

# Test 7: Newer directory with state.md takes precedence
echo "Test 7: Newer directory with state.md takes precedence"
NEWER_LOOP_DIR="$TEST_DIR/.humanize/rlcr/2024-01-02_12-00-00"
mkdir -p "$NEWER_LOOP_DIR"
cat > "$NEWER_LOOP_DIR/state.md" << 'EOF'
---
current_round: 0
max_iterations: 10
plan_file: new-plan.md
plan_tracked: false
start_branch: main
---
EOF

ACTIVE_LOOP=$(find_active_loop "$TEST_DIR/.humanize/rlcr")
if [[ "$ACTIVE_LOOP" == "$NEWER_LOOP_DIR" ]]; then
    pass "Newer directory with state.md takes precedence"
else
    fail "Newer directory precedence" "$NEWER_LOOP_DIR" "$ACTIVE_LOOP"
fi

echo ""
echo "=== Test: end_loop() Function ==="
echo ""

# Test 8: end_loop rejects invalid reason
echo "Test 8: end_loop rejects invalid reason"
END_LOOP_TEST_DIR="$TEST_DIR/.humanize/rlcr/2024-01-03_12-00-00"
mkdir -p "$END_LOOP_TEST_DIR"
cat > "$END_LOOP_TEST_DIR/state.md" << 'EOF'
---
current_round: 0
---
EOF

set +e
RESULT=$(end_loop "$END_LOOP_TEST_DIR" "$END_LOOP_TEST_DIR/state.md" "invalid_reason" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -ne 0 ]] && echo "$RESULT" | grep -q "Invalid end_loop reason"; then
    pass "end_loop rejects invalid reason"
else
    fail "end_loop invalid reason" "exit 1 with invalid reason error" "exit $EXIT_CODE: $RESULT"
fi

# Test 9: end_loop creates correct file for each valid reason
echo "Test 9: end_loop creates correct files for valid reasons"
REASONS_PASS=true
for reason in complete cancel maxiter stop unexpected; do
    mkdir -p "$END_LOOP_TEST_DIR"
    cat > "$END_LOOP_TEST_DIR/state.md" << 'EOF'
---
current_round: 0
---
EOF
    set +e
    end_loop "$END_LOOP_TEST_DIR" "$END_LOOP_TEST_DIR/state.md" "$reason" >/dev/null 2>&1
    EXIT_CODE=$?
    set -e
    EXPECTED_FILE="$END_LOOP_TEST_DIR/${reason}-state.md"
    if [[ $EXIT_CODE -ne 0 ]] || [[ ! -f "$EXPECTED_FILE" ]]; then
        fail "end_loop $reason" "$EXPECTED_FILE exists" "exit $EXIT_CODE, file exists: $(test -f "$EXPECTED_FILE" && echo yes || echo no)"
        REASONS_PASS=false
        break
    fi
    rm -f "$EXPECTED_FILE"
done
if [[ "$REASONS_PASS" == "true" ]]; then
    pass "end_loop creates correct files for all valid reasons"
fi

# Test 10: end_loop handles missing state file
echo "Test 10: end_loop handles missing state file gracefully"
rm -f "$END_LOOP_TEST_DIR/state.md"
set +e
RESULT=$(end_loop "$END_LOOP_TEST_DIR" "$END_LOOP_TEST_DIR/state.md" "complete" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -ne 0 ]] && echo "$RESULT" | grep -q "State file not found"; then
    pass "end_loop handles missing state file"
else
    fail "end_loop missing state file" "exit 1 with not found warning" "exit $EXIT_CODE: $RESULT"
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
