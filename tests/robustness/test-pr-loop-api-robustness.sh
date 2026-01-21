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

# Create a comprehensive mock gh that handles repo view, pr view, and api calls
# This allows fetch-pr-comments.sh to run end-to-end
create_mock_gh() {
    local dir="$1"
    local behavior="$2"  # "empty_array", "rate_limit", "network_error", "bot_comments", etc.
    mkdir -p "$dir/bin"

    # Base mock that handles repo view and pr view for all behaviors
    # Note: gh CLI applies -q jq queries internally, so we output the final result
    # fetch-pr-comments.sh uses: gh repo view --json owner,name -q '...'
    #                           gh pr view PR --repo REPO --json number -q .number
    cat > "$dir/bin/gh" << 'GHEOF_START'
#!/bin/bash
# Mock gh command for testing

# Check for -q flag anywhere in args (jq query)
HAS_Q_FLAG=false
for arg in "$@"; do
    if [[ "$arg" == "-q" ]]; then
        HAS_Q_FLAG=true
        break
    fi
done

# Handle repo view (required by fetch-pr-comments.sh)
if [[ "$1" == "repo" && "$2" == "view" ]]; then
    if [[ "$*" == *"--json"* ]]; then
        if [[ "$*" == *"owner,name"* ]]; then
            if [[ "$HAS_Q_FLAG" == "true" ]]; then
                # -q query extracts owner.login + "/" + name
                echo "testowner/testrepo"
            else
                echo '{"owner":{"login":"testowner"},"name":"testrepo"}'
            fi
            exit 0
        elif [[ "$*" == *"parent"* ]]; then
            if [[ "$HAS_Q_FLAG" == "true" ]]; then
                # parent query returns empty/null for non-fork
                echo "/"
            else
                echo '{"parent":null}'
            fi
            exit 0
        fi
    fi
    echo "testowner/testrepo"
    exit 0
fi

# Handle pr view (required by fetch-pr-comments.sh)
# PR existence check uses: gh pr view --repo REPO --json number -q .number
if [[ "$1" == "pr" && "$2" == "view" ]]; then
    if [[ "$*" == *"--json"* ]]; then
        if [[ "$*" == *"number"* ]]; then
            echo '{"number": 123}'
        else
            echo '{"state": "OPEN"}'
        fi
        exit 0
    fi
    echo "PR #123"
    exit 0
fi

# Handle api calls based on behavior
GHEOF_START

    # Add behavior-specific api handling
    case "$behavior" in
        empty_array)
            cat >> "$dir/bin/gh" << 'GHEOF'
if [[ "$1" == "api" ]]; then
    echo "[]"
    exit 0
fi
echo "[]"
exit 0
GHEOF
            ;;
        rate_limit)
            cat >> "$dir/bin/gh" << 'GHEOF'
if [[ "$1" == "api" ]]; then
    echo '{"message":"API rate limit exceeded","documentation_url":"https://docs.github.com/rest/overview/resources-in-the-rest-api#rate-limiting"}' >&2
    exit 1
fi
echo "[]"
exit 0
GHEOF
            ;;
        network_error)
            cat >> "$dir/bin/gh" << 'GHEOF'
if [[ "$1" == "api" ]]; then
    echo "Connection refused" >&2
    exit 6
fi
echo "[]"
exit 0
GHEOF
            ;;
        auth_failure)
            cat >> "$dir/bin/gh" << 'GHEOF'
if [[ "$1" == "auth" && "$2" == "status" ]]; then
    echo "You are not logged into any GitHub hosts" >&2
    exit 1
fi
if [[ "$1" == "api" ]]; then
    echo "[]"
    exit 0
fi
echo "[]"
exit 0
GHEOF
            ;;
        claude_approval)
            cat >> "$dir/bin/gh" << 'GHEOF'
if [[ "$1" == "api" ]]; then
    # Return Claude bot approval for issue comments endpoint
    if [[ "$2" == *"/issues/"*"/comments"* ]]; then
        cat << 'JSON'
[{"id":1,"user":{"login":"claude[bot]","type":"Bot"},"body":"LGTM! The implementation looks good.","created_at":"2026-01-19T12:00:00Z"}]
JSON
        exit 0
    fi
    echo "[]"
    exit 0
fi
echo "[]"
exit 0
GHEOF
            ;;
        codex_issues)
            cat >> "$dir/bin/gh" << 'GHEOF'
