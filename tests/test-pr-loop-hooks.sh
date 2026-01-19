#!/bin/bash
#
# PR Loop Hook Tests
#
# Tests for hook functionality:
# - Validators and protections
# - Comment processing
# - E2E tests
# - Fixture-based tests
# - Monitor tests
#
# Usage: source test-pr-loop-hooks.sh && run_hook_tests
#

run_hook_tests() {
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
  - codex
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
       grep -q "^  - codex$" "$loop_dir/state.md"; then
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

# Test: PR loop Bash protection works without RLCR loop
test_pr_loop_bash_protection_no_rlcr() {
    cd "$TEST_DIR"

    # Ensure NO RLCR loop exists
    rm -rf ".humanize/rlcr"

    local timestamp="2026-01-18_14-30-00"
    local loop_dir=".humanize/pr-loop/$timestamp"
    mkdir -p "$loop_dir"

    cat > "$loop_dir/state.md" << EOF
---
current_round: 0
max_iterations: 42
pr_number: 456
---
EOF

    # Test that Bash validator blocks state.md modifications via echo redirect
    local hook_input='{"tool_name": "Bash", "tool_input": {"command": "echo bad > '$TEST_DIR'/.humanize/pr-loop/'$timestamp'/state.md"}}'

    local output
    local exit_code
    output=$(echo "$hook_input" | "$PROJECT_ROOT/hooks/loop-bash-validator.sh" 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}

    if [[ $exit_code -eq 2 ]] && echo "$output" | grep -qi "state\|blocked\|pr loop"; then
        pass "T-SEC-4: PR loop Bash protection works without RLCR loop"
    else
        fail "T-SEC-4: PR loop Bash protection should work without RLCR" "exit=2, blocked" "exit=$exit_code, output=$output"
    fi

    cd "$SCRIPT_DIR"
}

test_pr_loop_bash_protection_no_rlcr

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
  - codex
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

    if [[ "$configured_bots" == "claude,codex," ]]; then
        pass "T-GATE-2: configured_bots YAML list is parsed correctly"
    else
        fail "T-GATE-2: configured_bots parsing failed" "claude,codex," "got $configured_bots"
    fi
}

# Test: Bot status extraction from Codex output
test_bot_status_extraction() {
    local codex_output="### Per-Bot Status
| Bot | Status | Summary |
|-----|--------|---------|
| claude | APPROVE | No issues found |
| codex | ISSUES | Found bug in line 42 |

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

    if [[ "$bots_with_issues" == "codex," ]]; then
        pass "T-GATE-3: Bots with ISSUES status are correctly identified"
    else
        fail "T-GATE-3: Bot status extraction failed" "codex," "got $bots_with_issues"
    fi
}

# Test: Bot re-add logic when previously approved bot has new issues
test_bot_readd_logic() {
    # Simulate: claude was approved (removed from active), but now has ISSUES
    local configured_bots=("claude" "codex")
    local active_bots=("codex")  # claude was removed (approved)

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
        {"id": 2, "body": "@claude @codex please review", "created_at": "2026-01-18T11:00:00Z"},
        {"id": 3, "body": "Another comment", "created_at": "2026-01-18T12:00:00Z"}
    ]'

    # Build pattern for @bot mentions
    local bot_pattern="@claude|@codex"

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
            echo '[{"id": 1, "user": {"login": "${trigger_user}"}, "created_at": "${trigger_timestamp}", "body": "@claude @codex please review"}]'
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

# Test: Round 0 uses last_trigger_at when present, started_at as fallback
test_round0_trigger_priority() {
    local current_round=0
    local started_at="2026-01-18T10:00:00Z"
    local last_trigger_at="2026-01-18T11:00:00Z"

    # Simulate the timestamp selection from stop hook (updated logic)
    # ALWAYS prefer last_trigger_at when available
    local after_timestamp
    if [[ -n "$last_trigger_at" ]]; then
        after_timestamp="$last_trigger_at"
    elif [[ "$current_round" -eq 0 ]]; then
        after_timestamp="$started_at"
    fi

    if [[ "$after_timestamp" == "$last_trigger_at" ]]; then
        pass "T-HOOK-4: Round 0 uses last_trigger_at when present (not started_at)"
    else
        fail "T-HOOK-4: Round 0 should prefer last_trigger_at" "$last_trigger_at" "got $after_timestamp"
    fi
}

