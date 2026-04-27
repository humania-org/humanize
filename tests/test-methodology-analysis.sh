#!/usr/bin/env bash
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/hooks/lib/methodology-analysis.sh"

PASSED=0
FAILED=0

pass() {
    echo "PASS: $1"
    PASSED=$((PASSED + 1))
}

fail() {
    echo "FAIL: $1"
    echo "  expected: $2"
    echo "  actual:   $3"
    FAILED=$((FAILED + 1))
}

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

echo "=== Test: methodology analysis completion ==="

LOOP_DIR="$TEST_DIR/loop"
mkdir -p "$LOOP_DIR"
echo "active state" > "$LOOP_DIR/methodology-analysis-state.md"
echo "complete" > "$LOOP_DIR/.methodology-exit-reason"
echo "analysis report" > "$LOOP_DIR/methodology-analysis-report.md"
echo "done" > "$LOOP_DIR/methodology-analysis-done.md"

if methodology_analysis_ready_to_complete; then
    if [[ -f "$LOOP_DIR/methodology-analysis-state.md" && ! -e "$LOOP_DIR/complete-state.md" ]]; then
        pass "methodology readiness check does not rename active state"
    else
        fail "methodology readiness check does not rename active state" "active state remains, terminal state absent" "$(ls "$LOOP_DIR")"
    fi
else
    fail "methodology readiness check succeeds" "exit 0" "non-zero"
fi

if complete_methodology_analysis; then
    if [[ ! -e "$LOOP_DIR/methodology-analysis-state.md" && -f "$LOOP_DIR/complete-state.md" && ! -e "$LOOP_DIR/.methodology-exit-reason" ]]; then
        pass "methodology completion finalizes state after readiness"
    else
        fail "methodology completion finalizes state after readiness" "terminal state exists and marker removed" "$(ls -a "$LOOP_DIR")"
    fi
else
    fail "methodology completion succeeds" "exit 0" "non-zero"
fi

echo ""
echo "=== Methodology Analysis Test Summary ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"

if [[ "$FAILED" -ne 0 ]]; then
    exit 1
fi

exit 0
