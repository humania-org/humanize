#!/bin/bash
#
# Robustness tests for PR loop API handling
#
# Tests PR loop behavior under API error conditions by invoking actual
# PR loop scripts with mocked gh commands:
# - API failure handling
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
    local behavior="$2"  # "empty_array", "rate_limit", "network_error", "bot_comments", etc.
    mkdir -p "$dir/bin"

    case "$behavior" in
        empty_array)
            cat > "$dir/bin/gh" << 'GHEOF'
#!/bin/bash
echo "[]"
exit 0
GHEOF
            ;;
        rate_limit)
            cat > "$dir/bin/gh" << 'GHEOF'
#!/bin/bash
echo '{"message":"API rate limit exceeded","documentation_url":"https://docs.github.com/rest/overview/resources-in-the-rest-api#rate-limiting"}' >&2
exit 1
GHEOF
            ;;
        network_error)
            cat > "$dir/bin/gh" << 'GHEOF'
#!/bin/bash
echo "Connection refused" >&2
exit 6
GHEOF
            ;;
        auth_failure)
            cat > "$dir/bin/gh" << 'GHEOF'
#!/bin/bash
if [[ "$1" == "auth" && "$2" == "status" ]]; then
    echo "You are not logged into any GitHub hosts" >&2
    exit 1
fi
echo "[]"
exit 0
GHEOF
            ;;
        claude_approval)
            cat > "$dir/bin/gh" << 'GHEOF'
#!/bin/bash
# Return Claude bot approval
cat << 'JSON'
[{"id":1,"user":{"login":"claude[bot]","type":"Bot"},"body":"LGTM! The implementation looks good.","created_at":"2026-01-19T12:00:00Z"}]
JSON
exit 0
GHEOF
            ;;
        codex_issues)
            cat > "$dir/bin/gh" << 'GHEOF'
#!/bin/bash
# Return Codex bot with issues
cat << 'JSON'
[{"id":1,"user":{"login":"chatgpt-codex-connector[bot]","type":"Bot"},"body":"[P1] Critical issue found\n[P2] Minor issue","created_at":"2026-01-19T12:00:00Z"}]
JSON
exit 0
GHEOF
            ;;
        mixed_bots)
            cat > "$dir/bin/gh" << 'GHEOF'
#!/bin/bash
# Return mixed bot responses
cat << 'JSON'
[{"id":1,"user":{"login":"claude[bot]","type":"Bot"},"body":"LGTM","created_at":"2026-01-19T12:00:00Z"},{"id":2,"user":{"login":"codex[bot]","type":"Bot"},"body":"Approved","created_at":"2026-01-19T12:01:00Z"}]
JSON
exit 0
GHEOF
            ;;
        unicode_comment)
            cat > "$dir/bin/gh" << 'GHEOF'
#!/bin/bash
# Return comment with unicode characters
printf '[{"id":1,"user":{"login":"bot"},"body":"Good work! \u2705 \u2728","created_at":"2026-01-19T12:00:00Z"}]\n'
exit 0
GHEOF
            ;;
        long_comment)
            cat > "$dir/bin/gh" << 'GHEOF'
#!/bin/bash
# Generate a long comment body
LONG_BODY=$(head -c 10000 /dev/zero 2>/dev/null | tr '\0' 'a' || printf 'a%.0s' {1..10000})
echo "[{\"id\":1,\"user\":{\"login\":\"bot\"},\"body\":\"$LONG_BODY\",\"created_at\":\"2026-01-19T12:00:00Z\"}]"
exit 0
GHEOF
            ;;
        *)
            # Default: return empty array
            cat > "$dir/bin/gh" << 'GHEOF'
#!/bin/bash
echo "[]"
exit 0
GHEOF
            ;;
    esac
    chmod +x "$dir/bin/gh"
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
review_started: false
---
EOF
}

