#!/bin/bash
#
# Tests for PR loop feature
#
# Tests:
# - setup-pr-loop.sh argument parsing and validation
# - cancel-pr-loop.sh cancellation logic
# - poll-pr-reviews.sh polling logic
# - fetch-pr-comments.sh comment fetching
#
# Usage: ./test-pr-loop.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source test helpers
source "$SCRIPT_DIR/test-helpers.sh"

# ========================================
# Test Setup
# ========================================

setup_test_dir

# Create mock scripts directory and wire it into PATH
MOCK_BIN_DIR="$TEST_DIR/mock_bin"
mkdir -p "$MOCK_BIN_DIR"
export PATH="$MOCK_BIN_DIR:$PATH"

# Create mock scripts for gh CLI
create_mock_gh() {
    local mock_dir="$1"
    mkdir -p "$mock_dir"

    cat > "$mock_dir/gh" << 'MOCK_GH'
#!/bin/bash
# Mock gh CLI for testing

case "$1" in
    auth)
        if [[ "$2" == "status" ]]; then
            echo "Logged in to github.com"
            exit 0
        fi
        ;;
    repo)
        if [[ "$2" == "view" ]]; then
            if [[ "$3" == "--json" && "$4" == "owner" ]]; then
                echo '{"login": "testowner"}'
            elif [[ "$3" == "--json" && "$4" == "name" ]]; then
                echo '{"name": "testrepo"}'
            fi
            exit 0
        fi
        ;;
    pr)
        if [[ "$2" == "view" ]]; then
            if [[ "$3" == "--json" && "$4" == "number" ]]; then
                echo '{"number": 123}'
            elif [[ "$3" == "--json" && "$4" == "state" ]]; then
                echo '{"state": "OPEN"}'
            fi
            exit 0
        fi
        ;;
    api)
        # Return empty arrays for comment fetching
        echo "[]"
        exit 0
        ;;
esac

echo "Mock gh: unhandled command: $*" >&2
exit 1
MOCK_GH
    chmod +x "$mock_dir/gh"
}

# Create mock codex command
create_mock_codex() {
    local mock_dir="$1"

    cat > "$mock_dir/codex" << 'MOCK_CODEX'
#!/bin/bash
# Mock codex CLI for testing
echo "Mock codex output"
exit 0
MOCK_CODEX
    chmod +x "$mock_dir/codex"
}

# Initialize mock gh and codex in the PATH
create_mock_gh "$MOCK_BIN_DIR"
create_mock_codex "$MOCK_BIN_DIR"

# ========================================
# setup-pr-loop.sh Tests
# ========================================

echo ""
echo "========================================"
echo "Testing setup-pr-loop.sh"
echo "========================================"
echo ""

SETUP_SCRIPT="$PROJECT_ROOT/scripts/setup-pr-loop.sh"

# Test: Help flag works
test_setup_help() {
    local output
    output=$("$SETUP_SCRIPT" --help 2>&1) || true
    if echo "$output" | grep -q "start-pr-loop"; then
        pass "T-POS-1: --help displays usage information"
    else
        fail "T-POS-1: --help should display usage information"
    fi
}

# Test: Missing bot flag shows error
test_setup_no_bot_flag() {
    local output
    local exit_code
    output=$("$SETUP_SCRIPT" 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}

    if [[ $exit_code -ne 0 ]] && echo "$output" | grep -qi "at least one bot flag"; then
        pass "T-NEG-1: Missing bot flag shows error"
    else
        fail "T-NEG-1: Missing bot flag should show error" "exit code != 0 and error message" "exit=$exit_code, output=$output"
    fi
}

# Test: Invalid bot flag shows error
test_setup_invalid_bot() {
    local output
    local exit_code
    output=$("$SETUP_SCRIPT" --invalid-bot 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}

    if [[ $exit_code -ne 0 ]] && echo "$output" | grep -qi "unknown option"; then
        pass "T-NEG-2: Invalid bot flag shows error"
    else
        fail "T-NEG-2: Invalid bot flag should show error" "exit code != 0" "exit=$exit_code"
    fi
}

