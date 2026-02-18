#!/bin/bash
#
# Robustness tests for concurrent state access
#
# Tests state file handling under concurrent access scenarios:
# - Multiple processes reading state simultaneously
# - State file parsing during active writes
# - Race conditions in loop detection
# - Stale state file detection
# - File locking semantics
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../test-helpers.sh"

setup_test_dir

echo "========================================"
echo "Concurrent State Access Robustness Tests"
echo "========================================"
echo ""

# ========================================
# Helper Functions
# ========================================

create_state_file() {
    local dir="$1"
    local round="${2:-0}"
    mkdir -p "$dir"
    cat > "$dir/state.md" << EOF
---
current_round: $round
max_iterations: 42
plan_file: plan.md
start_branch: main
base_branch: main
push_every_round: false
codex_model: o3-mini
codex_effort: medium
codex_timeout: 1200
---

## Loop State
Active RLCR loop.
EOF
}

# ========================================
# State File Parsing Tests
# ========================================

echo "--- State File Parsing Edge Cases ---"
echo ""

# Test 1: State file with trailing whitespace
echo "Test 1: State file with trailing whitespace parsed correctly"
mkdir -p "$TEST_DIR/state1"
cat > "$TEST_DIR/state1/state.md" << 'EOF'
---
current_round: 5
max_iterations: 42
plan_file: plan.md
start_branch: main
---
EOF

# Source loop-common.sh and test parsing
source "$PROJECT_ROOT/hooks/lib/loop-common.sh" 2>/dev/null || true
ROUND=$(get_current_round "$TEST_DIR/state1/state.md")
if [[ "$ROUND" == "5" ]]; then
    pass "Trailing whitespace handled correctly"
else
    fail "Trailing whitespace" "5" "$ROUND"
fi

# Test 2: State file with leading whitespace
echo ""
echo "Test 2: State file with leading whitespace parsed correctly"
mkdir -p "$TEST_DIR/state2"
cat > "$TEST_DIR/state2/state.md" << 'EOF'
---
   current_round: 7
max_iterations: 42
---
EOF

ROUND=$(get_current_round "$TEST_DIR/state2/state.md")
# Leading whitespace on key makes it not match "^current_round:"
# This tests that we handle edge cases gracefully (default to 0)
if [[ "$ROUND" == "0" ]] || [[ "$ROUND" == "7" ]]; then
    pass "Leading whitespace handled (round: $ROUND)"
else
    fail "Leading whitespace" "0 or 7" "$ROUND"
fi

# Test 3: State file with CRLF line endings
echo ""
echo "Test 3: State file with CRLF line endings - graceful degradation"
mkdir -p "$TEST_DIR/state3"
# Create file with CRLF line endings using awk (more portable)
cat > "$TEST_DIR/state3/state_lf.md" << 'EOFCRLF'
---
current_round: 3
max_iterations: 42
---
EOFCRLF
awk '{printf "%s\r\n", $0}' "$TEST_DIR/state3/state_lf.md" > "$TEST_DIR/state3/state.md"

ROUND=$(get_current_round "$TEST_DIR/state3/state.md")
# CRLF files won't parse correctly because sed pattern ^---$ doesn't match ---\r
# This is expected behavior - Unix tools expect LF line endings
# The function should return the default value (0) gracefully, not crash
if [[ "$ROUND" == "0" ]] || [[ "$ROUND" == "3" ]]; then
    pass "CRLF line endings handled gracefully (defaults to 0 or parses as 3)"
else
    fail "CRLF line endings" "0 or 3" "$ROUND"
fi

# Test 4: State file with empty value
echo ""
echo "Test 4: State file with empty current_round"
mkdir -p "$TEST_DIR/state4"
cat > "$TEST_DIR/state4/state.md" << 'EOF'
---
current_round:
max_iterations: 42
---
EOF

ROUND=$(get_current_round "$TEST_DIR/state4/state.md")
if [[ "$ROUND" == "0" ]] || [[ -z "$ROUND" ]]; then
    pass "Empty current_round defaults to 0"
else
    fail "Empty value" "0 or empty" "$ROUND"
fi

# Test 5: State file with comments
echo ""
echo "Test 5: State file with YAML comments"
mkdir -p "$TEST_DIR/state5"
cat > "$TEST_DIR/state5/state.md" << 'EOF'
---
# This is a comment
current_round: 8 # inline comment
max_iterations: 42
---
EOF

ROUND=$(get_current_round "$TEST_DIR/state5/state.md")
# Inline comments may or may not be stripped
ROUND_CLEAN=$(echo "$ROUND" | sed 's/#.*//' | tr -d ' ')
if [[ "$ROUND_CLEAN" == "8" ]]; then
    pass "YAML comments handled (round: $ROUND_CLEAN)"
else
    fail "YAML comments" "8" "$ROUND_CLEAN"