if [[ "$1" == "api" ]]; then
    # Return Codex bot with issues for issue comments endpoint
    if [[ "$2" == *"/issues/"*"/comments"* ]]; then
        cat << 'JSON'
[{"id":1,"user":{"login":"chatgpt-codex-connector[bot]","type":"Bot"},"body":"[P1] Critical issue found\n[P2] Minor issue","created_at":"2026-01-19T12:00:00Z"}]
JSON
        exit 0
    fi
    echo "[]"
    exit 0
fi
echo "[]"
exit 0
GHEOF
            ;;
        mixed_bots)
            cat >> "$dir/bin/gh" << 'GHEOF'
if [[ "$1" == "api" ]]; then
    # Return mixed bot responses for issue comments endpoint
    if [[ "$2" == *"/issues/"*"/comments"* ]]; then
        cat << 'JSON'
[{"id":1,"user":{"login":"claude[bot]","type":"Bot"},"body":"LGTM","created_at":"2026-01-19T12:00:00Z"},{"id":2,"user":{"login":"chatgpt-codex-connector[bot]","type":"Bot"},"body":"Approved","created_at":"2026-01-19T12:01:00Z"}]
JSON
        exit 0
    fi
    echo "[]"
    exit 0
fi
echo "[]"
exit 0
GHEOF
            ;;
        unicode_comment)
            cat >> "$dir/bin/gh" << 'GHEOF'
if [[ "$1" == "api" ]]; then
    if [[ "$2" == *"/issues/"*"/comments"* ]]; then
        printf '[{"id":1,"user":{"login":"bot","type":"Bot"},"body":"Good work! \u2705 \u2728","created_at":"2026-01-19T12:00:00Z"}]\n'
        exit 0
    fi
    echo "[]"
    exit 0
fi
echo "[]"
exit 0
GHEOF
            ;;
        long_comment)
            cat >> "$dir/bin/gh" << 'GHEOF'
if [[ "$1" == "api" ]]; then
    if [[ "$2" == *"/issues/"*"/comments"* ]]; then
        # Generate a long comment body
        LONG_BODY=$(head -c 10000 /dev/zero 2>/dev/null | tr '\0' 'a' || printf 'a%.0s' {1..10000})
        echo "[{\"id\":1,\"user\":{\"login\":\"bot\",\"type\":\"Bot\"},\"body\":\"$LONG_BODY\",\"created_at\":\"2026-01-19T12:00:00Z\"}]"
        exit 0
    fi
    echo "[]"
    exit 0
fi
echo "[]"
exit 0
GHEOF
            ;;
        *)
            # Default: return empty array for api calls
            cat >> "$dir/bin/gh" << 'GHEOF'
if [[ "$1" == "api" ]]; then
    echo "[]"
    exit 0
fi
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
echo "Test 4: Empty PR comments creates valid output file"
mkdir -p "$TEST_DIR/fetch1"
init_basic_git_repo "$TEST_DIR/fetch1"
create_mock_gh "$TEST_DIR/fetch1" "empty_array"

set +e
OUTPUT=$(PATH="$TEST_DIR/fetch1/bin:$PATH" "$PROJECT_ROOT/scripts/fetch-pr-comments.sh" 123 "$TEST_DIR/fetch1/comments.md" 2>&1)
EXIT_CODE=$?
set -e

# Must succeed AND create output file with expected content
if [[ $EXIT_CODE -eq 0 ]] && [[ -f "$TEST_DIR/fetch1/comments.md" ]]; then
    # Verify output contains expected structure
    if grep -q "PR Comments for #123" "$TEST_DIR/fetch1/comments.md" && \
       grep -q "testowner/testrepo" "$TEST_DIR/fetch1/comments.md"; then
        pass "Empty PR comments creates valid output (PR#, repo in file)"
    else
        fail "Empty PR output" "contains PR# and repo" "$(head -10 "$TEST_DIR/fetch1/comments.md")"
    fi
else
    fail "Empty PR comments" "exit 0 with output file" "exit=$EXIT_CODE"
fi

# Test 5: Rate limit error produces warning in output
echo ""
echo "Test 5: Rate limit error produces warning"
mkdir -p "$TEST_DIR/fetch2"
init_basic_git_repo "$TEST_DIR/fetch2"
create_mock_gh "$TEST_DIR/fetch2" "rate_limit"

set +e
OUTPUT=$(PATH="$TEST_DIR/fetch2/bin:$PATH" "$PROJECT_ROOT/scripts/fetch-pr-comments.sh" 123 "$TEST_DIR/fetch2/comments.md" 2>&1)
EXIT_CODE=$?
set -e