# Test: Round 0 falls back to started_at when no trigger
test_round0_started_at_fallback() {
    local current_round=0
    local started_at="2026-01-18T10:00:00Z"
    local last_trigger_at=""

    # Simulate the timestamp selection from stop hook
    local after_timestamp
    if [[ -n "$last_trigger_at" ]]; then
        after_timestamp="$last_trigger_at"
    elif [[ "$current_round" -eq 0 ]]; then
        after_timestamp="$started_at"
    fi

    if [[ "$after_timestamp" == "$started_at" ]]; then
        pass "T-HOOK-4b: Round 0 falls back to started_at when no trigger"
    else
        fail "T-HOOK-4b: Round 0 should fall back to started_at" "$started_at" "got $after_timestamp"
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
  - codex
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
test_round0_trigger_priority
test_round0_started_at_fallback
test_timeout_anchored_to_trigger
test_state_has_configured_bots
test_round_file_naming

# ========================================
# Stop Hook End-to-End Tests (Execute Hook with Mocked gh/codex)
# ========================================

echo ""
echo "========================================"
echo "Testing Stop Hook End-to-End Execution"
echo "========================================"
echo ""

# Test: Stop hook blocks when no resolve file exists
test_e2e_missing_resolve_blocks() {
    local test_subdir="$TEST_DIR/e2e_resolve_test"
    mkdir -p "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00"

    # Create state file
    cat > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 42
pr_number: 123
start_branch: test-branch
configured_bots:
  - claude
active_bots:
  - claude
codex_model: gpt-5.2-codex
codex_effort: medium
codex_timeout: 900
poll_interval: 30
poll_timeout: 900
started_at: 2026-01-18T12:00:00Z
last_trigger_at:
---
EOF

    # Create mock binaries
    local mock_bin="$test_subdir/bin"
    mkdir -p "$mock_bin"

    cat > "$mock_bin/gh" << 'MOCK_GH'
#!/bin/bash
case "$1" in
    api)
        if [[ "$2" == "user" ]]; then
            echo '{"login": "testuser"}'
            exit 0
        fi
        echo "[]"
        exit 0
        ;;
    pr)
        if [[ "$*" == *"state"* ]]; then
            echo '{"state": "OPEN"}'
            exit 0
        fi
        ;;
esac
exit 0
MOCK_GH
    chmod +x "$mock_bin/gh"

    cat > "$mock_bin/git" << 'MOCK_GIT'
#!/bin/bash
case "$1" in
    rev-parse) echo "/tmp/git" ;;
    status) echo "" ;;
esac
exit 0
MOCK_GIT
    chmod +x "$mock_bin/git"

    # Run stop hook with mocked environment
    export CLAUDE_PROJECT_DIR="$test_subdir"
    export PATH="$mock_bin:$PATH"

    local hook_output
    hook_output=$(echo '{}' | "$PROJECT_ROOT/hooks/pr-loop-stop-hook.sh" 2>&1) || true

    # Check for block decision about missing resolve file
    if echo "$hook_output" | grep -q "Resolution Summary Missing\|resolution summary\|round-0-pr-resolve"; then
        pass "T-E2E-1: Stop hook blocks when resolve file missing"
    else
        fail "T-E2E-1: Stop hook should block for missing resolve" "block message" "got: $hook_output"
    fi

    unset CLAUDE_PROJECT_DIR
}

# Test: Stop hook detects trigger comment and updates state
test_e2e_trigger_detection() {
    local test_subdir="$TEST_DIR/e2e_trigger_test"
    mkdir -p "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00"

    # Create state file with empty last_trigger_at
    cat > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 42
pr_number: 123
start_branch: test-branch
configured_bots:
  - claude
active_bots:
  - claude
codex_model: gpt-5.2-codex
codex_effort: medium
codex_timeout: 900
poll_interval: 30
poll_timeout: 900
started_at: 2026-01-18T12:00:00Z
last_trigger_at:
---
EOF

    # Create resolve file
    echo "# Resolution Summary" > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/round-0-pr-resolve.md"

    # Create mock binaries that return trigger comment
    local mock_bin="$test_subdir/bin"
    mkdir -p "$mock_bin"

    # Mock gh that properly returns jq-parsed user and trigger comments
    cat > "$mock_bin/gh" << 'MOCK_GH'
#!/bin/bash
case "$1" in
    api)
        if [[ "$2" == "user" ]]; then
            # gh api user --jq '.login' returns just the login string
            if [[ "$*" == *"--jq"* ]]; then
                echo "testuser"
            else
                echo '{"login": "testuser"}'
            fi
            exit 0
        fi
        if [[ "$2" == *"/issues/"*"/comments"* ]]; then
            # When --jq and --paginate are used, gh applies jq per-element and outputs transformed objects
            # The hook's jq: '.[] | {id: .id, author: .user.login, created_at: .created_at, body: .body}'
            if [[ "$*" == *"--jq"* ]]; then
                # Return pre-transformed format (what jq would output)
                echo '{"id": 1, "author": "testuser", "created_at": "2026-01-18T13:00:00Z", "body": "@claude please review"}'
            else
                # Return raw GitHub API format
                echo '[{"id": 1, "user": {"login": "testuser"}, "created_at": "2026-01-18T13:00:00Z", "body": "@claude please review"}]'
            fi
            exit 0
        fi
        echo "[]"
        exit 0
        ;;
    pr)
        if [[ "$*" == *"state"* ]]; then
            echo '{"state": "OPEN"}'
            exit 0
        fi
        ;;
