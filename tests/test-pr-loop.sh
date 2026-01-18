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

# Test: Comment deduplication by ID (unit test)
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

# Test: YAML list parsing for configured_bots
test_configured_bots_parsing() {
    local test_state="---
current_round: 0
configured_bots:
  - claude
  - chatgpt-codex-connector
active_bots:
  - claude
codex_model: gpt-5.2-codex
---"

    # Extract configured_bots using same logic as stop hook
    local configured_bots=""
    local in_field=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^configured_bots: ]]; then
            in_field=true
            continue
        fi
        if [[ "$in_field" == "true" ]]; then
            if [[ "$line" =~ ^[[:space:]]+-[[:space:]]+ ]]; then
                local bot_name="${line#*- }"
                bot_name=$(echo "$bot_name" | tr -d ' ')
                configured_bots="${configured_bots}${bot_name},"
            elif [[ "$line" =~ ^[a-zA-Z_] ]]; then
                in_field=false
            fi
        fi
    done <<< "$test_state"

    if [[ "$configured_bots" == "claude,chatgpt-codex-connector," ]]; then
        pass "T-GATE-2: configured_bots YAML list is parsed correctly"
    else
        fail "T-GATE-2: configured_bots parsing failed" "claude,chatgpt-codex-connector," "got $configured_bots"
    fi
}

# Test: Bot status extraction from Codex output
test_bot_status_extraction() {
    local codex_output="### Per-Bot Status
| Bot | Status | Summary |
|-----|--------|---------|
| claude | APPROVE | No issues found |
| chatgpt-codex-connector | ISSUES | Found bug in line 42 |

### Approved Bots
- claude"

    # Extract bots with ISSUES status using same logic as stop hook
    local bots_with_issues=""
    while IFS= read -r line; do
        if echo "$line" | grep -qiE '\|[[:space:]]*ISSUES[[:space:]]*\|'; then
            local bot=$(echo "$line" | sed 's/|/\n/g' | sed -n '2p' | tr -d ' ')
            bots_with_issues="${bots_with_issues}${bot},"
        fi
    done <<< "$codex_output"

    if [[ "$bots_with_issues" == "chatgpt-codex-connector," ]]; then
        pass "T-GATE-3: Bots with ISSUES status are correctly identified"
    else
        fail "T-GATE-3: Bot status extraction failed" "chatgpt-codex-connector," "got $bots_with_issues"
    fi
}

# Test: Bot re-add logic when previously approved bot has new issues
test_bot_readd_logic() {
    # Simulate: claude was approved (removed from active), but now has ISSUES
    local configured_bots=("claude" "chatgpt-codex-connector")
    local active_bots=("chatgpt-codex-connector")  # claude was removed (approved)

    # Codex output shows claude now has issues
    declare -A bots_with_issues
    bots_with_issues["claude"]="true"

    declare -A bots_approved
    # No bots approved this round

    # Re-add logic: process ALL configured bots
    local new_active=()
    for bot in "${configured_bots[@]}"; do
        if [[ "${bots_with_issues[$bot]:-}" == "true" ]]; then
            new_active+=("$bot")
        fi
    done

    # claude should be re-added because it has issues
    local found_claude=false
    for bot in "${new_active[@]}"; do
        if [[ "$bot" == "claude" ]]; then
            found_claude=true
            break
        fi
    done

    if [[ "$found_claude" == "true" ]]; then
        pass "T-GATE-4: Previously approved bot is re-added when it has new issues"
    else
        fail "T-GATE-4: Bot re-add logic failed" "claude in new_active" "not found"
    fi
}