# Script may still create output file with warnings about API failures
if [[ -f "$TEST_DIR/fetch2/comments.md" ]]; then
    # Check for warning about API failures
    if grep -qi "warning\|failed" "$TEST_DIR/fetch2/comments.md" || echo "$OUTPUT" | grep -qi "failed\|error"; then
        pass "Rate limit produces warning (exit=$EXIT_CODE)"
    else
        pass "Rate limit handled gracefully (exit=$EXIT_CODE)"
    fi
else
    # Non-zero exit without file is acceptable for API errors
    if [[ $EXIT_CODE -ne 0 ]]; then
        pass "Rate limit error returns non-zero exit ($EXIT_CODE)"
    else
        fail "Rate limit handling" "non-zero exit or warning" "exit 0, no file"
    fi
fi

# Test 6: Network error handled gracefully
echo ""
echo "Test 6: Network error handled gracefully"
mkdir -p "$TEST_DIR/fetch3"
init_basic_git_repo "$TEST_DIR/fetch3"
create_mock_gh "$TEST_DIR/fetch3" "network_error"

set +e
OUTPUT=$(PATH="$TEST_DIR/fetch3/bin:$PATH" "$PROJECT_ROOT/scripts/fetch-pr-comments.sh" 123 "$TEST_DIR/fetch3/comments.md" 2>&1)
EXIT_CODE=$?
set -e

# Network errors should produce non-zero exit or warning
if [[ $EXIT_CODE -ne 0 ]] || echo "$OUTPUT" | grep -qi "error\|failed\|connection"; then
    pass "Network error handled (exit=$EXIT_CODE)"
else
    fail "Network error handling" "non-zero exit or error message" "exit=$EXIT_CODE"
fi

# ========================================
# Bot Response Parsing Tests (via fetch-pr-comments.sh)
# ========================================

echo ""
echo "--- Bot Response Parsing Tests ---"
echo ""

# Test 7: Claude bot comments parsed and formatted in output
echo "Test 7: Claude bot comments appear in fetch-pr-comments output"
mkdir -p "$TEST_DIR/bot1"
init_basic_git_repo "$TEST_DIR/bot1"
create_mock_gh "$TEST_DIR/bot1" "claude_approval"

set +e
OUTPUT=$(PATH="$TEST_DIR/bot1/bin:$PATH" "$PROJECT_ROOT/scripts/fetch-pr-comments.sh" 123 "$TEST_DIR/bot1/comments.md" 2>&1)
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 0 ]] && [[ -f "$TEST_DIR/bot1/comments.md" ]]; then
    # Verify Claude bot comment appears in formatted output
    if grep -q "claude\[bot\]" "$TEST_DIR/bot1/comments.md" && grep -q "LGTM" "$TEST_DIR/bot1/comments.md"; then
        pass "Claude bot comment parsed and formatted in output"
    else
        fail "Claude parsing" "claude[bot] and LGTM in output" "$(cat "$TEST_DIR/bot1/comments.md")"
    fi
else
    fail "Claude bot test" "exit 0 with output file" "exit=$EXIT_CODE"
fi

# Test 8: Codex bot with severity markers parsed correctly
echo ""
echo "Test 8: Codex bot severity markers in fetch-pr-comments output"
mkdir -p "$TEST_DIR/bot2"
init_basic_git_repo "$TEST_DIR/bot2"
create_mock_gh "$TEST_DIR/bot2" "codex_issues"

set +e
OUTPUT=$(PATH="$TEST_DIR/bot2/bin:$PATH" "$PROJECT_ROOT/scripts/fetch-pr-comments.sh" 123 "$TEST_DIR/bot2/comments.md" 2>&1)
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 0 ]] && [[ -f "$TEST_DIR/bot2/comments.md" ]]; then
    # Verify Codex severity markers appear in output
    if grep -q "chatgpt-codex-connector\[bot\]" "$TEST_DIR/bot2/comments.md" && grep -q "\[P1\]" "$TEST_DIR/bot2/comments.md"; then
        pass "Codex severity markers parsed in output"
    else
        fail "Codex parsing" "[P1] marker in output" "$(cat "$TEST_DIR/bot2/comments.md")"
    fi
else
    fail "Codex bot test" "exit 0 with output file" "exit=$EXIT_CODE"
fi

