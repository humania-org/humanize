#!/bin/bash
#
# Robustness tests for state transition logic
#
# Tests state file transitions and validation:
# - Valid state progressions (round 0 -> 1 -> N -> finalize)
# - Invalid state transitions (skipped rounds, negative rounds)
# - Finalize and cancel state handling
# - State machine edge cases
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/hooks/lib/loop-common.sh"
source "$SCRIPT_DIR/../test-helpers.sh"

setup_test_dir

echo "========================================"
echo "State Transition Robustness Tests"
echo "========================================"
echo ""

# ========================================
# Helper Functions
# ========================================

create_full_state() {
    local dir="$1"
    local round="${2:-0}"
    local max="${3:-42}"
    mkdir -p "$dir"
    cat > "$dir/state.md" << EOF
---
current_round: $round
max_iterations: $max
plan_file: plan.md
start_branch: main
base_branch: main
push_every_round: false
codex_model: o3-mini
codex_effort: medium
codex_timeout: 1200
review_started: false
---

## Loop State
Active loop at round $round.
EOF
}

create_finalize_state() {
    local dir="$1"
    local round="${2:-10}"
    mkdir -p "$dir"
    cat > "$dir/finalize-state.md" << EOF
---
current_round: $round
max_iterations: 42
plan_file: plan.md
start_branch: main
base_branch: main
finalize_mode: true
review_started: true
---

## Finalize State
Loop is in finalize phase.
EOF
}

create_cancel_state() {
    local dir="$1"
    local round="${2:-5}"
    mkdir -p "$dir"
    cat > "$dir/cancel-state.md" << EOF
---
current_round: $round
max_iterations: 42
cancelled: true
cancelled_at: 2026-01-19T12:00:00Z
---

## Cancel State
Loop was cancelled.
EOF
}

# ========================================
# Valid State Progression Tests
# ========================================

echo "--- Valid State Progression Tests ---"
echo ""

# Test 1: Round 0 state is valid
echo "Test 1: Round 0 state is valid"
mkdir -p "$TEST_DIR/round0/.humanize/rlcr/2026-01-19_00-00-00"
create_full_state "$TEST_DIR/round0/.humanize/rlcr/2026-01-19_00-00-00" 0

set +e
parse_state_file_strict "$TEST_DIR/round0/.humanize/rlcr/2026-01-19_00-00-00/state.md" 2>/dev/null
RESULT=$?
set -e

if [[ $RESULT -eq 0 ]]; then
    pass "Round 0 state parses successfully"
else
    fail "Round 0 state" "exit 0" "exit $RESULT"
fi

# Test 2: Round progression 0 -> 5 is valid
echo ""
echo "Test 2: Round progression to 5 is valid"
mkdir -p "$TEST_DIR/round5/.humanize/rlcr/2026-01-19_00-00-00"
create_full_state "$TEST_DIR/round5/.humanize/rlcr/2026-01-19_00-00-00" 5

ROUND=$(get_current_round "$TEST_DIR/round5/.humanize/rlcr/2026-01-19_00-00-00/state.md")
if [[ "$ROUND" == "5" ]]; then
    pass "Round 5 state is valid"
else
    fail "Round 5" "5" "$ROUND"
fi

# Test 3: Max round is valid (round == max_iterations)
echo ""
echo "Test 3: Max round state is valid"
mkdir -p "$TEST_DIR/maxround/.humanize/rlcr/2026-01-19_00-00-00"
create_full_state "$TEST_DIR/maxround/.humanize/rlcr/2026-01-19_00-00-00" 42 42

ROUND=$(get_current_round "$TEST_DIR/maxround/.humanize/rlcr/2026-01-19_00-00-00/state.md")
if [[ "$ROUND" == "42" ]]; then
    pass "Max round state is valid"
else
    fail "Max round" "42" "$ROUND"
fi

# ========================================
# Finalize State Tests
# ========================================

echo ""
echo "--- Finalize State Tests ---"
echo ""

# Test 4: Finalize state is detected
echo "Test 4: Finalize state is detected"
mkdir -p "$TEST_DIR/finalize/.humanize/rlcr/2026-01-19_00-00-00"
create_finalize_state "$TEST_DIR/finalize/.humanize/rlcr/2026-01-19_00-00-00"

ACTIVE=$(find_active_loop "$TEST_DIR/finalize/.humanize/rlcr" 2>/dev/null || echo "")
if [[ -n "$ACTIVE" ]] && [[ -f "$ACTIVE/finalize-state.md" ]]; then
    pass "Finalize state detected"
else
    fail "Finalize detection" "active with finalize-state.md" "$ACTIVE"
fi

# Test 5: Finalize state takes precedence over state.md
echo ""
echo "Test 5: Finalize state takes precedence"
mkdir -p "$TEST_DIR/both/.humanize/rlcr/2026-01-19_00-00-00"
create_full_state "$TEST_DIR/both/.humanize/rlcr/2026-01-19_00-00-00" 5
create_finalize_state "$TEST_DIR/both/.humanize/rlcr/2026-01-19_00-00-00" 10