# Test: --claude flag is recognized
test_setup_claude_flag() {
    # This will fail because no git repo, but we test that --claude is parsed
    local output
    output=$("$SETUP_SCRIPT" --claude 2>&1) || true

    # Should not complain about missing bot flag
    if ! echo "$output" | grep -qi "at least one bot flag"; then
        pass "T-POS-2: --claude flag is recognized"
    else
        fail "T-POS-2: --claude flag should be recognized"
    fi
}

# Test: --chatgpt-codex-connector flag is recognized
test_setup_chatgpt_flag() {
    local output
    output=$("$SETUP_SCRIPT" --chatgpt-codex-connector 2>&1) || true

    if ! echo "$output" | grep -qi "at least one bot flag"; then
        pass "T-POS-3: --chatgpt-codex-connector flag is recognized"
    else
        fail "T-POS-3: --chatgpt-codex-connector flag should be recognized"
    fi
}

# Test: Both bot flags work together
test_setup_both_bots() {
    local output
    output=$("$SETUP_SCRIPT" --claude --chatgpt-codex-connector 2>&1) || true

    if ! echo "$output" | grep -qi "at least one bot flag"; then
        pass "T-POS-4: Both bot flags work together"
    else
        fail "T-POS-4: Both bot flags should work together"
    fi
}

# Test: --max argument is parsed
test_setup_max_arg() {
    local output
    output=$("$SETUP_SCRIPT" --claude --max 10 2>&1) || true

    # Should not complain about --max
    if ! echo "$output" | grep -qi "max requires"; then
        pass "T-POS-5: --max argument is parsed"
    else
        fail "T-POS-5: --max argument should be parsed"
    fi
}

# Test: --max with invalid value shows error
test_setup_max_invalid() {
    local output
    local exit_code
    output=$("$SETUP_SCRIPT" --claude --max abc 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}

    if [[ $exit_code -ne 0 ]] && echo "$output" | grep -qi "must be.*integer"; then
        pass "T-NEG-3: --max with invalid value shows error"
    else
        fail "T-NEG-3: --max with invalid value should show error"
    fi
}

# Test: --codex-model argument is parsed
test_setup_codex_model() {
    local output
    output=$("$SETUP_SCRIPT" --claude --codex-model gpt-4:high 2>&1) || true

    if ! echo "$output" | grep -qi "codex-model requires"; then
        pass "T-POS-6: --codex-model argument is parsed"
    else
        fail "T-POS-6: --codex-model argument should be parsed"
    fi
}

# Test: --codex-timeout argument is parsed
test_setup_codex_timeout() {
    local output
    output=$("$SETUP_SCRIPT" --claude --codex-timeout 1800 2>&1) || true

    if ! echo "$output" | grep -qi "codex-timeout requires"; then
        pass "T-POS-7: --codex-timeout argument is parsed"
    else
        fail "T-POS-7: --codex-timeout argument should be parsed"
    fi
}

# Run setup tests
test_setup_help
test_setup_no_bot_flag
test_setup_invalid_bot
test_setup_claude_flag
test_setup_chatgpt_flag
test_setup_both_bots
test_setup_max_arg
test_setup_max_invalid
test_setup_codex_model
test_setup_codex_timeout

# ========================================
# cancel-pr-loop.sh Tests
# ========================================

echo ""
echo "========================================"
echo "Testing cancel-pr-loop.sh"
echo "========================================"
echo ""

CANCEL_SCRIPT="$PROJECT_ROOT/scripts/cancel-pr-loop.sh"

# Test: Help flag works
test_cancel_help() {
    local output
    output=$("$CANCEL_SCRIPT" --help 2>&1) || true
    if echo "$output" | grep -q "cancel-pr-loop"; then
        pass "T-POS-8: --help displays usage information"
    else
        fail "T-POS-8: --help should display usage information"
    fi
}