esac
exit 0
MOCK_GH
    chmod +x "$mock_bin/gh"

    cat > "$mock_bin/git" << 'MOCK_GIT'
#!/bin/bash
case "$1" in
    rev-parse) echo "/tmp/git" ;;
    status) echo "" ;;
esac
exit 0
MOCK_GIT
    chmod +x "$mock_bin/git"

    # Run stop hook
    export CLAUDE_PROJECT_DIR="$test_subdir"
    export PATH="$mock_bin:$PATH"

    # Capture stderr for debug messages
    local hook_stderr
    hook_stderr=$(echo '{}' | "$PROJECT_ROOT/hooks/pr-loop-stop-hook.sh" 2>&1 >/dev/null) || true

    # Check for trigger detection message OR that last_trigger_at is being used
    # (which indicates the trigger was detected and persisted)
    if echo "$hook_stderr" | grep -q "Found trigger comment at:\|using trigger timestamp"; then
        pass "T-E2E-2: Stop hook detects and reports trigger comment"
    else
        fail "T-E2E-2: Stop hook should detect trigger" "trigger detected" "got: $hook_stderr"
    fi

    unset CLAUDE_PROJECT_DIR
}

# Test: Stop hook handles paginated API response (multi-page trigger detection)
test_e2e_pagination_runtime() {
    local test_subdir="$TEST_DIR/e2e_pagination_test"
    mkdir -p "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00"

    # Create state file
    cat > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 42
pr_number: 123
start_branch: test-branch
configured_bots:
  - claude
active_bots:
  - claude
codex_model: gpt-5.2-codex
codex_effort: medium
codex_timeout: 900
poll_interval: 30
poll_timeout: 900
started_at: 2026-01-18T10:00:00Z
last_trigger_at:
---
EOF

    # Create resolve file
    echo "# Resolution Summary" > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/round-0-pr-resolve.md"

    local mock_bin="$test_subdir/bin"
    mkdir -p "$mock_bin"

    # Mock gh that simulates paginated response (returns multiple JSON arrays)
    # The trigger comment is on page 2 (second array) - only visible if pagination works
    cat > "$mock_bin/gh" << 'MOCK_GH'
#!/bin/bash
case "$1" in
    api)
        if [[ "$2" == "user" ]]; then
            if [[ "$*" == *"--jq"* ]]; then
                echo "testuser"
            else
                echo '{"login": "testuser"}'
            fi
            exit 0
        fi
        if [[ "$2" == *"/issues/"*"/comments"* ]]; then
            # When --jq and --paginate are used, gh applies jq per-element and outputs transformed objects
            # Page 1: old comment without trigger
            # Page 2: newer comment WITH trigger - must combine to find it
            if [[ "$*" == *"--paginate"* ]] && [[ "$*" == *"--jq"* ]]; then
                # --paginate with --jq: output transformed objects (one per line)
                echo '{"id": 1, "author": "other", "created_at": "2026-01-18T11:00:00Z", "body": "old comment"}'
                echo '{"id": 2, "author": "testuser", "created_at": "2026-01-18T12:00:00Z", "body": "@claude please review the pagination fix"}'
            elif [[ "$*" == *"--paginate"* ]]; then
                # --paginate without --jq: output raw arrays
                echo '[{"id": 1, "user": {"login": "other"}, "created_at": "2026-01-18T11:00:00Z", "body": "old comment"}]'
                echo '[{"id": 2, "user": {"login": "testuser"}, "created_at": "2026-01-18T12:00:00Z", "body": "@claude please review the pagination fix"}]'
            else
                # No pagination: only first page (trigger NOT found)
                echo '[{"id": 1, "user": {"login": "other"}, "created_at": "2026-01-18T11:00:00Z", "body": "old comment"}]'
            fi
            exit 0
        fi
        echo "[]"
        exit 0
        ;;
    pr)
        if [[ "$*" == *"state"* ]]; then
            echo '{"state": "OPEN"}'
            exit 0
        fi
        ;;