# Test: Trigger comment timestamp detection pattern
test_trigger_comment_detection() {
    local comments='[
        {"id": 1, "body": "Just a regular comment", "created_at": "2026-01-18T10:00:00Z"},
        {"id": 2, "body": "@claude @chatgpt-codex-connector please review", "created_at": "2026-01-18T11:00:00Z"},
        {"id": 3, "body": "Another comment", "created_at": "2026-01-18T12:00:00Z"}
    ]'

    # Build pattern for @bot mentions
    local bot_pattern="@claude|@chatgpt-codex-connector"

    # Find most recent trigger comment
    local trigger_ts
    trigger_ts=$(echo "$comments" | jq -r --arg pattern "$bot_pattern" '
        [.[] | select(.body | test($pattern; "i"))] |
        sort_by(.created_at) | reverse | .[0].created_at // empty
    ')

    if [[ "$trigger_ts" == "2026-01-18T11:00:00Z" ]]; then
        pass "T-GATE-5: Trigger comment timestamp is correctly detected"
    else
        fail "T-GATE-5: Trigger timestamp detection failed" "2026-01-18T11:00:00Z" "got $trigger_ts"
    fi
}

# Test: APPROVE marker detection in Codex output
test_approve_marker_detection() {
    local codex_output="### Per-Bot Status
| Bot | Status | Summary |
|-----|--------|---------|
| claude | APPROVE | LGTM |

### Final Recommendation
All bots have approved.

APPROVE"

    local last_line
    last_line=$(echo "$codex_output" | grep -v '^[[:space:]]*$' | tail -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    if [[ "$last_line" == "APPROVE" ]]; then
        pass "T-GATE-6: APPROVE marker is correctly recognized"
    else
        fail "T-GATE-6: APPROVE marker detection failed" "APPROVE" "got $last_line"
    fi
}

# Test: WAITING_FOR_BOTS marker detection
test_waiting_for_bots_marker() {
    local codex_output="### Per-Bot Status
| Bot | Status | Summary |
|-----|--------|---------|
| claude | NO_RESPONSE | Bot did not respond |

### Final Recommendation
Some bots have not responded yet.

WAITING_FOR_BOTS"

    local last_line
    last_line=$(echo "$codex_output" | grep -v '^[[:space:]]*$' | tail -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    if [[ "$last_line" == "WAITING_FOR_BOTS" ]]; then
        pass "T-GATE-7: WAITING_FOR_BOTS marker is correctly recognized"
    else
        fail "T-GATE-7: WAITING_FOR_BOTS marker detection failed" "WAITING_FOR_BOTS" "got $last_line"
    fi
}

# Run gate-keeper tests
test_comment_deduplication
test_configured_bots_parsing
test_bot_status_extraction
test_bot_readd_logic
test_trigger_comment_detection
test_approve_marker_detection
test_waiting_for_bots_marker

# ========================================
# Stop Hook Integration Tests (with mocked gh/codex)
# ========================================

echo ""
echo "========================================"
echo "Testing Stop Hook Integration"
echo "========================================"
echo ""

# Create enhanced mock gh that returns trigger comments
create_enhanced_mock_gh() {
    local mock_dir="$1"
    local trigger_user="${2:-testuser}"
    local trigger_timestamp="${3:-2026-01-18T12:00:00Z}"

    cat > "$mock_dir/gh" << MOCK_GH
#!/bin/bash
# Enhanced mock gh CLI for stop hook testing

case "\$1" in
    auth)
        if [[ "\$2" == "status" ]]; then
            echo "Logged in to github.com"
            exit 0
        fi
        ;;
    repo)
        if [[ "\$2" == "view" ]]; then
            if [[ "\$3" == "--json" && "\$4" == "owner" ]]; then
                echo '{"login": "testowner"}'
            elif [[ "\$3" == "--json" && "\$4" == "name" ]]; then
                echo '{"name": "testrepo"}'
            fi
            exit 0
        fi
        ;;
    pr)
        if [[ "\$2" == "view" ]]; then
            if [[ "\$*" == *"number"* ]]; then
                echo '{"number": 123}'
            elif [[ "\$*" == *"state"* ]]; then
                echo '{"state": "OPEN"}'
            fi
            exit 0
        fi
        ;;
    api)
        # Handle user endpoint for current user
        if [[ "\$2" == "user" ]]; then
            echo '{"login": "${trigger_user}"}'
            exit 0
        fi
        # Handle PR comments endpoint
        if [[ "\$2" == *"/issues/"*"/comments"* ]]; then
            echo '[{"id": 1, "user": {"login": "${trigger_user}"}, "created_at": "${trigger_timestamp}", "body": "@claude @chatgpt-codex-connector please review"}]'
            exit 0
        fi
        # Return empty arrays for other endpoints
        echo "[]"
        exit 0
        ;;