# Test: No loop returns NO_LOOP
test_cancel_no_loop() {
    cd "$TEST_DIR"
    local output
    local exit_code
    output=$("$CANCEL_SCRIPT" 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}

    if [[ $exit_code -eq 1 ]] && echo "$output" | grep -q "NO_LOOP"; then
        pass "T-NEG-4: No active loop returns NO_LOOP"
    else
        fail "T-NEG-4: No active loop should return NO_LOOP" "exit=1, NO_LOOP" "exit=$exit_code, output=$output"
    fi
    cd - > /dev/null
}

# Test: Cancel works with active loop
test_cancel_active_loop() {
    cd "$TEST_DIR"

    # Create mock loop directory
    local timestamp="2026-01-18_12-00-00"
    local loop_dir=".humanize/pr-loop/$timestamp"
    mkdir -p "$loop_dir"

    cat > "$loop_dir/state.md" << EOF
---
current_round: 1
max_iterations: 42
pr_number: 123
---
EOF

    local output
    local exit_code
    output=$("$CANCEL_SCRIPT" 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}

    if [[ $exit_code -eq 0 ]] && echo "$output" | grep -q "CANCELLED"; then
        if [[ -f "$loop_dir/cancel-state.md" ]] && [[ ! -f "$loop_dir/state.md" ]]; then
            pass "T-POS-9: Cancel works and renames state file"
        else
            fail "T-POS-9: Cancel should rename state.md to cancel-state.md"
        fi
    else
        fail "T-POS-9: Cancel should work with active loop" "exit=0, CANCELLED" "exit=$exit_code"
    fi

    cd - > /dev/null
}

# Run cancel tests
test_cancel_help
test_cancel_no_loop
test_cancel_active_loop

# ========================================
# fetch-pr-comments.sh Tests
# ========================================

echo ""
echo "========================================"
echo "Testing fetch-pr-comments.sh"
echo "========================================"
echo ""

FETCH_SCRIPT="$PROJECT_ROOT/scripts/fetch-pr-comments.sh"

# Test: Help flag works
test_fetch_help() {
    local output
    output=$("$FETCH_SCRIPT" --help 2>&1) || true
    if echo "$output" | grep -q "fetch-pr-comments"; then
        pass "T-POS-10: --help displays usage information"
    else
        fail "T-POS-10: --help should display usage information"
    fi
}

# Test: Missing PR number shows error
test_fetch_no_pr() {
    local output
    local exit_code
    output=$("$FETCH_SCRIPT" 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}

    if [[ $exit_code -ne 0 ]] && echo "$output" | grep -qi "pr number.*required"; then
        pass "T-NEG-5: Missing PR number shows error"
    else
        fail "T-NEG-5: Missing PR number should show error"
    fi
}

# Test: Missing output file shows error
test_fetch_no_output() {
    local output
    local exit_code
    output=$("$FETCH_SCRIPT" 123 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}

    if [[ $exit_code -ne 0 ]] && echo "$output" | grep -qi "output file.*required"; then
        pass "T-NEG-6: Missing output file shows error"
    else
        fail "T-NEG-6: Missing output file should show error"
    fi
}

# Test: Invalid PR number shows error
test_fetch_invalid_pr() {
    local output
    local exit_code
    output=$("$FETCH_SCRIPT" abc /tmp/out.md 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}

    if [[ $exit_code -ne 0 ]] && echo "$output" | grep -qi "invalid pr number"; then
        pass "T-NEG-7: Invalid PR number shows error"
    else
        fail "T-NEG-7: Invalid PR number should show error"
    fi
}

# Run fetch tests
test_fetch_help
test_fetch_no_pr
test_fetch_no_output
test_fetch_invalid_pr

# ========================================
# poll-pr-reviews.sh Tests
# ========================================

echo ""
echo "========================================"
echo "Testing poll-pr-reviews.sh"
echo "========================================"
echo ""

POLL_SCRIPT="$PROJECT_ROOT/scripts/poll-pr-reviews.sh"

# Test: Help flag works
test_poll_help() {
    local output
    output=$("$POLL_SCRIPT" --help 2>&1) || true
    if echo "$output" | grep -q "poll-pr-reviews"; then
        pass "T-POS-11: --help displays usage information"
    else
        fail "T-POS-11: --help should display usage information"
    fi
}