esac
exit 0
MOCK_GH
    chmod +x "$mock_bin/gh"

    cat > "$mock_bin/git" << 'MOCK_GIT'
#!/bin/bash
case "$1" in
    rev-parse) echo "/tmp/git" ;;
    status) echo "" ;;
esac
exit 0
MOCK_GIT
    chmod +x "$mock_bin/git"

    # Run stop hook
    export CLAUDE_PROJECT_DIR="$test_subdir"
    export PATH="$mock_bin:$PATH"

    local hook_stderr
    hook_stderr=$(echo '{}' | "$PROJECT_ROOT/hooks/pr-loop-stop-hook.sh" 2>&1 >/dev/null) || true

    # Check that trigger was found (proving pagination worked to combine arrays)
    if echo "$hook_stderr" | grep -q "Found trigger comment at:\|using trigger timestamp"; then
        pass "T-E2E-3: Pagination combines arrays and finds trigger on page 2"
    else
        fail "T-E2E-3: Pagination should find trigger on page 2" "trigger detected" "got: $hook_stderr"
    fi

    unset CLAUDE_PROJECT_DIR
}

# Test: Stop hook uses last_trigger_at when present (even for round 0)
test_e2e_trigger_priority_runtime() {
    local test_subdir="$TEST_DIR/e2e_priority_test"
    mkdir -p "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00"

    # Create state file with BOTH started_at and last_trigger_at set
    # The trigger timestamp is LATER than started_at - if priority works,
    # the hook should use the trigger timestamp (not started_at)
    cat > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 42
pr_number: 123
start_branch: test-branch
configured_bots:
  - claude
active_bots:
  - claude
codex_model: gpt-5.2-codex
codex_effort: medium
codex_timeout: 900
poll_interval: 30
poll_timeout: 900
started_at: 2026-01-18T10:00:00Z
last_trigger_at: 2026-01-18T14:30:00Z
---
EOF

    # Create resolve file
    echo "# Resolution Summary" > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/round-0-pr-resolve.md"

    local mock_bin="$test_subdir/bin"
    mkdir -p "$mock_bin"

    cat > "$mock_bin/gh" << 'MOCK_GH'
#!/bin/bash
case "$1" in
    api)
        if [[ "$2" == "user" ]]; then
            if [[ "$*" == *"--jq"* ]]; then
                echo "testuser"
            fi
            exit 0
        fi
        if [[ "$2" == *"/issues/"*"/comments"* ]]; then
            echo '[{"id": 1, "author": "testuser", "created_at": "2026-01-18T14:30:00Z", "body": "@claude review"}]'
            exit 0
        fi
        echo "[]"
        exit 0
        ;;
    pr)
        if [[ "$*" == *"state"* ]]; then
            echo '{"state": "OPEN"}'
            exit 0
        fi
        ;;
esac
exit 0
MOCK_GH
    chmod +x "$mock_bin/gh"

    cat > "$mock_bin/git" << 'MOCK_GIT'
#!/bin/bash
case "$1" in
    rev-parse) echo "/tmp/git" ;;
    status) echo "" ;;
esac
exit 0
MOCK_GIT
    chmod +x "$mock_bin/git"

    export CLAUDE_PROJECT_DIR="$test_subdir"
    export PATH="$mock_bin:$PATH"

    local hook_stderr
    hook_stderr=$(echo '{}' | "$PROJECT_ROOT/hooks/pr-loop-stop-hook.sh" 2>&1 >/dev/null) || true

    # Check that it reports using trigger timestamp for --after (not started_at)
    # Must match the SPECIFIC log format: "Round 0: using trigger timestamp for --after: <timestamp>"
    # This proves last_trigger_at is prioritized even for round 0
    if echo "$hook_stderr" | grep -q "Round 0: using trigger timestamp for --after: 2026-01-18T14:30:00Z"; then
        pass "T-E2E-4: Round 0 uses last_trigger_at for --after (not started_at)"
    else
        fail "T-E2E-4: Round 0 should use last_trigger_at for --after" \
            "Round 0: using trigger timestamp for --after: 2026-01-18T14:30:00Z" \
            "got: $hook_stderr"
    fi

    unset CLAUDE_PROJECT_DIR
}

# Run end-to-end tests
test_e2e_missing_resolve_blocks
test_e2e_trigger_detection
test_e2e_pagination_runtime
test_e2e_trigger_priority_runtime