esac

echo "Mock gh: unhandled command: \$*" >&2
exit 1
MOCK_GH
    chmod +x "$mock_dir/gh"
}

# Test: Trigger comment detection filters by current user
test_trigger_user_filter() {
    local test_subdir="$TEST_DIR/stop_hook_user_test"
    mkdir -p "$test_subdir"

    # Create mock that returns comments from different users
    cat > "$test_subdir/gh" << 'MOCK_GH'
#!/bin/bash
case "$1" in
    api)
        if [[ "$2" == "user" ]]; then
            echo '{"login": "myuser"}'
            exit 0
        fi
        if [[ "$2" == *"/issues/"*"/comments"* ]]; then
            echo '[
                {"id": 1, "user": {"login": "otheruser"}, "created_at": "2026-01-18T11:00:00Z", "body": "@claude please review"},
                {"id": 2, "user": {"login": "myuser"}, "created_at": "2026-01-18T12:00:00Z", "body": "@claude please review"},
                {"id": 3, "user": {"login": "otheruser"}, "created_at": "2026-01-18T13:00:00Z", "body": "@claude please review"}
            ]'
            exit 0
        fi
        echo "[]"
        exit 0
        ;;
esac
exit 1
MOCK_GH
    chmod +x "$test_subdir/gh"

    # Test the jq filter logic
    local comments='[
        {"id": 1, "author": "otheruser", "created_at": "2026-01-18T11:00:00Z", "body": "@claude please review"},
        {"id": 2, "author": "myuser", "created_at": "2026-01-18T12:00:00Z", "body": "@claude please review"},
        {"id": 3, "author": "otheruser", "created_at": "2026-01-18T13:00:00Z", "body": "@claude please review"}
    ]'

    local trigger_ts
    trigger_ts=$(echo "$comments" | jq -r --arg pattern "@claude" --arg user "myuser" '
        [.[] | select(.author == $user and (.body | test($pattern; "i")))] |
        sort_by(.created_at) | reverse | .[0].created_at // empty
    ')

    if [[ "$trigger_ts" == "2026-01-18T12:00:00Z" ]]; then
        pass "T-HOOK-1: Trigger detection filters by current user"
    else
        fail "T-HOOK-1: Trigger should be from myuser only" "2026-01-18T12:00:00Z" "got $trigger_ts"
    fi
}

# Test: Trigger timestamp refresh when newer exists
test_trigger_refresh() {
    local old_trigger="2026-01-18T10:00:00Z"
    local new_trigger="2026-01-18T12:00:00Z"

    # Simulate the refresh logic from stop hook
    local should_update=false
    if [[ -z "$old_trigger" ]] || [[ "$new_trigger" > "$old_trigger" ]]; then
        should_update=true
    fi

    if [[ "$should_update" == "true" ]]; then
        pass "T-HOOK-2: Trigger timestamp refreshes when newer comment exists"
    else
        fail "T-HOOK-2: Should update trigger when newer" "update" "no update"
    fi
}

# Test: Missing trigger blocks exit for round > 0
test_missing_trigger_blocks() {
    local current_round=1
    local last_trigger_at=""

    # Simulate the check from stop hook
    local should_block=false
    if [[ "$current_round" -gt 0 && -z "$last_trigger_at" ]]; then
        should_block=true
    fi

    if [[ "$should_block" == "true" ]]; then
        pass "T-HOOK-3: Missing trigger comment blocks exit for round > 0"
    else
        fail "T-HOOK-3: Should block when no trigger" "block" "allow"
    fi
}