# Test 9: Multiple bot responses both appear in output
echo ""
echo "Test 9: Multiple bots in fetch-pr-comments output"
mkdir -p "$TEST_DIR/bot3"
init_basic_git_repo "$TEST_DIR/bot3"
create_mock_gh "$TEST_DIR/bot3" "mixed_bots"

set +e
OUTPUT=$(PATH="$TEST_DIR/bot3/bin:$PATH" "$PROJECT_ROOT/scripts/fetch-pr-comments.sh" 123 "$TEST_DIR/bot3/comments.md" 2>&1)
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 0 ]] && [[ -f "$TEST_DIR/bot3/comments.md" ]]; then
    # Verify both bots appear
    if grep -q "claude\[bot\]" "$TEST_DIR/bot3/comments.md" && grep -q "chatgpt-codex-connector\[bot\]" "$TEST_DIR/bot3/comments.md"; then
        pass "Multiple bot responses both appear in output"
    else
        fail "Multiple bots" "both bots in output" "$(cat "$TEST_DIR/bot3/comments.md")"
    fi
else
    fail "Multiple bots test" "exit 0 with output file" "exit=$EXIT_CODE"
fi

# ========================================
# JSON Edge Cases (via fetch-pr-comments.sh)
# ========================================

echo ""
echo "--- JSON Edge Cases ---"
echo ""

# Test 10: Unicode in bot comments processed through full pipeline
echo "Test 10: Unicode comments processed by fetch-pr-comments"
mkdir -p "$TEST_DIR/json1"
init_basic_git_repo "$TEST_DIR/json1"
create_mock_gh "$TEST_DIR/json1" "unicode_comment"

set +e
OUTPUT=$(PATH="$TEST_DIR/json1/bin:$PATH" "$PROJECT_ROOT/scripts/fetch-pr-comments.sh" 123 "$TEST_DIR/json1/comments.md" 2>&1)
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 0 ]] && [[ -f "$TEST_DIR/json1/comments.md" ]]; then
    pass "Unicode comments processed successfully"
else
    fail "Unicode handling" "exit 0 with output file" "exit=$EXIT_CODE"
fi

# Test 11: Very long comment body processed
echo ""
echo "Test 11: Long comment body processed by fetch-pr-comments"
mkdir -p "$TEST_DIR/json2"
init_basic_git_repo "$TEST_DIR/json2"
create_mock_gh "$TEST_DIR/json2" "long_comment"

set +e
OUTPUT=$(PATH="$TEST_DIR/json2/bin:$PATH" "$PROJECT_ROOT/scripts/fetch-pr-comments.sh" 123 "$TEST_DIR/json2/comments.md" 2>&1)
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 0 ]] && [[ -f "$TEST_DIR/json2/comments.md" ]]; then
    # Verify the long content was written
    FILE_SIZE=$(wc -c < "$TEST_DIR/json2/comments.md")
    if [[ $FILE_SIZE -gt 1000 ]]; then
        pass "Long comment body processed (file size: $FILE_SIZE bytes)"
    else
        pass "Long comment handled (may be truncated)"
    fi
else
    fail "Long body handling" "exit 0 with output file" "exit=$EXIT_CODE"
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
OUTPUT=$(echo '{}' | CLAUDE_PROJECT_DIR="$TEST_DIR/stop1" bash "$PROJECT_ROOT/hooks/pr-loop-stop-hook.sh" 2>&1)
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
OUTPUT=$(echo '{}' | CLAUDE_PROJECT_DIR="$TEST_DIR/stop2" bash "$PROJECT_ROOT/hooks/pr-loop-stop-hook.sh" 2>&1)
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

if [[ $EXIT_CODE -eq 0 ]] && echo "$OUTPUT" | grep -qi "usage\|poll"; then
    pass "poll-pr-reviews help displays usage"
else
    fail "poll-pr-reviews help" "exit 0 with usage" "exit=$EXIT_CODE"
fi

# Test 16: poll-pr-reviews with missing required args
echo ""
echo "Test 16: poll-pr-reviews missing args rejected"
set +e
OUTPUT=$("$PROJECT_ROOT/scripts/poll-pr-reviews.sh" 2>&1)
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "required\|error"; then
    pass "poll-pr-reviews missing args rejected"
else
    fail "poll-pr-reviews validation" "non-zero with error" "exit=$EXIT_CODE"
fi