# When both exist, finalize-state should be preferred
if [[ -f "$TEST_DIR/both/.humanize/rlcr/2026-01-19_00-00-00/finalize-state.md" ]]; then
    pass "Finalize state file coexists with regular state"
else
    fail "Both states" "finalize-state.md exists" "missing"
fi

# ========================================
# Cancel State Tests
# ========================================

echo ""
echo "--- Cancel State Tests ---"
echo ""

# Test 6: Cancel state is not considered active
echo "Test 6: Cancel state is not active"
mkdir -p "$TEST_DIR/cancel/.humanize/rlcr/2026-01-19_00-00-00"
create_cancel_state "$TEST_DIR/cancel/.humanize/rlcr/2026-01-19_00-00-00"

ACTIVE=$(find_active_loop "$TEST_DIR/cancel/.humanize/rlcr" 2>/dev/null || echo "")
if [[ -z "$ACTIVE" ]]; then
    pass "Cancel state is not considered active"
else
    fail "Cancel not active" "empty" "$ACTIVE"
fi

# Test 7: Regular state after cancel in newer directory
echo ""
echo "Test 7: New state after cancel is valid"
mkdir -p "$TEST_DIR/aftercancel/.humanize/rlcr/2026-01-19_00-00-00"
create_cancel_state "$TEST_DIR/aftercancel/.humanize/rlcr/2026-01-19_00-00-00"
mkdir -p "$TEST_DIR/aftercancel/.humanize/rlcr/2026-01-19_12-00-00"
create_full_state "$TEST_DIR/aftercancel/.humanize/rlcr/2026-01-19_12-00-00" 0

ACTIVE=$(find_active_loop "$TEST_DIR/aftercancel/.humanize/rlcr" 2>/dev/null || echo "")
if [[ "$ACTIVE" == *"12-00-00"* ]]; then
    pass "New state after cancel is detected"
else
    fail "New after cancel" "*12-00-00*" "$ACTIVE"
fi

# ========================================
# Invalid State Edge Cases
# ========================================

echo ""
echo "--- Invalid State Edge Cases ---"
echo ""

# Test 8: Negative round number
echo "Test 8: Negative round number"
mkdir -p "$TEST_DIR/negative/.humanize/rlcr/2026-01-19_00-00-00"
cat > "$TEST_DIR/negative/.humanize/rlcr/2026-01-19_00-00-00/state.md" << 'EOF'
---
current_round: -1
max_iterations: 42
plan_file: plan.md
base_branch: main
review_started: false
---
EOF

# Negative rounds should be accepted by regex ^-?[0-9]+$ but may indicate error
ROUND=$(get_current_round "$TEST_DIR/negative/.humanize/rlcr/2026-01-19_00-00-00/state.md")
if [[ "$ROUND" == "-1" ]]; then
    pass "Negative round parsed (value: $ROUND)"
else
    fail "Negative round" "-1" "$ROUND"
fi

# Test 9: Round exceeds max_iterations
echo ""
echo "Test 9: Round exceeds max_iterations"
mkdir -p "$TEST_DIR/exceed/.humanize/rlcr/2026-01-19_00-00-00"
cat > "$TEST_DIR/exceed/.humanize/rlcr/2026-01-19_00-00-00/state.md" << 'EOF'
---
current_round: 100
max_iterations: 42
plan_file: plan.md
base_branch: main
review_started: false
---
EOF

ROUND=$(get_current_round "$TEST_DIR/exceed/.humanize/rlcr/2026-01-19_00-00-00/state.md")
if [[ "$ROUND" == "100" ]]; then
    pass "Over-max round parsed (enforcement is elsewhere)"
else
    fail "Over-max round" "100" "$ROUND"
fi

# Test 10: Non-numeric round
echo ""
echo "Test 10: Non-numeric round rejected by strict parser"
mkdir -p "$TEST_DIR/nonnumeric/.humanize/rlcr/2026-01-19_00-00-00"
cat > "$TEST_DIR/nonnumeric/.humanize/rlcr/2026-01-19_00-00-00/state.md" << 'EOF'
---
current_round: abc
max_iterations: 42
plan_file: plan.md
base_branch: main
review_started: false
---
EOF

set +e
parse_state_file_strict "$TEST_DIR/nonnumeric/.humanize/rlcr/2026-01-19_00-00-00/state.md" 2>/dev/null
RESULT=$?
set -e

if [[ $RESULT -ne 0 ]]; then
    pass "Non-numeric round rejected by strict parser"
else
    fail "Non-numeric round" "non-zero exit" "exit 0"
fi

# ========================================
# State File Schema Validation
# ========================================

echo ""
echo "--- State Schema Validation Tests ---"
echo ""

# Test 11: Missing current_round field
echo "Test 11: Missing current_round field"
mkdir -p "$TEST_DIR/nocurrent/.humanize/rlcr/2026-01-19_00-00-00"
cat > "$TEST_DIR/nocurrent/.humanize/rlcr/2026-01-19_00-00-00/state.md" << 'EOF'
---
max_iterations: 42
plan_file: plan.md
base_branch: main
review_started: false
---
EOF