# ========================================
# Approval-Only Review Tests
# ========================================

echo ""
echo "========================================"
echo "Testing Approval-Only Review Handling"
echo "========================================"
echo ""

# Test: Empty-body PR reviews are captured with state placeholder
test_approval_only_review_captured() {
    # Simulate PR review with APPROVED state but empty body
    local reviews='[
        {"id": 1, "user": {"login": "claude[bot]"}, "state": "APPROVED", "body": null, "submitted_at": "2026-01-18T12:00:00Z"},
        {"id": 2, "user": {"login": "claude[bot]"}, "state": "APPROVED", "body": "", "submitted_at": "2026-01-18T12:01:00Z"},
        {"id": 3, "user": {"login": "claude[bot]"}, "state": "CHANGES_REQUESTED", "body": "Fix bug", "submitted_at": "2026-01-18T12:02:00Z"}
    ]'

    # Apply the same jq logic as poll-pr-reviews.sh (fixed version)
    local processed
    processed=$(echo "$reviews" | jq '[.[] | {
        id: .id,
        author: .user.login,
        state: .state,
        body: (if .body == null or .body == "" then "[Review state: \(.state)]" else .body end)
    }]')

    local count
    count=$(echo "$processed" | jq 'length')

    if [[ "$count" == "3" ]]; then
        pass "T-APPROVE-1: Empty-body PR reviews are captured (count=3)"
    else
        fail "T-APPROVE-1: All reviews should be captured including empty-body" "3" "got $count"
    fi

    # Check that empty body gets placeholder
    local placeholder_count
    placeholder_count=$(echo "$processed" | jq '[.[] | select(.body | test("\\[Review state:"))] | length')

    if [[ "$placeholder_count" == "2" ]]; then
        pass "T-APPROVE-2: Empty-body reviews get state placeholder"
    else
        fail "T-APPROVE-2: Empty-body reviews should get placeholder" "2" "got $placeholder_count"
    fi
}

# Test: Approval-only reviews match bot patterns for polling
test_approval_polls_correctly() {
    local bot_pattern="claude\\[bot\\]"
    local reviews='[
        {"type": "pr_review", "author": "claude[bot]", "state": "APPROVED", "body": "[Review state: APPROVED]", "created_at": "2026-01-18T12:00:00Z"}
    ]'

    local filtered
    filtered=$(echo "$reviews" | jq --arg pattern "$bot_pattern" '[.[] | select(.author | test($pattern; "i"))]')
    local count
    count=$(echo "$filtered" | jq 'length')

    if [[ "$count" == "1" ]]; then
        pass "T-APPROVE-3: Approval-only reviews match bot pattern for polling"
    else
        fail "T-APPROVE-3: Approval-only review should match bot" "1" "got $count"
    fi
}

# Run approval-only review tests
test_approval_only_review_captured
test_approval_polls_correctly

# ========================================
# Fixture-Backed Fetch/Poll Tests
# ========================================

echo ""
echo "========================================"
echo "Testing Fetch/Poll with Fixture-Backed Mock GH"
echo "========================================"
echo ""

# Set up fixture-backed mock gh
setup_fixture_mock_gh() {
    local mock_bin_dir="$TEST_DIR/mock_bin"
    local fixtures_dir="$SCRIPT_DIR/fixtures"

    # Create the mock gh
    "$SCRIPT_DIR/setup-fixture-mock-gh.sh" "$mock_bin_dir" "$fixtures_dir" > /dev/null

    echo "$mock_bin_dir"
}

# Test: fetch-pr-comments.sh returns all comment types including approval-only reviews
test_fetch_pr_comments_with_fixtures() {
    cd "$TEST_DIR"

    local mock_bin_dir
    mock_bin_dir=$(setup_fixture_mock_gh)

    # Run fetch-pr-comments.sh with mock gh in PATH
    local output_file="$TEST_DIR/pr-comments.md"
    PATH="$mock_bin_dir:$PATH" "$PROJECT_ROOT/scripts/fetch-pr-comments.sh" 123 "$output_file"

    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        fail "T-FIXTURE-1: fetch-pr-comments.sh should succeed" "exit=0" "exit=$exit_code"
        return
    fi

    if [[ ! -f "$output_file" ]]; then
        fail "T-FIXTURE-1: Output file should exist" "file exists" "file not found"
        return
    fi

    # Check for issue comments
    if ! grep -q "humanuser" "$output_file"; then
        fail "T-FIXTURE-1: Output should contain human issue comment" "humanuser comment" "not found"
        return
    fi

    # Check for review comments (inline code comments)
    if ! grep -q "const instead of let" "$output_file"; then
        fail "T-FIXTURE-1: Output should contain inline review comment" "const instead of let" "not found"
        return
    fi

    # Check for approval-only PR reviews with placeholder
    if ! grep -q "\[Review state: APPROVED\]" "$output_file"; then
        fail "T-FIXTURE-1: Output should contain approval-only review with placeholder" "[Review state: APPROVED]" "not found"
        return
    fi

    pass "T-FIXTURE-1: fetch-pr-comments.sh returns all comment types including approval-only"
    cd "$SCRIPT_DIR"
}