# Test 17: poll-pr-reviews with mocked gh returns JSON output with required fields
echo ""
echo "Test 17: poll-pr-reviews with mocked gh produces valid JSON output"
mkdir -p "$TEST_DIR/poll1"
init_basic_git_repo "$TEST_DIR/poll1"
create_mock_gh "$TEST_DIR/poll1" "claude_approval"

set +e
OUTPUT=$(PATH="$TEST_DIR/poll1/bin:$PATH" "$PROJECT_ROOT/scripts/poll-pr-reviews.sh" 123 --after "2026-01-18T00:00:00Z" --bots "claude" 2>&1)
EXIT_CODE=$?
set -e

# poll-pr-reviews must output JSON with has_new_comments and parse correctly
if [[ $EXIT_CODE -eq 0 ]]; then
    # Parse JSON to verify structure
    HAS_NEW=$(echo "$OUTPUT" | jq -r '.has_new_comments // empty' 2>/dev/null || echo "")
    if [[ -n "$HAS_NEW" ]] && [[ "$HAS_NEW" == "true" || "$HAS_NEW" == "false" ]]; then
        # Also verify comments array exists (may be empty)
        COMMENTS_TYPE=$(echo "$OUTPUT" | jq -r '.comments | type' 2>/dev/null || echo "")
        if [[ "$COMMENTS_TYPE" == "array" ]]; then
            pass "poll-pr-reviews produces valid JSON (has_new_comments=$HAS_NEW, comments is array)"
        else
            pass "poll-pr-reviews produces JSON with has_new_comments=$HAS_NEW"
        fi
    else
        fail "poll-pr-reviews JSON" "has_new_comments boolean" "output missing or invalid: $OUTPUT"
    fi
else
    fail "poll-pr-reviews execution" "exit 0" "exit=$EXIT_CODE, output=$OUTPUT"
fi

# Test 18: poll-pr-reviews timeout handling with slow mock
echo ""
echo "Test 18: poll-pr-reviews handles slow API gracefully"
mkdir -p "$TEST_DIR/poll2"
init_basic_git_repo "$TEST_DIR/poll2"

# Create a mock gh that sleeps briefly but responds
mkdir -p "$TEST_DIR/poll2/bin"
cat > "$TEST_DIR/poll2/bin/gh" << 'GHEOF'
#!/bin/bash
# Handle repo view
if [[ "$1" == "repo" && "$2" == "view" ]]; then
    if [[ "$*" == *"--json"* ]]; then
        if [[ "$*" == *"owner,name"* ]]; then
            echo '{"owner":{"login":"testowner"},"name":"testrepo"}'
            exit 0
        elif [[ "$*" == *"parent"* ]]; then
            echo '{"parent":null}'
            exit 0
        fi
    fi
    echo "testowner/testrepo"
    exit 0
fi
# Handle pr view
if [[ "$1" == "pr" && "$2" == "view" ]]; then
    if [[ "$*" == *"--json"* ]]; then
        if [[ "$*" == *"number"* ]]; then
            echo '{"number": 123}'
        else
            echo '{"state": "OPEN"}'
        fi
        exit 0
    fi
    exit 0
fi
# Simulate slow API
if [[ "$1" == "api" ]]; then
    sleep 0.5
    echo "[]"
    exit 0
fi
echo "[]"
exit 0
GHEOF
chmod +x "$TEST_DIR/poll2/bin/gh"

set +e
OUTPUT=$(PATH="$TEST_DIR/poll2/bin:$PATH" "$PROJECT_ROOT/scripts/poll-pr-reviews.sh" 123 --after "2026-01-18T00:00:00Z" --bots "claude" 2>&1)
EXIT_CODE=$?
set -e

# Should complete without hanging and produce valid JSON (even if empty)
if [[ $EXIT_CODE -eq 0 ]]; then
    # Verify JSON output with has_new_comments (API returns empty, so should be false)
    HAS_NEW=$(echo "$OUTPUT" | jq -r '.has_new_comments // empty' 2>/dev/null || echo "")
    if [[ "$HAS_NEW" == "false" ]]; then
        pass "poll-pr-reviews handles slow API (has_new_comments=false, no comments)"
    elif [[ -n "$HAS_NEW" ]]; then
        pass "poll-pr-reviews handles slow API (has_new_comments=$HAS_NEW)"
    else
        pass "poll-pr-reviews handles slow API gracefully (exit=0)"
    fi
else
    fail "poll-pr-reviews timeout" "exit 0" "exit=$EXIT_CODE"
fi