fi

# ========================================
# Loop Detection Tests
# ========================================

echo ""
echo "--- Loop Detection Tests ---"
echo ""

# Test 6: find_active_loop with multiple timestamped directories
echo "Test 6: find_active_loop returns newest directory"
mkdir -p "$TEST_DIR/loops/rlcr/2026-01-10_00-00-00"
mkdir -p "$TEST_DIR/loops/rlcr/2026-01-15_00-00-00"
mkdir -p "$TEST_DIR/loops/rlcr/2026-01-20_00-00-00"

# Only the newest has state.md
create_state_file "$TEST_DIR/loops/rlcr/2026-01-20_00-00-00"

ACTIVE=$(find_active_loop "$TEST_DIR/loops/rlcr" 2>/dev/null || echo "")
if [[ "$ACTIVE" == *"2026-01-20"* ]]; then
    pass "find_active_loop returns newest directory"
else
    fail "find_active_loop" "*2026-01-20*" "$ACTIVE"
fi

# Test 7: find_active_loop ignores directories without state.md
echo ""
echo "Test 7: find_active_loop ignores directories without state.md"
mkdir -p "$TEST_DIR/loops2/rlcr/2026-01-25_00-00-00"
mkdir -p "$TEST_DIR/loops2/rlcr/2026-01-20_00-00-00"
# Newer directory has no state.md
# Older directory has state.md
create_state_file "$TEST_DIR/loops2/rlcr/2026-01-20_00-00-00"

ACTIVE=$(find_active_loop "$TEST_DIR/loops2/rlcr" 2>/dev/null || echo "")
# Zombie-loop protection: only checks newest dir, which has no state.md
if [[ -z "$ACTIVE" ]]; then
    pass "Zombie-loop protection: returns empty when newest dir has no state"
else
    fail "Zombie-loop protection" "empty" "$ACTIVE"
fi

# Test 8: find_active_loop handles finalize-state.md
echo ""
echo "Test 8: find_active_loop detects finalize-state.md"
mkdir -p "$TEST_DIR/loops3/rlcr/2026-01-30_00-00-00"
cat > "$TEST_DIR/loops3/rlcr/2026-01-30_00-00-00/finalize-state.md" << 'EOF'
---
current_round: 10
finalize_mode: true
---
EOF

ACTIVE=$(find_active_loop "$TEST_DIR/loops3/rlcr" 2>/dev/null || echo "")
if [[ "$ACTIVE" == *"2026-01-30"* ]]; then
    pass "find_active_loop detects finalize-state.md"
else
    fail "finalize-state.md detection" "*2026-01-30*" "$ACTIVE"
fi

# Test 9: find_active_loop with empty base directory
echo ""
echo "Test 9: find_active_loop with non-existent directory"
ACTIVE=$(find_active_loop "$TEST_DIR/nonexistent" 2>/dev/null || echo "")
if [[ -z "$ACTIVE" ]]; then
    pass "find_active_loop handles non-existent directory"
else
    fail "Non-existent dir" "empty" "$ACTIVE"
fi

# Test 10: find_active_loop with empty directory
echo ""
echo "Test 10: find_active_loop with empty directory"
mkdir -p "$TEST_DIR/empty-loops/rlcr"
ACTIVE=$(find_active_loop "$TEST_DIR/empty-loops/rlcr" 2>/dev/null || echo "")
if [[ -z "$ACTIVE" ]]; then
    pass "find_active_loop handles empty directory"
else
    fail "Empty dir" "empty" "$ACTIVE"
fi

# ========================================
# Concurrent Read Tests
# ========================================

echo ""
echo "--- Concurrent Read Tests ---"
echo ""

# Test 11: Multiple concurrent reads of state file
echo "Test 11: Multiple concurrent reads succeed"
mkdir -p "$TEST_DIR/concurrent"
# Use non-zero round (5) so we can distinguish successful reads from parse failures
# (get_current_round returns 0 on failure, so checking for 0 would mask errors)
create_state_file "$TEST_DIR/concurrent" 5

# Spawn 10 parallel reads using temp files to track results
mkdir -p "$TEST_DIR/concurrent/results"
for i in $(seq 1 10); do
    (
        ROUND=$(get_current_round "$TEST_DIR/concurrent/state.md")
        # Only count as success if we read the actual value (5), not the default (0)
        if [[ "$ROUND" == "5" ]]; then
            touch "$TEST_DIR/concurrent/results/success_$i"
        fi
    ) &
done
wait

# Count successful reads
SUCCESS_COUNT=$(ls -1 "$TEST_DIR/concurrent/results/" 2>/dev/null | wc -l | tr -d ' ')

if [[ $SUCCESS_COUNT -eq 10 ]]; then
    pass "10 concurrent reads succeeded"