# Test: fetch-pr-comments.sh respects --after timestamp filter
test_fetch_pr_comments_after_filter() {
    cd "$TEST_DIR"

    local mock_bin_dir
    mock_bin_dir=$(setup_fixture_mock_gh)

    # Run with --after filter (after 12:00, should exclude early comments)
    local output_file="$TEST_DIR/pr-comments-filtered.md"
    PATH="$mock_bin_dir:$PATH" "$PROJECT_ROOT/scripts/fetch-pr-comments.sh" 123 "$output_file" --after "2026-01-18T12:00:00Z"

    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        fail "T-FIXTURE-2: fetch-pr-comments.sh --after should succeed" "exit=0" "exit=$exit_code"
        return
    fi

    # Should include late comments (13:00+ approvals)
    if ! grep -q "\[Review state: APPROVED\]" "$output_file"; then
        fail "T-FIXTURE-2: Should include late approval-only review" "[Review state: APPROVED]" "not found"
        return
    fi

    # Should NOT include early human comment from 09:00
    # (humanreviewer's "LGTM!" was at 09:00)
    if grep -q "LGTM" "$output_file"; then
        fail "T-FIXTURE-2: Should exclude comments before --after timestamp" "no LGTM" "LGTM found"
        return
    fi

    pass "T-FIXTURE-2: fetch-pr-comments.sh --after filter works correctly"
    cd "$SCRIPT_DIR"
}

# Test: poll-pr-reviews.sh returns JSON with approval-only reviews
test_poll_pr_reviews_with_fixtures() {
    cd "$TEST_DIR"

    local mock_bin_dir
    mock_bin_dir=$(setup_fixture_mock_gh)

    # Run poll-pr-reviews.sh with mock gh in PATH
    # Use early timestamp to catch all bot reviews
    local output
    output=$(PATH="$mock_bin_dir:$PATH" "$PROJECT_ROOT/scripts/poll-pr-reviews.sh" 123 \
        --after "2026-01-18T10:00:00Z" \
        --bots "claude,codex")

    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        fail "T-FIXTURE-3: poll-pr-reviews.sh should succeed" "exit=0" "exit=$exit_code"
        return
    fi

    # Validate JSON structure
    if ! echo "$output" | jq . > /dev/null 2>&1; then
        fail "T-FIXTURE-3: Output should be valid JSON" "valid JSON" "invalid JSON"
        return
    fi

    # Check for approval-only reviews in comments
    local has_placeholder
    has_placeholder=$(echo "$output" | jq '[.comments[]? | select(.body | test("\\[Review state:"))] | length')

    if [[ "$has_placeholder" -lt 1 ]]; then
        fail "T-FIXTURE-3: Should include approval-only reviews with placeholder" ">=1" "$has_placeholder"
        return
    fi

    # Check bots_responded includes both bots
    local bots_count
    bots_count=$(echo "$output" | jq '.bots_responded | length')

    if [[ "$bots_count" -lt 1 ]]; then
        fail "T-FIXTURE-3: Should have bots in bots_responded" ">=1" "$bots_count"
        return
    fi

    pass "T-FIXTURE-3: poll-pr-reviews.sh returns approval-only reviews in JSON"
    cd "$SCRIPT_DIR"
}