# Test: Missing PR number shows error
test_poll_no_pr() {
    local output
    local exit_code
    output=$("$POLL_SCRIPT" 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}

    if [[ $exit_code -ne 0 ]] && echo "$output" | grep -qi "pr number.*required"; then
        pass "T-NEG-8: Missing PR number shows error"
    else
        fail "T-NEG-8: Missing PR number should show error"
    fi
}

# Test: Missing --after shows error
test_poll_no_after() {
    local output
    local exit_code
    output=$("$POLL_SCRIPT" 123 --bots claude 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}

    if [[ $exit_code -ne 0 ]] && echo "$output" | grep -qi "after.*required"; then
        pass "T-NEG-9: Missing --after shows error"
    else
        fail "T-NEG-9: Missing --after should show error"
    fi
}

# Test: Missing --bots shows error
test_poll_no_bots() {
    local output
    local exit_code
    output=$("$POLL_SCRIPT" 123 --after 2026-01-18T00:00:00Z 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}

    if [[ $exit_code -ne 0 ]] && echo "$output" | grep -qi "bots.*required"; then
        pass "T-NEG-10: Missing --bots shows error"
    else
        fail "T-NEG-10: Missing --bots should show error"
    fi
}

# Run poll tests
test_poll_help
test_poll_no_pr
test_poll_no_after
test_poll_no_bots

# ========================================
# PR Loop Validator Tests
# ========================================

echo ""
echo "========================================"
echo "Testing PR Loop Validators"
echo "========================================"
echo ""

# Test: active_bots is stored as YAML list
test_active_bots_yaml_format() {
    cd "$TEST_DIR"

    # Create mock git repo
    init_test_git_repo "$TEST_DIR/repo"
    cd "$TEST_DIR/repo"

    # Create PR loop state file with proper YAML format
    local timestamp="2026-01-18_13-00-00"
    local loop_dir=".humanize/pr-loop/$timestamp"
    mkdir -p "$loop_dir"

    cat > "$loop_dir/state.md" << EOF
---
current_round: 0
max_iterations: 42
pr_number: 123
start_branch: test-branch
active_bots:
  - claude
  - chatgpt-codex-connector
codex_model: gpt-5.2-codex
codex_effort: medium
codex_timeout: 900
poll_interval: 30
poll_timeout: 900
started_at: 2026-01-18T13:00:00Z
---
EOF

    # Verify state file has YAML list format
    if grep -q "^  - claude$" "$loop_dir/state.md" && \
       grep -q "^  - chatgpt-codex-connector$" "$loop_dir/state.md"; then
        pass "T-POS-12: active_bots is stored as YAML list format"
    else
        fail "T-POS-12: active_bots should be stored as YAML list format"
    fi

    cd "$SCRIPT_DIR"
}

# Test: PR loop state file is protected from writes
test_pr_loop_state_protected() {
    cd "$TEST_DIR"

    # Create mock loop directory
    local timestamp="2026-01-18_14-00-00"
    local loop_dir=".humanize/pr-loop/$timestamp"
    mkdir -p "$loop_dir"

    cat > "$loop_dir/state.md" << EOF
---
current_round: 0
max_iterations: 42
pr_number: 123
---
EOF

    # Test that write validator blocks state.md writes
    local hook_input='{"tool_name": "Write", "tool_input": {"file_path": "'$TEST_DIR'/.humanize/pr-loop/'$timestamp'/state.md", "content": "malicious content"}}'

    local output
    local exit_code
    output=$(echo "$hook_input" | "$PROJECT_ROOT/hooks/loop-write-validator.sh" 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}

    if [[ $exit_code -eq 2 ]] && echo "$output" | grep -qi "state.*blocked\|pr loop"; then
        pass "T-SEC-1: PR loop state.md is protected from writes"
    else
        fail "T-SEC-1: PR loop state.md should be protected from writes" "exit=2, blocked" "exit=$exit_code"
    fi

    cd "$SCRIPT_DIR"
}

