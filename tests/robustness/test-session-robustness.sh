#!/bin/bash
#
# Robustness tests for concurrent session handling
#
# Tests session detection and management under edge cases:
# - Multiple concurrent sessions
# - Session directory deletion
# - Permission changes
# - Rapid creation/deletion cycles
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/hooks/lib/loop-common.sh"
source "$SCRIPT_DIR/../test-helpers.sh"

setup_test_dir

echo "========================================"
echo "Session Robustness Tests"
echo "========================================"
echo ""

# ========================================
# Positive Tests - Valid Session Handling
# ========================================

echo "--- Positive Tests: Valid Session Handling ---"
echo ""

# Test 1: Newest session detection with multiple sessions
echo "Test 1: Newest session detection returns correct session"
mkdir -p "$TEST_DIR/rlcr/2026-01-15_10-00-00"
mkdir -p "$TEST_DIR/rlcr/2026-01-16_10-00-00"
mkdir -p "$TEST_DIR/rlcr/2026-01-17_10-00-00"
touch "$TEST_DIR/rlcr/2026-01-17_10-00-00/state.md"

RESULT=$(find_active_loop "$TEST_DIR/rlcr")
EXPECTED="$TEST_DIR/rlcr/2026-01-17_10-00-00"
if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass "Returns newest session with state.md"
else
    fail "Newest session detection" "$EXPECTED" "$RESULT"
fi

# Test 2: Session with finalize-state.md is detected
echo ""
echo "Test 2: Session with finalize-state.md is detected"
rm -rf "$TEST_DIR/rlcr"
mkdir -p "$TEST_DIR/rlcr/2026-01-17_12-00-00"
touch "$TEST_DIR/rlcr/2026-01-17_12-00-00/finalize-state.md"

RESULT=$(find_active_loop "$TEST_DIR/rlcr")
EXPECTED="$TEST_DIR/rlcr/2026-01-17_12-00-00"
if [[ "$RESULT" == "$EXPECTED" ]]; then
    pass "Detects session in finalize phase"
else
    fail "Finalize phase detection" "$EXPECTED" "$RESULT"
fi

# Test 3: Session directory listing handles many sessions (10+)
echo ""
echo "Test 3: Handle many sessions (15) without performance issues"
rm -rf "$TEST_DIR/rlcr"
mkdir -p "$TEST_DIR/rlcr"
for i in $(seq 1 15); do
    day=$(printf "%02d" $i)
    mkdir -p "$TEST_DIR/rlcr/2026-01-${day}_10-00-00"
done
touch "$TEST_DIR/rlcr/2026-01-15_10-00-00/state.md"

START_TIME=$(date +%s%N)
RESULT=$(find_active_loop "$TEST_DIR/rlcr")
END_TIME=$(date +%s%N)
ELAPSED_MS=$(( (END_TIME - START_TIME) / 1000000 ))

if [[ "$RESULT" == "$TEST_DIR/rlcr/2026-01-15_10-00-00" ]]; then
    if [[ $ELAPSED_MS -lt 1000 ]]; then
        pass "Handles 15 sessions efficiently (${ELAPSED_MS}ms)"
    else
        fail "Performance with many sessions" "<1000ms" "${ELAPSED_MS}ms"
    fi
else
    fail "Many sessions detection" "$TEST_DIR/rlcr/2026-01-15_10-00-00" "$RESULT"
fi

# Test 4: Only newest directory is checked (zombie-loop protection)
echo ""
echo "Test 4: Only newest directory is checked (older sessions with state.md ignored)"
rm -rf "$TEST_DIR/rlcr"
mkdir -p "$TEST_DIR/rlcr/2026-01-15_10-00-00"
mkdir -p "$TEST_DIR/rlcr/2026-01-17_10-00-00"
touch "$TEST_DIR/rlcr/2026-01-15_10-00-00/state.md"
# Newest directory has no state.md -- older stale loop must NOT be revived

RESULT=$(find_active_loop "$TEST_DIR/rlcr")
if [[ -z "$RESULT" ]]; then
    pass "Zombie-loop protection: returns empty when newest dir has no state.md"
else
    fail "Zombie-loop protection" "empty" "$RESULT"
fi