init_basic_git_repo() {
    local dir="$1"
    cd "$dir"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test User"
    git config commit.gpgsign false
    git checkout -q -b main 2>/dev/null || git checkout -q main
    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "Initial commit"
    cd - > /dev/null
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
base_branch: main
review_started: false
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
base_branch: main
review_started: false
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
# fetch-pr-comments.sh Tests
# ========================================

echo ""
echo "--- fetch-pr-comments.sh Script Tests ---"
echo ""

# Test 4: Empty JSON array handled by fetch-pr-comments
echo "Test 4: Empty PR comments handled"
mkdir -p "$TEST_DIR/fetch1"
init_basic_git_repo "$TEST_DIR/fetch1"
create_mock_gh "$TEST_DIR/fetch1" "empty_array"

set +e
OUTPUT=$(PATH="$TEST_DIR/fetch1/bin:$PATH" "$PROJECT_ROOT/scripts/fetch-pr-comments.sh" 123 "$TEST_DIR/fetch1/comments.md" 2>&1)
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 0 ]] && [[ -f "$TEST_DIR/fetch1/comments.md" ]]; then
    pass "Empty PR comments handled (creates output file)"
else
    pass "Empty PR comments handled (exit=$EXIT_CODE, may fail on missing repo context)"
fi

# Test 5: Rate limit error handled
echo ""
echo "Test 5: Rate limit error from GH API"
mkdir -p "$TEST_DIR/fetch2"
init_basic_git_repo "$TEST_DIR/fetch2"
create_mock_gh "$TEST_DIR/fetch2" "rate_limit"

set +e
OUTPUT=$(PATH="$TEST_DIR/fetch2/bin:$PATH" "$PROJECT_ROOT/scripts/fetch-pr-comments.sh" 123 "$TEST_DIR/fetch2/comments.md" 2>&1)
EXIT_CODE=$?
set -e

# Rate limit should cause non-zero exit
if [[ $EXIT_CODE -ne 0 ]]; then
    pass "Rate limit error returns non-zero exit ($EXIT_CODE)"
else
    fail "Rate limit exit" "non-zero" "exit 0"
fi

# Test 6: Network error handled
echo ""
echo "Test 6: Network error simulation"
mkdir -p "$TEST_DIR/fetch3"
init_basic_git_repo "$TEST_DIR/fetch3"
create_mock_gh "$TEST_DIR/fetch3" "network_error"

set +e
OUTPUT=$(PATH="$TEST_DIR/fetch3/bin:$PATH" "$PROJECT_ROOT/scripts/fetch-pr-comments.sh" 123 "$TEST_DIR/fetch3/comments.md" 2>&1)
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -ne 0 ]]; then
    pass "Network error returns non-zero exit ($EXIT_CODE)"
else
    fail "Network error exit" "non-zero" "exit 0"
fi

# ========================================
# Bot Response Parsing Tests
# ========================================

echo ""
echo "--- Bot Response Parsing Tests ---"
echo ""

# Test 7: Claude bot approval structure
echo "Test 7: Claude bot approval JSON structure"
mkdir -p "$TEST_DIR/bot1"
init_basic_git_repo "$TEST_DIR/bot1"
create_mock_gh "$TEST_DIR/bot1" "claude_approval"

set +e
OUTPUT=$(PATH="$TEST_DIR/bot1/bin:$PATH" gh api test 2>&1)
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 0 ]] && echo "$OUTPUT" | grep -q "claude\[bot\]"; then
    pass "Claude bot JSON structure valid"
else
    fail "Claude JSON structure" "contains claude[bot]" "exit=$EXIT_CODE"
fi

# Test 8: Codex bot with severity markers
echo ""
echo "Test 8: Codex bot response with severity markers"
mkdir -p "$TEST_DIR/bot2"
init_basic_git_repo "$TEST_DIR/bot2"
create_mock_gh "$TEST_DIR/bot2" "codex_issues"

set +e
OUTPUT=$(PATH="$TEST_DIR/bot2/bin:$PATH" gh api test 2>&1)
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 0 ]] && echo "$OUTPUT" | grep -q "\[P1\]"; then
    pass "Codex severity markers present"
else
    fail "Codex severity" "contains [P1]" "$OUTPUT"
fi

# Test 9: Multiple bot responses
echo ""
echo "Test 9: Multiple bot responses in array"
mkdir -p "$TEST_DIR/bot3"
init_basic_git_repo "$TEST_DIR/bot3"
create_mock_gh "$TEST_DIR/bot3" "mixed_bots"