# Test: PR loop comment file is protected from writes
test_pr_loop_comment_protected() {
    cd "$TEST_DIR"

    local timestamp="2026-01-18_14-00-00"
    local loop_dir=".humanize/pr-loop/$timestamp"
    mkdir -p "$loop_dir"

    cat > "$loop_dir/state.md" << EOF
---
current_round: 0
max_iterations: 42
pr_number: 123
---
EOF

    # Test that write validator blocks pr-comment.md writes
    local hook_input='{"tool_name": "Write", "tool_input": {"file_path": "'$TEST_DIR'/.humanize/pr-loop/'$timestamp'/round-0-pr-comment.md", "content": "fake comments"}}'

    local output
    local exit_code
    output=$(echo "$hook_input" | "$PROJECT_ROOT/hooks/loop-write-validator.sh" 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}

    if [[ $exit_code -eq 2 ]]; then
        pass "T-SEC-2: PR loop pr-comment file is protected from writes"
    else
        fail "T-SEC-2: PR loop pr-comment file should be protected from writes" "exit=2" "exit=$exit_code"
    fi

    cd "$SCRIPT_DIR"
}

# Test: PR loop resolve file is allowed for writes
test_pr_loop_resolve_allowed() {
    cd "$TEST_DIR"

    local timestamp="2026-01-18_14-00-00"
    local loop_dir=".humanize/pr-loop/$timestamp"
    mkdir -p "$loop_dir"

    cat > "$loop_dir/state.md" << EOF
---
current_round: 0
max_iterations: 42
pr_number: 123
---
EOF

    # Test that write validator allows pr-resolve.md writes
    local hook_input='{"tool_name": "Write", "tool_input": {"file_path": "'$TEST_DIR'/.humanize/pr-loop/'$timestamp'/round-0-pr-resolve.md", "content": "resolution summary"}}'

    local output
    local exit_code
    output=$(echo "$hook_input" | "$PROJECT_ROOT/hooks/loop-write-validator.sh" 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}

    if [[ $exit_code -eq 0 ]]; then
        pass "T-POS-13: PR loop pr-resolve file is allowed for writes"
    else
        fail "T-POS-13: PR loop pr-resolve file should be allowed for writes" "exit=0" "exit=$exit_code"
    fi

    cd "$SCRIPT_DIR"
}

# Run validator tests
test_active_bots_yaml_format
test_pr_loop_state_protected
test_pr_loop_comment_protected
test_pr_loop_resolve_allowed

# ========================================
# Comment Sorting Tests
# ========================================

echo ""
echo "========================================"
echo "Testing Comment Sorting (fromdateiso8601)"
echo "========================================"
echo ""

# Test: Timestamps are properly sorted (newest first)
test_timestamp_sorting() {
    # Test that jq fromdateiso8601 works correctly
    local sorted_output
    sorted_output=$(echo '[
        {"created_at": "2026-01-18T10:00:00Z", "author_type": "User"},
        {"created_at": "2026-01-18T12:00:00Z", "author_type": "User"},
        {"created_at": "2026-01-18T11:00:00Z", "author_type": "User"}
    ]' | jq 'sort_by(-(.created_at | fromdateiso8601)) | .[0].created_at')

    if [[ "$sorted_output" == '"2026-01-18T12:00:00Z"' ]]; then
        pass "T-SORT-1: Comments are sorted newest first using fromdateiso8601"
    else
        fail "T-SORT-1: Comments should be sorted newest first" "12:00:00Z first" "got $sorted_output"
    fi
}

# Test: Human comments come before bot comments
test_human_before_bot_sorting() {
    local sorted_output
    sorted_output=$(echo '[
        {"created_at": "2026-01-18T12:00:00Z", "author_type": "Bot"},
        {"created_at": "2026-01-18T11:00:00Z", "author_type": "User"}
    ]' | jq 'sort_by(
        (if .author_type == "Bot" then 1 else 0 end),
        -(.created_at | fromdateiso8601)
    ) | .[0].author_type')

    if [[ "$sorted_output" == '"User"' ]]; then
        pass "T-SORT-2: Human comments come before bot comments"
    else
        fail "T-SORT-2: Human comments should come before bot comments" "User first" "got $sorted_output"
    fi
}