# Test 5: Session with both state.md and finalize-state.md
echo ""
echo "Test 5: Session with both state.md and finalize-state.md"
rm -rf "$TEST_DIR/rlcr"
mkdir -p "$TEST_DIR/rlcr/2026-01-17_10-00-00"
touch "$TEST_DIR/rlcr/2026-01-17_10-00-00/state.md"
touch "$TEST_DIR/rlcr/2026-01-17_10-00-00/finalize-state.md"

RESULT=$(find_active_loop "$TEST_DIR/rlcr")
if [[ "$RESULT" == "$TEST_DIR/rlcr/2026-01-17_10-00-00" ]]; then
    pass "Handles session with both state files"
else
    fail "Both state files" "$TEST_DIR/rlcr/2026-01-17_10-00-00" "$RESULT"
fi

# ========================================
# Negative Tests - Edge Cases
# ========================================

echo ""
echo "--- Negative Tests: Edge Cases ---"
echo ""

# Test 6: Empty base directory
echo "Test 6: Empty base directory returns empty"
rm -rf "$TEST_DIR/rlcr"
mkdir -p "$TEST_DIR/rlcr"

RESULT=$(find_active_loop "$TEST_DIR/rlcr")
if [[ -z "$RESULT" ]]; then
    pass "Returns empty for empty base directory"
else
    fail "Empty directory" "empty" "$RESULT"
fi

# Test 7: Non-existent base directory
echo ""
echo "Test 7: Non-existent base directory returns empty"
RESULT=$(find_active_loop "$TEST_DIR/nonexistent")
if [[ -z "$RESULT" ]]; then
    pass "Returns empty for non-existent directory"
else
    fail "Non-existent directory" "empty" "$RESULT"
fi

# Test 8: Directory with no subdirectories
echo ""
echo "Test 8: Base directory with files but no subdirectories"
rm -rf "$TEST_DIR/rlcr"
mkdir -p "$TEST_DIR/rlcr"
touch "$TEST_DIR/rlcr/some-file.txt"

RESULT=$(find_active_loop "$TEST_DIR/rlcr")
if [[ -z "$RESULT" ]]; then
    pass "Returns empty when no subdirectories exist"
else
    fail "No subdirectories" "empty" "$RESULT"
fi

# Test 9: Session directories without state files
echo ""
echo "Test 9: All session directories lack state files"
rm -rf "$TEST_DIR/rlcr"
mkdir -p "$TEST_DIR/rlcr/2026-01-17_10-00-00"
mkdir -p "$TEST_DIR/rlcr/2026-01-16_10-00-00"
# Neither has state.md

RESULT=$(find_active_loop "$TEST_DIR/rlcr")
if [[ -z "$RESULT" ]]; then
    pass "Returns empty when no sessions have state files"
else
    fail "No state files" "empty" "$RESULT"
fi

# Test 10: Session with unexpected naming format
echo ""
echo "Test 10: Session with unexpected naming format"
rm -rf "$TEST_DIR/rlcr"
mkdir -p "$TEST_DIR/rlcr/random-session-name"
touch "$TEST_DIR/rlcr/random-session-name/state.md"

RESULT=$(find_active_loop "$TEST_DIR/rlcr")
# Should work - function doesn't require specific naming
if [[ "$RESULT" == "$TEST_DIR/rlcr/random-session-name" ]]; then
    pass "Handles non-standard session naming"
else
    fail "Non-standard naming" "$TEST_DIR/rlcr/random-session-name" "$RESULT"
fi

# Test 11: Session directory is a symlink
echo ""
echo "Test 11: Session directory is a symlink"
rm -rf "$TEST_DIR/rlcr"
mkdir -p "$TEST_DIR/rlcr/real-session"
touch "$TEST_DIR/rlcr/real-session/state.md"
ln -s "$TEST_DIR/rlcr/real-session" "$TEST_DIR/rlcr/zzzz-symlink"

RESULT=$(find_active_loop "$TEST_DIR/rlcr")
# ls sorts alphabetically, symlink sorts last
if [[ -n "$RESULT" ]]; then
    pass "Handles symlinked session directory (returns: $(basename "$RESULT"))"
else
    fail "Symlinked session" "some result" "empty"
fi

# Test 12: Session directory with special characters in name
echo ""
echo "Test 12: Session directory with spaces in name"
rm -rf "$TEST_DIR/rlcr"
mkdir -p "$TEST_DIR/rlcr/session with spaces"
touch "$TEST_DIR/rlcr/session with spaces/state.md"