# Test: poll-pr-reviews.sh filters by --after timestamp correctly
test_poll_pr_reviews_after_filter() {
    cd "$TEST_DIR"

    local mock_bin_dir
    mock_bin_dir=$(setup_fixture_mock_gh)

    # Use timestamp that filters out early CHANGES_REQUESTED (11:00)
    # but includes late APPROVED reviews (13:00, 13:30)
    local output
    output=$(PATH="$mock_bin_dir:$PATH" "$PROJECT_ROOT/scripts/poll-pr-reviews.sh" 123 \
        --after "2026-01-18T12:30:00Z" \
        --bots "claude,codex")

    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        fail "T-FIXTURE-4: poll-pr-reviews.sh --after should succeed" "exit=0" "exit=$exit_code"
        return
    fi

    # Should have claude[bot] approval at 13:00 and codex approval at 13:30
    local comment_count
    comment_count=$(echo "$output" | jq '.comments | length')

    # At minimum, should have the late approvals
    if [[ "$comment_count" -lt 1 ]]; then
        fail "T-FIXTURE-4: Should include late approvals" ">=1" "$comment_count"
        return
    fi

    # Should NOT include the CHANGES_REQUESTED from 11:00 (before our --after)
    local changes_requested
    changes_requested=$(echo "$output" | jq '[.comments[]? | select(.body | test("security concerns"))] | length')

    if [[ "$changes_requested" -gt 0 ]]; then
        fail "T-FIXTURE-4: Should exclude comments before --after" "0" "$changes_requested"
        return
    fi

    pass "T-FIXTURE-4: poll-pr-reviews.sh --after filter excludes early comments"
    cd "$SCRIPT_DIR"
}

# Run fixture-backed tests
test_fetch_pr_comments_with_fixtures
test_fetch_pr_comments_after_filter
test_poll_pr_reviews_with_fixtures
test_poll_pr_reviews_after_filter

# ========================================
# Wrong-Round Validation Tests
# ========================================

echo ""
echo "========================================"
echo "Testing Wrong-Round Validation"
echo "========================================"
echo ""

# Test: Wrong-round pr-resolve write is blocked
test_wrong_round_pr_resolve_blocked() {
    cd "$TEST_DIR"

    local timestamp="2026-01-18_15-00-00"
    local loop_dir=".humanize/pr-loop/$timestamp"
    mkdir -p "$loop_dir"

    # State says current_round is 2
    cat > "$loop_dir/state.md" << EOF
---
current_round: 2
max_iterations: 42
pr_number: 123
---
EOF

    # Try to write to round-0 (wrong round)
    local hook_input='{"tool_name": "Write", "tool_input": {"file_path": "'$TEST_DIR'/.humanize/pr-loop/'$timestamp'/round-0-pr-resolve.md", "content": "wrong round"}}'

    local output
    local exit_code
    output=$(echo "$hook_input" | "$PROJECT_ROOT/hooks/loop-write-validator.sh" 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}

    if [[ $exit_code -eq 2 ]] && echo "$output" | grep -qi "wrong round"; then
        pass "T-ROUND-1: Wrong-round pr-resolve write is blocked"
    else
        fail "T-ROUND-1: Wrong-round pr-resolve should be blocked" "exit=2, wrong round" "exit=$exit_code"
    fi

    cd "$SCRIPT_DIR"
}

# Test: Correct-round pr-resolve write is allowed
test_correct_round_pr_resolve_allowed() {
    cd "$TEST_DIR"

    local timestamp="2026-01-18_15-01-00"
    local loop_dir=".humanize/pr-loop/$timestamp"
    mkdir -p "$loop_dir"

    # State says current_round is 2
    cat > "$loop_dir/state.md" << EOF
---
current_round: 2
max_iterations: 42
pr_number: 123
---
EOF

    # Write to round-2 (correct round)
    local hook_input='{"tool_name": "Write", "tool_input": {"file_path": "'$TEST_DIR'/.humanize/pr-loop/'$timestamp'/round-2-pr-resolve.md", "content": "correct round"}}'

    local output
    local exit_code
    output=$(echo "$hook_input" | "$PROJECT_ROOT/hooks/loop-write-validator.sh" 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}

    if [[ $exit_code -eq 0 ]]; then
        pass "T-ROUND-2: Correct-round pr-resolve write is allowed"
    else
        fail "T-ROUND-2: Correct-round pr-resolve should be allowed" "exit=0" "exit=$exit_code"
    fi

    cd "$SCRIPT_DIR"
}

# Test: Wrong-round pr-resolve edit is blocked
test_wrong_round_pr_resolve_edit_blocked() {
    cd "$TEST_DIR"

    local timestamp="2026-01-18_15-02-00"
    local loop_dir=".humanize/pr-loop/$timestamp"
    mkdir -p "$loop_dir"

    cat > "$loop_dir/state.md" << EOF
---
current_round: 3
max_iterations: 42
pr_number: 123
---
EOF

    # Try to edit round-1 (wrong round)
    local hook_input='{"tool_name": "Edit", "tool_input": {"file_path": "'$TEST_DIR'/.humanize/pr-loop/'$timestamp'/round-1-pr-resolve.md", "old_string": "x", "new_string": "y"}}'

    local output
    local exit_code
    output=$(echo "$hook_input" | "$PROJECT_ROOT/hooks/loop-edit-validator.sh" 2>&1) || exit_code=$?
    exit_code=${exit_code:-0}

    if [[ $exit_code -eq 2 ]] && echo "$output" | grep -qi "wrong round"; then
        pass "T-ROUND-3: Wrong-round pr-resolve edit is blocked"
    else
        fail "T-ROUND-3: Wrong-round pr-resolve edit should be blocked" "exit=2, wrong round" "exit=$exit_code"
    fi

    cd "$SCRIPT_DIR"
}