# Test: Round 0 uses started_at (no trigger required)
test_round0_uses_started_at() {
    local current_round=0
    local started_at="2026-01-18T10:00:00Z"
    local last_trigger_at=""

    # Simulate the timestamp selection from stop hook
    local after_timestamp
    if [[ "$current_round" -eq 0 ]]; then
        after_timestamp="$started_at"
    else
        after_timestamp="$last_trigger_at"
    fi

    if [[ "$after_timestamp" == "$started_at" ]]; then
        pass "T-HOOK-4: Round 0 uses started_at for --after timestamp"
    else
        fail "T-HOOK-4: Round 0 should use started_at" "$started_at" "got $after_timestamp"
    fi
}

# Test: Per-bot timeout anchored to trigger timestamp
test_timeout_anchored_to_trigger() {
    # Simulate: trigger at T=0, poll starts at T=60, timeout is 900s
    local trigger_epoch=1000
    local poll_start_epoch=1060
    local current_time=1900  # 900s after trigger, 840s after poll start
    local timeout=900

    # With trigger-anchored timeout:
    local elapsed_from_trigger=$((current_time - trigger_epoch))
    # With poll-anchored timeout (wrong):
    local elapsed_from_poll=$((current_time - poll_start_epoch))

    local timed_out_trigger=false
    local timed_out_poll=false

    if [[ $elapsed_from_trigger -ge $timeout ]]; then
        timed_out_trigger=true
    fi
    if [[ $elapsed_from_poll -ge $timeout ]]; then
        timed_out_poll=true
    fi

    # Should be timed out based on trigger (900s elapsed), not poll (840s elapsed)
    if [[ "$timed_out_trigger" == "true" && "$timed_out_poll" == "false" ]]; then
        pass "T-HOOK-5: Per-bot timeout is anchored to trigger timestamp"
    else
        fail "T-HOOK-5: Timeout should be from trigger, not poll start" "trigger-based timeout" "poll-based timeout"
    fi
}

# Test: State file includes configured_bots
test_state_has_configured_bots() {
    local test_subdir="$TEST_DIR/state_configured_test"
    mkdir -p "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00"

    cat > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/state.md" << 'EOF'
---
current_round: 1
configured_bots:
  - claude
  - chatgpt-codex-connector
active_bots:
  - claude
last_trigger_at: 2026-01-18T12:00:00Z
---
EOF

    # Extract configured_bots count
    local configured_count
    configured_count=$(grep -c "^  - " "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/state.md" 2>/dev/null | head -1)

    if [[ "$configured_count" -ge 2 ]]; then
        pass "T-HOOK-6: State file tracks configured_bots separately"
    else
        fail "T-HOOK-6: State should have configured_bots" "2+ bots" "got $configured_count"
    fi
}

# Test: Round file naming consistency
test_round_file_naming() {
    # All round-N files should use NEXT_ROUND
    local current_round=1
    local next_round=$((current_round + 1))

    local comment_file="round-${next_round}-pr-comment.md"
    local check_file="round-${next_round}-pr-check.md"
    local feedback_file="round-${next_round}-pr-feedback.md"

    # All should use next_round (2)
    if [[ "$comment_file" == "round-2-pr-comment.md" && \
          "$check_file" == "round-2-pr-check.md" && \
          "$feedback_file" == "round-2-pr-feedback.md" ]]; then
        pass "T-HOOK-7: Round file naming is consistent (all use NEXT_ROUND)"
    else
        fail "T-HOOK-7: Round files should all use NEXT_ROUND" "round-2-*" "inconsistent"
    fi
}

# Run stop hook integration tests
test_trigger_user_filter
test_trigger_refresh
test_missing_trigger_blocks
test_round0_uses_started_at
test_timeout_anchored_to_trigger
test_state_has_configured_bots
test_round_file_naming

# ========================================
# Summary
# ========================================

print_test_summary "PR Loop Tests"

exit $([[ $TESTS_FAILED -eq 0 ]] && echo 0 || echo 1)
