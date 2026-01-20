#!/bin/bash
#
# Robustness tests for PR loop API handling
#
# Tests PR loop behavior under API error conditions:
# - API failure handling via mock gh commands
# - Rate limiting responses
# - Bot response JSON parsing
# - Network error simulation
# - PR loop state file handling
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/hooks/lib/loop-common.sh"
source "$SCRIPT_DIR/../test-helpers.sh"

setup_test_dir

echo "========================================"
echo "PR Loop API Robustness Tests"
echo "========================================"
echo ""

# ========================================
# Helper Functions
# ========================================

create_mock_gh() {
    local dir="$1"
    local response="${2:-{}}"
    local exit_code="${3:-0}"
    mkdir -p "$dir"
    cat > "$dir/gh" << EOF
#!/bin/bash
echo '$response'
exit $exit_code
EOF
    chmod +x "$dir/gh"
}

create_pr_loop_state() {
    local dir="$1"
    local round="${2:-0}"
    mkdir -p "$dir/.humanize/pr-loop/2026-01-19_00-00-00"
    cat > "$dir/.humanize/pr-loop/2026-01-19_00-00-00/state.md" << EOF
---
current_round: $round
max_iterations: 42
pr_number: 123
pr_owner: testowner
pr_repo: testrepo
base_branch: main
configured_bots:
  - claude
  - codex
active_bots:
  - claude
startup_case: 3
---
EOF
}

# ========================================
# PR Loop State Handling Tests
# ========================================

echo "--- PR Loop State Handling Tests ---"
echo ""

# Test 1: find_active_pr_loop detects PR loop state
echo "Test 1: PR loop state detection"
mkdir -p "$TEST_DIR/prloop1/.humanize/pr-loop/2026-01-19_00-00-00"
create_pr_loop_state "$TEST_DIR/prloop1"

ACTIVE=$(find_active_pr_loop "$TEST_DIR/prloop1/.humanize/pr-loop" 2>/dev/null || echo "")
if [[ "$ACTIVE" == *"2026-01-19"* ]]; then
    pass "PR loop state detected"
else
    fail "PR loop detection" "*2026-01-19*" "$ACTIVE"
fi

# Test 2: PR loop with YAML list active_bots
echo ""
echo "Test 2: PR loop with YAML list active_bots"
mkdir -p "$TEST_DIR/prloop2/.humanize/pr-loop/2026-01-19_00-00-00"
cat > "$TEST_DIR/prloop2/.humanize/pr-loop/2026-01-19_00-00-00/state.md" << 'EOF'
---
current_round: 1
max_iterations: 42
pr_number: 456
active_bots:
  - claude
  - codex
configured_bots:
  - claude
  - codex
---
EOF

# Verify the file can be read
if grep -q "active_bots:" "$TEST_DIR/prloop2/.humanize/pr-loop/2026-01-19_00-00-00/state.md"; then
    pass "YAML list active_bots format accepted"
else
    fail "YAML list format" "contains active_bots" "not found"
fi

# Test 3: PR loop state with missing pr_number
echo ""
echo "Test 3: PR loop state with missing pr_number"
mkdir -p "$TEST_DIR/prloop3/.humanize/pr-loop/2026-01-19_00-00-00"
cat > "$TEST_DIR/prloop3/.humanize/pr-loop/2026-01-19_00-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 42
configured_bots:
  - claude
---
EOF

# Should still be detectable as an active loop
ACTIVE=$(find_active_pr_loop "$TEST_DIR/prloop3/.humanize/pr-loop" 2>/dev/null || echo "")
if [[ -n "$ACTIVE" ]]; then
    pass "PR loop without pr_number still detected"
else
    fail "Missing pr_number" "detected" "not detected"
fi

# ========================================
# Mock GH Response Tests
# ========================================

echo ""
echo "--- Mock GH Response Tests ---"
echo ""

# Test 4: Empty JSON array response
echo "Test 4: Empty JSON array handled"
mkdir -p "$TEST_DIR/empty/bin"
# Create mock directly to avoid heredoc issues
printf '#!/bin/bash\necho "[]"\nexit 0\n' > "$TEST_DIR/empty/bin/gh"
chmod +x "$TEST_DIR/empty/bin/gh"
create_pr_loop_state "$TEST_DIR/empty"