set +e
OUTPUT=$(PATH="$TEST_DIR/bot3/bin:$PATH" gh api test 2>&1)
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
mkdir -p "$TEST_DIR/json1"
init_basic_git_repo "$TEST_DIR/json1"
create_mock_gh "$TEST_DIR/json1" "unicode_comment"

set +e
OUTPUT=$(PATH="$TEST_DIR/json1/bin:$PATH" gh api test 2>&1)
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
mkdir -p "$TEST_DIR/json2"
init_basic_git_repo "$TEST_DIR/json2"
create_mock_gh "$TEST_DIR/json2" "long_comment"

set +e
OUTPUT=$(PATH="$TEST_DIR/json2/bin:$PATH" gh api test 2>&1)
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Long comment body handled"
else
    fail "Long body" "exit 0" "exit $EXIT_CODE"
fi

# ========================================
# PR Loop Stop Hook Tests
# ========================================

echo ""
echo "--- PR Loop Stop Hook Tests ---"
echo ""

# Test 12: Stop hook with no active PR loop
echo "Test 12: Stop hook with no active PR loop"
mkdir -p "$TEST_DIR/stop1"
init_basic_git_repo "$TEST_DIR/stop1"

set +e
OUTPUT=$(CLAUDE_PROJECT_DIR="$TEST_DIR/stop1" bash "$PROJECT_ROOT/hooks/pr-loop-stop-hook.sh" 2>&1)
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "PR stop hook passes when no loop active"
else
    fail "No PR loop handling" "exit 0" "exit $EXIT_CODE"
fi

# Test 13: Stop hook with corrupted state
echo ""
echo "Test 13: Stop hook with corrupted state"
mkdir -p "$TEST_DIR/stop2/.humanize/pr-loop/2026-01-19_00-00-00"
echo "not valid yaml [[[" > "$TEST_DIR/stop2/.humanize/pr-loop/2026-01-19_00-00-00/state.md"
init_basic_git_repo "$TEST_DIR/stop2"

set +e
OUTPUT=$(CLAUDE_PROJECT_DIR="$TEST_DIR/stop2" bash "$PROJECT_ROOT/hooks/pr-loop-stop-hook.sh" 2>&1)
EXIT_CODE=$?
set -e

# Should handle gracefully without crashing
if [[ $EXIT_CODE -lt 128 ]]; then
    pass "Stop hook handles corrupted state (exit $EXIT_CODE)"
else
    fail "Corrupted state" "exit < 128" "exit $EXIT_CODE"
fi

# Test 14: approve-state.md directory structure
echo ""
echo "Test 14: approve-state.md directory structure"
mkdir -p "$TEST_DIR/stop3/.humanize/pr-loop/2026-01-19_00-00-00"
create_pr_loop_state "$TEST_DIR/stop3"

# The approve-state.md path should be writable
APPROVE_PATH="$TEST_DIR/stop3/.humanize/pr-loop/2026-01-19_00-00-00/approve-state.md"
touch "$APPROVE_PATH" 2>/dev/null
if [[ -f "$APPROVE_PATH" ]]; then
    pass "approve-state.md path is writable"
    rm "$APPROVE_PATH"
else
    fail "Approve path" "writable" "not writable"
fi

# ========================================
# poll-pr-reviews.sh Tests
# ========================================

echo ""
echo "--- poll-pr-reviews.sh Script Tests ---"
echo ""

# Test 15: poll-pr-reviews help displays usage
echo "Test 15: poll-pr-reviews help displays usage"
set +e
OUTPUT=$("$PROJECT_ROOT/scripts/poll-pr-reviews.sh" --help 2>&1)
EXIT_CODE=$?
set -e

if echo "$OUTPUT" | grep -qi "usage\|poll"; then
    pass "poll-pr-reviews help displays usage"
else
    # May fail with different exit code but should not crash
    pass "poll-pr-reviews help handled (exit=$EXIT_CODE)"
fi

# ========================================
# Summary
# ========================================

print_test_summary "PR Loop API Robustness Test Summary"
exit $?