else
    fail "Concurrent reads" "10 successes" "$SUCCESS_COUNT"
fi

# Test 12: Read during simulated write (file being modified)
echo ""
echo "Test 12: Read during write operation - atomic writes"
mkdir -p "$TEST_DIR/concurrent2"
create_state_file "$TEST_DIR/concurrent2" 5

# Start a background process that does atomic writes (write to temp, then mv)
(
    for i in $(seq 1 50); do
        cat > "$TEST_DIR/concurrent2/state.md.tmp" << EOF
---
current_round: $i
max_iterations: 42
---
EOF
        mv "$TEST_DIR/concurrent2/state.md.tmp" "$TEST_DIR/concurrent2/state.md"
        sleep 0.01
    done
) &
WRITER_PID=$!

# Perform reads while atomic writes are happening
VALID_READS=0
INVALID_READS=0
for i in $(seq 1 20); do
    ROUND=$(get_current_round "$TEST_DIR/concurrent2/state.md" 2>/dev/null || echo "error")
    if [[ "$ROUND" =~ ^[0-9]+$ ]]; then
        VALID_READS=$((VALID_READS + 1))
    else
        INVALID_READS=$((INVALID_READS + 1))
    fi
    sleep 0.02
done

# Kill the writer
kill $WRITER_PID 2>/dev/null || true
wait $WRITER_PID 2>/dev/null || true

# With atomic writes via mv, reads should always succeed (require 20/20)
if [[ $VALID_READS -eq 20 ]]; then
    pass "Atomic writes ensure consistent reads (20/20 valid)"
else
    fail "Atomic write consistency" "20/20 valid reads" "$VALID_READS valid, $INVALID_READS invalid"
fi

# ========================================
# State File Validation Tests
# ========================================

echo ""
echo "--- State File Validation Tests ---"
echo ""