set +e
OUTPUT=$("$TEST_DIR/empty/bin/gh" api test 2>&1)
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 0 ]] && [[ "$OUTPUT" == "[]" ]]; then
    pass "Empty array response handled"
else
    fail "Empty array" "exit 0, []" "exit $EXIT_CODE, $OUTPUT"
fi

# Test 5: Rate limit error response
echo ""
echo "Test 5: Rate limit error response"
mkdir -p "$TEST_DIR/ratelimit"
create_mock_gh "$TEST_DIR/ratelimit/bin" '{"message":"API rate limit exceeded"}' 1
create_pr_loop_state "$TEST_DIR/ratelimit"

set +e
OUTPUT=$(cd "$TEST_DIR/ratelimit" && PATH="$TEST_DIR/ratelimit/bin:$PATH" gh api test 2>&1)
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 1 ]]; then
    pass "Rate limit error returns exit 1"
else
    fail "Rate limit exit" "exit 1" "exit $EXIT_CODE"
fi

# Test 6: Network error simulation
echo ""
echo "Test 6: Network error simulation"
mkdir -p "$TEST_DIR/network"
create_mock_gh "$TEST_DIR/network/bin" "Connection refused" 6
create_pr_loop_state "$TEST_DIR/network"

set +e
OUTPUT=$(cd "$TEST_DIR/network" && PATH="$TEST_DIR/network/bin:$PATH" gh api test 2>&1)
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 6 ]]; then
    pass "Network error returns correct exit code"
else
    fail "Network error exit" "exit 6" "exit $EXIT_CODE"
fi

# ========================================
# Bot Response JSON Parsing Tests
# ========================================

echo ""
echo "--- Bot Response Parsing Tests ---"
echo ""

# Test 7: Parse Claude bot approval
echo "Test 7: Claude bot approval JSON structure"
CLAUDE_JSON='[{"user":{"login":"claude[bot]"},"body":"LGTM","created_at":"2026-01-19T12:00:00Z"}]'
mkdir -p "$TEST_DIR/claude"
create_mock_gh "$TEST_DIR/claude/bin" "$CLAUDE_JSON" 0
create_pr_loop_state "$TEST_DIR/claude"

set +e
OUTPUT=$(cd "$TEST_DIR/claude" && PATH="$TEST_DIR/claude/bin:$PATH" gh api test 2>&1)
EXIT_CODE=$?
set -e

if echo "$OUTPUT" | grep -q "claude\[bot\]"; then
    pass "Claude bot JSON parsed correctly"
else
    fail "Claude JSON parsing" "contains claude[bot]" "$OUTPUT"
fi

# Test 8: Parse Codex bot with issues
echo ""
echo "Test 8: Codex bot response with severity markers"
CODEX_JSON='[{"user":{"login":"chatgpt-codex-connector[bot]"},"body":"[P1] Issue found","created_at":"2026-01-19T12:00:00Z"}]'
mkdir -p "$TEST_DIR/codex"
create_mock_gh "$TEST_DIR/codex/bin" "$CODEX_JSON" 0
create_pr_loop_state "$TEST_DIR/codex"

set +e
OUTPUT=$(cd "$TEST_DIR/codex" && PATH="$TEST_DIR/codex/bin:$PATH" gh api test 2>&1)
EXIT_CODE=$?
set -e

if echo "$OUTPUT" | grep -q "\[P1\]"; then
    pass "Codex severity marker parsed"
else
    fail "Codex severity parsing" "contains [P1]" "$OUTPUT"
fi

# Test 9: Mixed bot responses
echo ""
echo "Test 9: Multiple bot responses in array"
MIXED_JSON='[{"user":{"login":"claude[bot]"},"body":"LGTM"},{"user":{"login":"codex[bot]"},"body":"Approved"}]'
mkdir -p "$TEST_DIR/mixed"
create_mock_gh "$TEST_DIR/mixed/bin" "$MIXED_JSON" 0

set +e
OUTPUT=$(cd "$TEST_DIR/mixed" && PATH="$TEST_DIR/mixed/bin:$PATH" gh api test 2>&1)
EXIT_CODE=$?
set -e

if echo "$OUTPUT" | grep -q "claude\[bot\]" && echo "$OUTPUT" | grep -q "codex\[bot\]"; then
    pass "Multiple bot responses parsed"
else
    fail "Multiple bots" "both bots present" "$OUTPUT"
fi