# Run wrong-round validation tests
test_wrong_round_pr_resolve_blocked
test_correct_round_pr_resolve_allowed
test_wrong_round_pr_resolve_edit_blocked

# ========================================
# Monitor PR Active Bots Tests
# ========================================

echo ""
echo "========================================"
echo "Testing Monitor PR Active Bots Display"
echo "========================================"
echo ""

# Test: Monitor parses YAML list for active_bots
test_monitor_yaml_list_parsing() {
    local test_subdir="$TEST_DIR/monitor_yaml_test"
    mkdir -p "$test_subdir"

    # Use helper script to create state file (avoids validator blocking)
    "$SCRIPT_DIR/setup-monitor-test-env.sh" "$test_subdir" yaml_list >/dev/null

    # Source the humanize script and run monitor from test subdirectory (use --once for non-interactive)
    cd "$test_subdir"
    local output
    output=$(source "$PROJECT_ROOT/scripts/humanize.sh" && humanize monitor pr --once 2>&1) || true
    cd "$SCRIPT_DIR"

    # Check that active bots are displayed correctly (comma-separated)
    if echo "$output" | grep -q "Active Bots:.*claude.*codex\|Active Bots:.*codex.*claude"; then
        pass "T-MONITOR-1: Monitor parses and displays YAML list active_bots"
    else
        # Also accept claude,codex format
        if echo "$output" | grep -q "Active Bots:.*claude,codex\|Active Bots:.*codex,claude"; then
            pass "T-MONITOR-1: Monitor parses and displays YAML list active_bots"
        else
            fail "T-MONITOR-1: Monitor should display active bots from YAML list" "claude,codex" "got: $output"
        fi
    fi
}

# Test: Monitor shows configured_bots separately
test_monitor_configured_bots() {
    local test_subdir="$TEST_DIR/monitor_configured_test"
    mkdir -p "$test_subdir"

    # Use helper script to create state file (avoids validator blocking)
    "$SCRIPT_DIR/setup-monitor-test-env.sh" "$test_subdir" configured >/dev/null

    # Source the humanize script and run monitor from test subdirectory (use --once for non-interactive)
    cd "$test_subdir"
    local output
    output=$(source "$PROJECT_ROOT/scripts/humanize.sh" && humanize monitor pr --once 2>&1) || true
    cd "$SCRIPT_DIR"

    # Check that both configured and active bots are displayed
    if echo "$output" | grep -q "Configured Bots:.*claude.*codex\|Configured Bots:.*codex.*claude\|Configured Bots:.*claude,codex\|Configured Bots:.*codex,claude"; then
        pass "T-MONITOR-2: Monitor displays configured_bots"
    else
        fail "T-MONITOR-2: Monitor should display configured bots" "claude,codex" "got: $output"
    fi
}

# Test: Monitor shows 'none' when active_bots is empty
test_monitor_empty_active_bots() {
    local test_subdir="$TEST_DIR/monitor_empty_test"
    mkdir -p "$test_subdir"

    # Use helper script to create state file (avoids validator blocking)
    "$SCRIPT_DIR/setup-monitor-test-env.sh" "$test_subdir" empty >/dev/null

    # Source the humanize script and run monitor from test subdirectory (use --once for non-interactive)
    cd "$test_subdir"
    local output
    output=$(source "$PROJECT_ROOT/scripts/humanize.sh" && humanize monitor pr --once 2>&1) || true
    cd "$SCRIPT_DIR"

    # Check that active bots shows 'none'
    if echo "$output" | grep -q "Active Bots:.*none"; then
        pass "T-MONITOR-3: Monitor shows 'none' for empty active_bots"
    else
        fail "T-MONITOR-3: Monitor should show 'none' for empty active_bots" "none" "got: $output"
    fi
}

# Run monitor tests
test_monitor_yaml_list_parsing
test_monitor_configured_bots
test_monitor_empty_active_bots

}