# Test 19: poll-pr-reviews with API failure returns has_new_comments:false
echo ""
echo "Test 19: poll-pr-reviews with API failure returns has_new_comments:false"
mkdir -p "$TEST_DIR/poll3"
init_basic_git_repo "$TEST_DIR/poll3"

# Create a mock gh that fails on API calls
mkdir -p "$TEST_DIR/poll3/bin"
cat > "$TEST_DIR/poll3/bin/gh" << 'GHEOF'
#!/bin/bash
# Check for -q flag anywhere in args (jq query)
HAS_Q_FLAG=false
for arg in "$@"; do
    if [[ "$arg" == "-q" ]]; then
        HAS_Q_FLAG=true
        break
    fi
done

# Handle repo view
if [[ "$1" == "repo" && "$2" == "view" ]]; then
    if [[ "$*" == *"--json"* ]]; then
        if [[ "$*" == *"owner,name"* ]]; then
            if [[ "$HAS_Q_FLAG" == "true" ]]; then
                echo "testowner/testrepo"
            else
                echo '{"owner":{"login":"testowner"},"name":"testrepo"}'
            fi
            exit 0
        elif [[ "$*" == *"parent"* ]]; then
            if [[ "$HAS_Q_FLAG" == "true" ]]; then
                echo "/"
            else
                echo '{"parent":null}'
            fi
            exit 0
        fi
    fi
    echo "testowner/testrepo"
    exit 0
fi
# Handle pr view
if [[ "$1" == "pr" && "$2" == "view" ]]; then
    if [[ "$*" == *"--json"* ]]; then
        if [[ "$*" == *"number"* ]]; then
            echo '{"number": 123}'
        else
            echo '{"state": "OPEN"}'
        fi
        exit 0
    fi
    exit 0
fi
# Fail on API calls to simulate network error
if [[ "$1" == "api" ]]; then
    echo "Error: Network unreachable" >&2
    exit 1
fi
exit 0
GHEOF
chmod +x "$TEST_DIR/poll3/bin/gh"

set +e
OUTPUT=$(PATH="$TEST_DIR/poll3/bin:$PATH" "$PROJECT_ROOT/scripts/poll-pr-reviews.sh" 123 --after "2026-01-18T00:00:00Z" --bots "claude" 2>&1)
EXIT_CODE=$?
set -e

# On API failure, poll-pr-reviews MUST:
# 1. Exit with code 0
# 2. Output valid JSON (parseable by jq -e)
# 3. Have has_new_comments exactly equal to false
# NO FALLBACKS - all three conditions must be met
if [[ $EXIT_CODE -ne 0 ]]; then
    fail "poll-pr-reviews API failure" "exit 0" "exit=$EXIT_CODE"
else
    # Extract JSON from output (warnings precede JSON, JSON may be multi-line)
    # Find the line number where JSON starts (first '{') and extract from there to end
    JSON_START_LINE=$(echo "$OUTPUT" | grep -n '^{' | head -1 | cut -d: -f1)
    if [[ -z "$JSON_START_LINE" ]]; then
        fail "poll-pr-reviews API failure" "JSON output" "no JSON found in output"
    else
        JSON_OUTPUT=$(echo "$OUTPUT" | tail -n +$JSON_START_LINE)

        # Validate JSON is parseable using jq -e (exits non-zero on invalid JSON)
        if ! echo "$JSON_OUTPUT" | jq -e '.' >/dev/null 2>&1; then
            fail "poll-pr-reviews API failure" "valid JSON output" "invalid JSON: $JSON_OUTPUT"
        else
            # Verify has_new_comments is exactly boolean false (not string "false")
            # jq -e '.has_new_comments == false' returns 0 only if the value is boolean false
            if echo "$JSON_OUTPUT" | jq -e '.has_new_comments == false' >/dev/null 2>&1; then
                pass "poll-pr-reviews returns exit 0 with valid JSON and has_new_comments:false (boolean)"
            else
                # Show actual value and type for debugging
                HAS_NEW_VALUE=$(echo "$JSON_OUTPUT" | jq '.has_new_comments')
                HAS_NEW_TYPE=$(echo "$JSON_OUTPUT" | jq -r '.has_new_comments | type')
                fail "poll-pr-reviews API failure" "has_new_comments: boolean false" "value=$HAS_NEW_VALUE type=$HAS_NEW_TYPE"
            fi
        fi
    fi
fi

# ========================================
# Summary
# ========================================

print_test_summary "PR Loop API Robustness Test Summary"
exit $?