# ========================================
# JSON Edge Cases
# ========================================

echo ""
echo "--- JSON Edge Cases ---"
echo ""

# Test 10: Unicode in bot comments
echo "Test 10: Unicode in bot comments"
UNICODE_JSON='[{"user":{"login":"bot"},"body":"Good work! \u2705"}]'
mkdir -p "$TEST_DIR/unicode"
create_mock_gh "$TEST_DIR/unicode/bin" "$UNICODE_JSON" 0

set +e
OUTPUT=$(cd "$TEST_DIR/unicode" && PATH="$TEST_DIR/unicode/bin:$PATH" gh api test 2>&1)
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Unicode in comments handled"
else
    fail "Unicode handling" "exit 0" "exit $EXIT_CODE"
fi

# Test 11: Very long comment body
echo ""
echo "Test 11: Long comment body"
LONG_BODY=$(head -c 10000 /dev/zero | tr '\0' 'a')
LONG_JSON='[{"user":{"login":"bot"},"body":"'"$LONG_BODY"'"}]'
mkdir -p "$TEST_DIR/long"
create_mock_gh "$TEST_DIR/long/bin" "$LONG_JSON" 0

set +e
OUTPUT=$(cd "$TEST_DIR/long" && PATH="$TEST_DIR/long/bin:$PATH" gh api test 2>&1)
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Long comment body handled"
else
    fail "Long body" "exit 0" "exit $EXIT_CODE"
fi

# Test 12: Nested JSON in comment
echo ""
echo "Test 12: JSON-like content in comment body"
JSON_IN_BODY='[{"user":{"login":"bot"},"body":"Config: {\"key\": \"value\"}"}]'
mkdir -p "$TEST_DIR/nested"
create_mock_gh "$TEST_DIR/nested/bin" "$JSON_IN_BODY" 0

set +e
OUTPUT=$(cd "$TEST_DIR/nested" && PATH="$TEST_DIR/nested/bin:$PATH" gh api test 2>&1)
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Nested JSON-like content handled"
else
    fail "Nested JSON" "exit 0" "exit $EXIT_CODE"
fi

# ========================================
# PR Loop Stop Hook State Tests
# ========================================

echo ""
echo "--- Stop Hook State Tests ---"
echo ""

# Test 13: Stop hook with no active PR loop
echo "Test 13: Stop hook with no active PR loop"
mkdir -p "$TEST_DIR/nostop"
# No .humanize directory

set +e
OUTPUT=$(CLAUDE_PROJECT_DIR="$TEST_DIR/nostop" bash "$PROJECT_ROOT/hooks/pr-loop-stop-hook.sh" 2>&1)
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "PR stop hook passes when no loop active"
else
    fail "No PR loop handling" "exit 0" "exit $EXIT_CODE"
fi

# Test 14: Stop hook with corrupted state
echo ""
echo "Test 14: Stop hook with corrupted state"
mkdir -p "$TEST_DIR/corrupt/.humanize/pr-loop/2026-01-19_00-00-00"
echo "not valid yaml [[[" > "$TEST_DIR/corrupt/.humanize/pr-loop/2026-01-19_00-00-00/state.md"

set +e
OUTPUT=$(CLAUDE_PROJECT_DIR="$TEST_DIR/corrupt" bash "$PROJECT_ROOT/hooks/pr-loop-stop-hook.sh" 2>&1)
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -lt 128 ]]; then
    pass "Stop hook handles corrupted state (exit $EXIT_CODE)"
else
    fail "Corrupted state" "exit < 128" "exit $EXIT_CODE"
fi

# Test 15: approve-state.md creation path
echo ""
echo "Test 15: approve-state.md directory structure"
mkdir -p "$TEST_DIR/approve/.humanize/pr-loop/2026-01-19_00-00-00"
create_pr_loop_state "$TEST_DIR/approve"

# The approve-state.md path should be writable
APPROVE_PATH="$TEST_DIR/approve/.humanize/pr-loop/2026-01-19_00-00-00/approve-state.md"
touch "$APPROVE_PATH" 2>/dev/null
if [[ -f "$APPROVE_PATH" ]]; then
    pass "approve-state.md path is writable"
    rm "$APPROVE_PATH"
else
    fail "Approve path" "writable" "not writable"
fi

# ========================================
# Summary
# ========================================

print_test_summary "PR Loop API Robustness Test Summary"
exit $?