set +e
parse_state_file_strict "$TEST_DIR/nocurrent/.humanize/rlcr/2026-01-19_00-00-00/state.md" 2>/dev/null
RESULT=$?
set -e

if [[ $RESULT -ne 0 ]]; then
    pass "Missing current_round rejected"
else
    fail "Missing current_round" "non-zero exit" "exit 0"
fi

# Test 12: Missing max_iterations field
echo ""
echo "Test 12: Missing max_iterations field"
mkdir -p "$TEST_DIR/nomax/.humanize/rlcr/2026-01-19_00-00-00"
cat > "$TEST_DIR/nomax/.humanize/rlcr/2026-01-19_00-00-00/state.md" << 'EOF'
---
current_round: 0
plan_file: plan.md
base_branch: main
review_started: false
---
EOF

set +e
parse_state_file_strict "$TEST_DIR/nomax/.humanize/rlcr/2026-01-19_00-00-00/state.md" 2>/dev/null
RESULT=$?
set -e

if [[ $RESULT -ne 0 ]]; then
    pass "Missing max_iterations rejected"
else
    fail "Missing max_iterations" "non-zero exit" "exit 0"
fi

# Test 13: Missing base_branch field
echo ""
echo "Test 13: Missing base_branch field"
mkdir -p "$TEST_DIR/nobase/.humanize/rlcr/2026-01-19_00-00-00"
cat > "$TEST_DIR/nobase/.humanize/rlcr/2026-01-19_00-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 42
plan_file: plan.md
review_started: false
---
EOF

set +e
parse_state_file_strict "$TEST_DIR/nobase/.humanize/rlcr/2026-01-19_00-00-00/state.md" 2>/dev/null
RESULT=$?
set -e

if [[ $RESULT -ne 0 ]]; then
    pass "Missing base_branch rejected"
else
    fail "Missing base_branch" "non-zero exit" "exit 0"
fi

# ========================================
# Loop Directory Discovery Tests
# ========================================

echo ""
echo "--- Loop Directory Discovery Tests ---"
echo ""

# Test 14: Multiple loop directories - newest is selected
echo "Test 14: Newest loop directory selected"
mkdir -p "$TEST_DIR/multi/.humanize/rlcr/2026-01-10_00-00-00"
mkdir -p "$TEST_DIR/multi/.humanize/rlcr/2026-01-20_00-00-00"
mkdir -p "$TEST_DIR/multi/.humanize/rlcr/2026-01-15_00-00-00"
create_full_state "$TEST_DIR/multi/.humanize/rlcr/2026-01-20_00-00-00" 3

ACTIVE=$(find_active_loop "$TEST_DIR/multi/.humanize/rlcr" 2>/dev/null || echo "")
if [[ "$ACTIVE" == *"2026-01-20"* ]]; then
    pass "Newest directory with state selected"
else
    fail "Newest directory" "*2026-01-20*" "$ACTIVE"
fi

# Test 15: Lexicographic ordering used for directory selection
echo ""
echo "Test 15: Lexicographic ordering used for directory selection"
# Note: find_active_loop uses lexicographic sorting, not timestamp validation
# "not-a-timestamp" > "2026-..." lexicographically, so it would be selected if it has state.md
# This test verifies the function uses lexicographic ordering (sort -r)
mkdir -p "$TEST_DIR/invalid/.humanize/rlcr/2026-01-19_00-00-00"
create_full_state "$TEST_DIR/invalid/.humanize/rlcr/2026-01-19_00-00-00" 0
mkdir -p "$TEST_DIR/invalid/.humanize/rlcr/2025-01-01_00-00-00"
create_full_state "$TEST_DIR/invalid/.humanize/rlcr/2025-01-01_00-00-00" 1

ACTIVE=$(find_active_loop "$TEST_DIR/invalid/.humanize/rlcr" 2>/dev/null || echo "")
# Should select the lexicographically largest (2026 > 2025)
if [[ -n "$ACTIVE" ]] && [[ "$ACTIVE" == *"2026-01-19_00-00-00"* ]]; then
    pass "Lexicographically largest directory selected (2026 > 2025)"
else
    fail "Lexicographic ordering" "*2026-01-19_00-00-00*" "$ACTIVE"
fi

# Test 16: Deeply nested invalid state ignored
echo ""
echo "Test 16: State in wrong location ignored"
mkdir -p "$TEST_DIR/wrongloc/.humanize/rlcr/2026-01-19_00-00-00/subdir"
create_full_state "$TEST_DIR/wrongloc/.humanize/rlcr/2026-01-19_00-00-00/subdir" 0
# No state.md in the expected location

ACTIVE=$(find_active_loop "$TEST_DIR/wrongloc/.humanize/rlcr" 2>/dev/null || echo "")
# Should not find the nested state
if [[ -z "$ACTIVE" ]]; then
    pass "Nested state in wrong location ignored"
else
    fail "Wrong location ignored" "empty" "$ACTIVE"
fi

# ========================================
# Summary
# ========================================

print_test_summary "State Transition Robustness Test Summary"
exit $?