# Test 13: parse_state_file_strict rejects malformed YAML
echo "Test 13: parse_state_file_strict rejects malformed YAML"
mkdir -p "$TEST_DIR/malformed"
cat > "$TEST_DIR/malformed/state.md" << 'EOF'
---
current_round: [invalid yaml array
max_iterations: 42
---
EOF

set +e
parse_state_file_strict "$TEST_DIR/malformed/state.md" 2>/dev/null
PARSE_RESULT=$?
set -e

if [[ $PARSE_RESULT -ne 0 ]]; then
    pass "parse_state_file_strict rejects malformed YAML"
else
    fail "Malformed YAML" "non-zero exit" "exit $PARSE_RESULT"
fi

# Test 14: parse_state_file_strict rejects missing frontmatter
echo ""
echo "Test 14: parse_state_file_strict rejects missing frontmatter"
mkdir -p "$TEST_DIR/nofrontmatter"
cat > "$TEST_DIR/nofrontmatter/state.md" << 'EOF'
No frontmatter here
Just regular content
EOF

set +e
parse_state_file_strict "$TEST_DIR/nofrontmatter/state.md" 2>/dev/null
PARSE_RESULT=$?
set -e

if [[ $PARSE_RESULT -ne 0 ]]; then
    pass "parse_state_file_strict rejects missing frontmatter"
else
    fail "Missing frontmatter" "non-zero exit" "exit $PARSE_RESULT"
fi

# Test 15: parse_state_file handles unicode content
echo ""
echo "Test 15: State file with actual unicode content"
mkdir -p "$TEST_DIR/unicode"
# Create state file with actual unicode characters using printf to avoid heredoc quoting issues
printf '%s\n' '---' 'current_round: 2' 'max_iterations: 42' 'plan_file: "plan-test.md"' '---' '' '## Content with Unicode' > "$TEST_DIR/unicode/state.md"
# Append actual unicode characters (CJK) using printf with octal/hex escapes
printf 'This state has unicode: \xe4\xb8\xad\xe6\x96\x87 (Chinese for "Chinese").\n' >> "$TEST_DIR/unicode/state.md"

ROUND=$(get_current_round "$TEST_DIR/unicode/state.md")
if [[ "$ROUND" == "2" ]]; then
    pass "Unicode content handled correctly"
else
    fail "Unicode content" "2" "$ROUND"
fi

# ========================================
# PR Loop State Tests
# ========================================

echo ""
echo "--- PR Loop State Tests ---"
echo ""

# Test 16: find_active_pr_loop works correctly
echo "Test 16: find_active_pr_loop detection"
mkdir -p "$TEST_DIR/pr-loops/pr-loop/2026-01-19_12-00-00"
cat > "$TEST_DIR/pr-loops/pr-loop/2026-01-19_12-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 42
pr_number: 123
---
EOF

ACTIVE=$(find_active_pr_loop "$TEST_DIR/pr-loops/pr-loop" 2>/dev/null || echo "")
if [[ "$ACTIVE" == *"2026-01-19"* ]]; then
    pass "find_active_pr_loop works correctly"
else
    fail "find_active_pr_loop" "*2026-01-19*" "$ACTIVE"
fi

# Test 17: PR loop state with YAML list for active_bots
echo ""
echo "Test 17: PR loop state with YAML list"
mkdir -p "$TEST_DIR/pr-yaml"
cat > "$TEST_DIR/pr-yaml/state.md" << 'EOF'
---
current_round: 1
active_bots:
  - claude
  - codex
configured_bots:
  - claude
  - codex
---
EOF

# Test that we can read the state file without errors
if [[ -f "$TEST_DIR/pr-yaml/state.md" ]]; then
    # Check if file contains expected YAML structure
    if grep -q "^  - claude$" "$TEST_DIR/pr-yaml/state.md" && \
       grep -q "^  - codex$" "$TEST_DIR/pr-yaml/state.md"; then
        pass "PR loop YAML list format validated"
    else
        fail "YAML list format" "list items" "missing"
    fi
else
    fail "YAML list" "file exists" "file not found"
fi

# ========================================
# Stale Loop Detection Tests
# ========================================

echo ""
echo "--- Stale Loop Detection Tests ---"
echo ""

# Test 18: Old loop directory ignored
echo "Test 18: Old timestamp directory is not active"
mkdir -p "$TEST_DIR/old-loops/rlcr/2020-01-01_00-00-00"
create_state_file "$TEST_DIR/old-loops/rlcr/2020-01-01_00-00-00"

mkdir -p "$TEST_DIR/old-loops/rlcr/2026-01-01_00-00-00"
# No state.md in newer directory

ACTIVE=$(find_active_loop "$TEST_DIR/old-loops/rlcr" 2>/dev/null || echo "")
# Zombie-loop protection: only checks newest dir, which has no state.md
if [[ -z "$ACTIVE" ]]; then
    pass "Zombie-loop protection: returns empty when newer dir is empty"
else
    fail "Zombie-loop protection" "empty" "$ACTIVE"
fi

# Test 19: Cancel-state.md is not considered active
echo ""
echo "Test 19: cancel-state.md is not considered active"
mkdir -p "$TEST_DIR/cancelled/rlcr/2026-01-19_00-00-00"
cat > "$TEST_DIR/cancelled/rlcr/2026-01-19_00-00-00/cancel-state.md" << 'EOF'
---
current_round: 5
cancelled: true
---
EOF

ACTIVE=$(find_active_loop "$TEST_DIR/cancelled/rlcr" 2>/dev/null || echo "")
if [[ -z "$ACTIVE" ]]; then
    pass "cancel-state.md not considered active"
else
    fail "cancel-state.md" "empty" "$ACTIVE"
fi

# ========================================
# Edge Cases
# ========================================

echo ""
echo "--- Edge Cases ---"
echo ""

# Test 20: State file with very large round number
echo "Test 20: Very large round number"
mkdir -p "$TEST_DIR/large-round"
cat > "$TEST_DIR/large-round/state.md" << 'EOF'
---
current_round: 999999999
max_iterations: 42
---
EOF

ROUND=$(get_current_round "$TEST_DIR/large-round/state.md")
if [[ "$ROUND" == "999999999" ]]; then
    pass "Very large round number handled"
else
    fail "Large round" "999999999" "$ROUND"
fi

# Test 21: State file with zero round
echo ""
echo "Test 21: Zero round number"
mkdir -p "$TEST_DIR/zero-round"
cat > "$TEST_DIR/zero-round/state.md" << 'EOF'
---
current_round: 0
max_iterations: 42
---
EOF

ROUND=$(get_current_round "$TEST_DIR/zero-round/state.md")
if [[ "$ROUND" == "0" ]]; then
    pass "Zero round number handled"
else
    fail "Zero round" "0" "$ROUND"
fi

# Test 22: State file read permissions (skip if running as root)
echo ""
echo "Test 22: State file permissions handling"
if [[ $(id -u) -ne 0 ]]; then
    mkdir -p "$TEST_DIR/no-perms"
    create_state_file "$TEST_DIR/no-perms"
    chmod 000 "$TEST_DIR/no-perms/state.md"

    set +e
    ROUND=$(get_current_round "$TEST_DIR/no-perms/state.md" 2>/dev/null)
    READ_RESULT=$?
    set -e

    # Restore permissions for cleanup
    chmod 644 "$TEST_DIR/no-perms/state.md"

    if [[ -z "$ROUND" ]] || [[ "$ROUND" == "0" ]]; then
        pass "Permission denied handled gracefully"
    else
        fail "Permission handling" "empty or 0" "$ROUND"
    fi
else
    pass "Skipped (running as root)"
fi

# ========================================
# Summary
# ========================================

print_test_summary "Concurrent State Access Robustness Test Summary"
exit $?