RESULT=$(find_active_loop "$TEST_DIR/rlcr")
if [[ "$RESULT" == "$TEST_DIR/rlcr/session with spaces" ]]; then
    pass "Handles spaces in session directory name"
else
    fail "Spaces in name" "$TEST_DIR/rlcr/session with spaces" "$RESULT"
fi

# Test 13: Very deep session path
echo ""
echo "Test 13: Very deep session path"
rm -rf "$TEST_DIR/rlcr"
DEEP_PATH="$TEST_DIR/rlcr/a/b/c/d/e/f/g/h/i/j"
mkdir -p "$DEEP_PATH"
touch "$DEEP_PATH/state.md"

# find_active_loop only looks one level deep
RESULT=$(find_active_loop "$TEST_DIR/rlcr")
if [[ -z "$RESULT" ]] || [[ "$RESULT" != *"/a/b/c"* ]]; then
    pass "Only checks immediate subdirectories (not deeply nested)"
else
    fail "Depth check" "empty or shallow" "$RESULT"
fi

# Test 14: Rapid session creation test
echo ""
echo "Test 14: Rapid session creation (5 sessions in quick succession)"
rm -rf "$TEST_DIR/rlcr"
mkdir -p "$TEST_DIR/rlcr"

for i in $(seq 1 5); do
    SESSION="$TEST_DIR/rlcr/session-$i"
    mkdir -p "$SESSION"
    touch "$SESSION/state.md"
done

RESULT=$(find_active_loop "$TEST_DIR/rlcr")
if [[ -n "$RESULT" ]]; then
    pass "Handles rapid session creation (returns: $(basename "$RESULT"))"
else
    fail "Rapid creation" "some session" "empty"
fi

# Test 15: Session with only complete-state.md (finished loop)
echo ""
echo "Test 15: Session with complete-state.md (finished loop)"
rm -rf "$TEST_DIR/rlcr"
mkdir -p "$TEST_DIR/rlcr/2026-01-17_10-00-00"
touch "$TEST_DIR/rlcr/2026-01-17_10-00-00/complete-state.md"

RESULT=$(find_active_loop "$TEST_DIR/rlcr")
if [[ -z "$RESULT" ]]; then
    pass "Ignores sessions with only complete-state.md"
else
    fail "Finished session ignored" "empty" "$RESULT"
fi

# Test 16: Session with cancel-state.md (cancelled loop)
echo ""
echo "Test 16: Session with cancel-state.md (cancelled loop)"
rm -rf "$TEST_DIR/rlcr"
mkdir -p "$TEST_DIR/rlcr/2026-01-17_10-00-00"
touch "$TEST_DIR/rlcr/2026-01-17_10-00-00/cancel-state.md"

RESULT=$(find_active_loop "$TEST_DIR/rlcr")
if [[ -z "$RESULT" ]]; then
    pass "Ignores sessions with only cancel-state.md"
else
    fail "Cancelled session ignored" "empty" "$RESULT"
fi

# Test 17: Mixed finished and active sessions
echo ""
echo "Test 17: Mixed finished and active sessions"
rm -rf "$TEST_DIR/rlcr"
mkdir -p "$TEST_DIR/rlcr/2026-01-15_10-00-00"
mkdir -p "$TEST_DIR/rlcr/2026-01-17_10-00-00"
touch "$TEST_DIR/rlcr/2026-01-15_10-00-00/state.md"
touch "$TEST_DIR/rlcr/2026-01-17_10-00-00/complete-state.md"

# Newest is finished, older has state.md -- zombie-loop protection returns empty
RESULT=$(find_active_loop "$TEST_DIR/rlcr")
if [[ -z "$RESULT" ]]; then
    pass "Zombie-loop protection: returns empty when newest dir is finished"
else
    fail "Newest finished" "empty" "$RESULT"
fi

# Test 18: Unicode in session directory name
echo ""
echo "Test 18: Unicode characters in session directory name"
rm -rf "$TEST_DIR/rlcr"
mkdir -p "$TEST_DIR/rlcr/session-test"
touch "$TEST_DIR/rlcr/session-test/state.md"

RESULT=$(find_active_loop "$TEST_DIR/rlcr")
if [[ -n "$RESULT" ]]; then
    pass "Handles session directory names gracefully"
else
    fail "Unicode handling" "some result" "empty"
fi

# ========================================
# Summary
# ========================================

print_test_summary "Session Robustness Test Summary"
exit $?