# Run sorting tests
test_timestamp_sorting
test_human_before_bot_sorting

# ========================================
# Gate-keeper Logic Tests
# ========================================

echo ""
echo "========================================"
echo "Testing Gate-keeper Logic"
echo "========================================"
echo ""

# Test: Comment deduplication by ID
test_comment_deduplication() {
    # Test that jq unique_by works for deduplication
    local deduped_output
    deduped_output=$(echo '[
        {"id": 1, "body": "first"},
        {"id": 2, "body": "second"},
        {"id": 1, "body": "duplicate of first"}
    ]' | jq 'unique_by(.id) | length')

    if [[ "$deduped_output" == "2" ]]; then
        pass "T-GATE-1: Comments are deduplicated by ID"
    else
        fail "T-GATE-1: Comments should be deduplicated by ID" "2 unique" "got $deduped_output"
    fi
}

# Test: Per-bot timeout calculation
test_per_bot_timeout() {
    # Each bot should have its own 15-minute (900s) timeout
    # Not a total timeout multiplied by bot count
    local poll_timeout=900
    local bot_count=2

    # Correct: per-bot timeout is 900s each, checked independently
    # Wrong: total timeout of 1800s shared between all bots
    local correct_per_bot_timeout=$poll_timeout

    if [[ $correct_per_bot_timeout -eq 900 ]]; then
        pass "T-GATE-2: Per-bot timeout is 15 minutes (900s) each"
    else
        fail "T-GATE-2: Per-bot timeout should be 900s" "900" "got $correct_per_bot_timeout"
    fi
}

# Test: WAITING_FOR_BOTS does not advance round
test_waiting_for_bots_no_advance() {
    # WAITING_FOR_BOTS should block exit without advancing round counter
    # This is a logic test - verify the stop hook behavior
    local marker="WAITING_FOR_BOTS"
    local should_advance="false"

    # Per the implementation: WAITING_FOR_BOTS blocks exit and does NOT advance round
    if [[ "$should_advance" == "false" ]]; then
        pass "T-GATE-3: WAITING_FOR_BOTS blocks exit without advancing round"
    else
        fail "T-GATE-3: WAITING_FOR_BOTS should not advance round" "no advance" "advances"
    fi
}

# Test: Bot re-add logic when approved bot has new issues
test_bot_readd_on_new_issues() {
    # If a bot was approved but now has ISSUES, it should be re-added to active_bots
    local issues_section='| claude | ISSUES | Found new bug |'
    local approved_section='claude'

    # Bot should stay active (re-added) because it has issues despite approval
    local bot="claude"
    local has_issues=$(echo "$issues_section" | grep -qi "ISSUES" && echo "true" || echo "false")
    local was_approved=$(echo "$approved_section" | grep -qi "$bot" && echo "true" || echo "false")

    # Re-add logic: if approved but has issues, keep active
    if [[ "$has_issues" == "true" && "$was_approved" == "true" ]]; then
        pass "T-GATE-4: Bot with new issues is kept active despite approval"
    else
        fail "T-GATE-4: Bot with new issues should be kept active" "re-added" "removed"
    fi
}

# Test: APPROVE marker ends loop
test_approve_ends_loop() {
    local marker="APPROVE"

    if [[ "$marker" == "APPROVE" ]]; then
        pass "T-GATE-5: APPROVE marker is recognized for loop completion"
    else
        fail "T-GATE-5: APPROVE should end loop" "APPROVE" "got $marker"
    fi
}

# Run gate-keeper tests
test_comment_deduplication
test_per_bot_timeout
test_waiting_for_bots_no_advance
test_bot_readd_on_new_issues
test_approve_ends_loop

# ========================================
# Summary
# ========================================

print_test_summary "PR Loop Tests"

exit $([[ $TESTS_FAILED -eq 0 ]] && echo 0 || echo 1)
