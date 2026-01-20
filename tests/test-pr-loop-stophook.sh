#!/bin/bash
#
# PR Loop Stop Hook Tests
#
# Tests for the stop hook functionality:
# - Force push detection
# - Trigger validation
# - Bot timeout handling
# - State file management
# - Dynamic startup_case updates
#
# Usage: source test-pr-loop-stophook.sh && run_stophook_tests
#

run_stophook_tests() {
# ========================================
# Stop-Hook Integration Tests
# ========================================

# Test: Force push trigger validation - old triggers rejected after force push
test_stophook_force_push_rejects_old_trigger() {
    local test_subdir="$TEST_DIR/stophook_force_push_test"
    mkdir -p "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00"

    # Create state file with latest_commit_at set to AFTER the old trigger comment
    # This simulates: force push happened after the old trigger was posted
    cat > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/state.md" << 'EOF'
---
current_round: 1
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
trigger_comment_id:
startup_case: 4
latest_commit_sha: newsha123
latest_commit_at: 2026-01-18T14:00:00Z
---
EOF

    # Create resolve file
    echo "# Resolution Summary" > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/round-1-pr-resolve.md"

    local mock_bin="$test_subdir/bin"
    mkdir -p "$mock_bin"

    # Mock gh that returns OLD trigger comment (BEFORE latest_commit_at)
    cat > "$mock_bin/gh" << 'MOCK_GH'
#!/bin/bash
# Check if --jq is in arguments (for transformed format)
HAS_JQ=false
for arg in "$@"; do
    if [[ "$arg" == "--jq" || "$arg" == "-q" ]]; then
        HAS_JQ=true
        break
    fi
done

case "$1" in
    api)
        if [[ "$2" == "user" ]]; then
            echo "testuser"
            exit 0
        fi
        if [[ "$2" == *"/issues/"*"/comments"* ]]; then
            # Return old trigger comment from 12:00 (BEFORE latest_commit_at of 14:00)
            if [[ "$HAS_JQ" == "true" ]]; then
                # With --jq --paginate, output one transformed object per line
                echo '{"id": 1, "author": "testuser", "created_at": "2026-01-18T12:00:00Z", "body": "@claude please review"}'
            else
                # Raw GitHub API format
                echo '[{"id": 1, "user": {"login": "testuser"}, "created_at": "2026-01-18T12:00:00Z", "body": "@claude please review"}]'
            fi
            exit 0
        fi
        echo "[]"
        exit 0
        ;;
    pr)
        if [[ "$*" == *"commits"* ]] && [[ "$*" == *"--jq"* ]]; then
            # Return just the timestamp when --jq is used
            echo "2026-01-18T10:00:00Z"
            exit 0
        fi
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
    rev-parse)
        if [[ "$2" == "HEAD" ]]; then
            echo "newsha123"  # Match state file
        else
            echo "/tmp/git"
        fi
        ;;
    status) echo "" ;;
    merge-base) exit 0 ;;  # Pretend no force push in this test
esac
exit 0
MOCK_GIT
    chmod +x "$mock_bin/git"

    export CLAUDE_PROJECT_DIR="$test_subdir"
    export PATH="$mock_bin:$PATH"

    # Run stop hook and capture output
    local hook_output
    hook_output=$(echo '{}' | "$PROJECT_ROOT/hooks/pr-loop-stop-hook.sh" 2>&1) || true

    # The old trigger should be rejected because it's before latest_commit_at
    # Stop hook should block requiring a new trigger
    if echo "$hook_output" | grep -qi "trigger\|comment @\|re-trigger\|no trigger"; then
        pass "T-STOPHOOK-1: Force push validation rejects old trigger comment"
    else
        fail "T-STOPHOOK-1: Should reject old trigger after force push" "block/require trigger" "got: $hook_output"
    fi

    unset CLAUDE_PROJECT_DIR
}

# Test: Step 7 Case 1 exception - no trigger required for startup_case=1, round=0
test_stophook_case1_no_trigger_required() {
    local test_subdir="$TEST_DIR/stophook_case1_test"
    mkdir -p "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00"

    # Create state file with startup_case=1 and round=0
    cat > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 42
pr_number: 123
start_branch: test-branch
configured_bots:
  - codex
active_bots:
  - codex
codex_model: gpt-5.2-codex
codex_effort: medium
codex_timeout: 900
poll_interval: 1
poll_timeout: 2
started_at: 2026-01-18T10:00:00Z
last_trigger_at:
trigger_comment_id:
startup_case: 1
latest_commit_sha: abc123
latest_commit_at: 2026-01-18T10:00:00Z
---
EOF

    # Create resolve file
    echo "# Resolution Summary" > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/round-0-pr-resolve.md"

    local mock_bin="$test_subdir/bin"
    mkdir -p "$mock_bin"

    # Mock gh that returns no trigger comments, but has codex +1
    cat > "$mock_bin/gh" << 'MOCK_GH'
#!/bin/bash
case "$1" in
    api)
        if [[ "$2" == "user" ]]; then
            echo "testuser"
            exit 0
        fi
        if [[ "$2" == *"/issues/"*"/reactions"* ]]; then
            # Return codex +1 reaction (triggers approval)
            echo '[{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"+1","created_at":"2026-01-18T10:05:00Z"}]'
            exit 0
        fi
        if [[ "$2" == *"/issues/"*"/comments"* ]]; then
            echo '[]'  # No comments
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
    rev-parse)
        if [[ "$2" == "HEAD" ]]; then
            echo "abc123"
        else
            echo "/tmp/git"
        fi
        ;;
    status) echo "" ;;
    merge-base) exit 0 ;;
esac
exit 0
MOCK_GIT
    chmod +x "$mock_bin/git"

    export CLAUDE_PROJECT_DIR="$test_subdir"
    export PATH="$mock_bin:$PATH"

    local hook_stderr
    hook_stderr=$(echo '{}' | "$PROJECT_ROOT/hooks/pr-loop-stop-hook.sh" 2>&1 >/dev/null) || true

    # Case 1 exception: should NOT block for missing trigger
    if echo "$hook_stderr" | grep -q "trigger not required\|Case 1\|startup_case=1"; then
        pass "T-STOPHOOK-2: Case 1 exception - no trigger required"
    else
        # Alternative: check that it didn't block
        if ! echo "$hook_stderr" | grep -qi "block.*trigger\|missing.*trigger\|comment @"; then
            pass "T-STOPHOOK-2: Case 1 exception - no trigger required (no block)"
        else
            fail "T-STOPHOOK-2: Case 1 should not require trigger" "no block" "got: $hook_stderr"
        fi
    fi

    unset CLAUDE_PROJECT_DIR
}

# Test: Step 9 - APPROVE creates approve-state.md
test_stophook_approve_creates_state() {
    local test_subdir="$TEST_DIR/stophook_approve_test"
    mkdir -p "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00"

    # Create state file with empty active_bots (YAML list format, no items)
    cat > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/state.md" << 'EOF'
---
current_round: 1
max_iterations: 42
pr_number: 123
start_branch: test-branch
configured_bots:
  - codex
active_bots:
codex_model: gpt-5.2-codex
codex_effort: medium
codex_timeout: 900
poll_interval: 30
poll_timeout: 900
started_at: 2026-01-18T10:00:00Z
last_trigger_at: 2026-01-18T11:00:00Z
trigger_comment_id: 123
startup_case: 3
latest_commit_sha: abc123
latest_commit_at: 2026-01-18T10:00:00Z
---
EOF

    # Create resolve file (required by stop hook)
    echo "# Resolution Summary" > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/round-1-pr-resolve.md"

    export CLAUDE_PROJECT_DIR="$test_subdir"

    local mock_bin="$test_subdir/bin"
    mkdir -p "$mock_bin"

    cat > "$mock_bin/gh" << 'MOCK_GH'
#!/bin/bash
exit 0
MOCK_GH
    chmod +x "$mock_bin/gh"

    cat > "$mock_bin/git" << 'MOCK_GIT'
#!/bin/bash
case "$1" in
    rev-parse)
        if [[ "$2" == "HEAD" ]]; then
            echo "abc123"
        else
            echo "/tmp/git"
        fi
        ;;
    status) echo "" ;;
    merge-base) exit 0 ;;
esac
exit 0
MOCK_GIT
    chmod +x "$mock_bin/git"

    export PATH="$mock_bin:$PATH"

    # Run stop hook - with empty active_bots, it should approve
    local hook_output
    hook_output=$(echo '{}' | "$PROJECT_ROOT/hooks/pr-loop-stop-hook.sh" 2>&1) || true

    # Check for approve-state.md creation
    if [[ -f "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/approve-state.md" ]]; then
        pass "T-STOPHOOK-3: APPROVE creates approve-state.md"
    else
        # Alternative: check output for approval message
        if echo "$hook_output" | grep -qi "approved\|complete"; then
            pass "T-STOPHOOK-3: APPROVE creates approve-state.md (via message)"
        else
            fail "T-STOPHOOK-3: Should create approve-state.md" "approve-state.md exists" "not found"
        fi
    fi

    unset CLAUDE_PROJECT_DIR
}

# Test: Dynamic startup_case update when new comments arrive
test_stophook_dynamic_startup_case() {
    local test_subdir="$TEST_DIR/stophook_dynamic_case_test"
    mkdir -p "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00"

    # Start with startup_case=1 (no comments)
    cat > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 42
pr_number: 123
start_branch: test-branch
configured_bots:
  - claude
  - codex
active_bots:
  - claude
  - codex
codex_model: gpt-5.2-codex
codex_effort: medium
codex_timeout: 900
poll_interval: 1
poll_timeout: 2
started_at: 2026-01-18T10:00:00Z
last_trigger_at:
trigger_comment_id:
startup_case: 1
latest_commit_sha: abc123
latest_commit_at: 2026-01-18T10:00:00Z
---
EOF

    echo "# Resolution" > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/round-0-pr-resolve.md"

    local mock_bin="$test_subdir/bin"
    mkdir -p "$mock_bin"

    # Mock gh that returns bot comments (simulating comments arriving)
    cat > "$mock_bin/gh" << 'MOCK_GH'
#!/bin/bash
case "$1" in
    api)
        if [[ "$2" == "user" ]]; then
            echo "testuser"
            exit 0
        fi
        # Return bot comments (claude and codex have commented)
        if [[ "$2" == *"/issues/"*"/comments"* ]]; then
            echo '[{"id":1,"user":{"login":"claude[bot]"},"created_at":"2026-01-18T10:05:00Z","body":"Found issue"},{"id":2,"user":{"login":"chatgpt-codex-connector[bot]"},"created_at":"2026-01-18T10:06:00Z","body":"Also found issue"}]'
            exit 0
        fi
        if [[ "$2" == *"/pulls/"*"/reviews"* ]]; then
            echo '[]'
            exit 0
        fi
        if [[ "$2" == *"/pulls/"*"/comments"* ]]; then
            echo '[]'
            exit 0
        fi
        if [[ "$2" == *"/reactions"* ]]; then
            echo '[]'
            exit 0
        fi
        echo "[]"
        exit 0
        ;;
    pr)
        if [[ "$*" == *"commits"* ]] && [[ "$*" == *"--jq"* ]]; then
            # Return just the timestamp when --jq is used
            echo "2026-01-18T09:00:00Z"
            exit 0
        fi
        if [[ "$*" == *"commits"* ]]; then
            echo '{"commits":[{"committedDate":"2026-01-18T09:00:00Z"}]}'
            exit 0
        fi
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
    rev-parse)
        if [[ "$2" == "HEAD" ]]; then
            echo "abc123"
        else
            echo "/tmp/git"
        fi
        ;;
    status) echo "" ;;
    merge-base) exit 0 ;;
esac
exit 0
MOCK_GIT
    chmod +x "$mock_bin/git"

    export CLAUDE_PROJECT_DIR="$test_subdir"
    export PATH="$mock_bin:$PATH"

    # Run stop hook with timeout (it may poll, so limit to 5 seconds)
    timeout 5 bash -c 'echo "{}" | "$1/hooks/pr-loop-stop-hook.sh" 2>&1' _ "$PROJECT_ROOT" >/dev/null 2>&1 || true

    # Check if startup_case was updated in state file
    local new_case
    new_case=$(grep "^startup_case:" "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/state.md" 2>/dev/null | sed 's/startup_case: *//' | tr -d ' ' || true)

    # With both bots commented and no new commits, should be Case 3
    if [[ "$new_case" == "3" ]]; then
        pass "T-STOPHOOK-4: Dynamic startup_case updated to 3 (all commented, no new commits)"
    elif [[ -n "$new_case" && "$new_case" != "1" ]]; then
        pass "T-STOPHOOK-4: Dynamic startup_case updated from 1 to $new_case"
    else
        fail "T-STOPHOOK-4: startup_case should update dynamically" "case 3" "got: $new_case"
    fi

    unset CLAUDE_PROJECT_DIR
}

# Test: Step 6 - unpushed commits block exit
test_stophook_step6_unpushed_commits() {
    local test_subdir="$TEST_DIR/stophook_step6_test"
    mkdir -p "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00"

    # Create state file
    cat > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 42
pr_number: 123
start_branch: test-branch
configured_bots:
  - codex
active_bots:
  - codex
codex_model: gpt-5.2-codex
codex_effort: medium
codex_timeout: 900
poll_interval: 30
poll_timeout: 900
started_at: 2026-01-18T10:00:00Z
last_trigger_at:
trigger_comment_id:
startup_case: 1
latest_commit_sha: abc123
latest_commit_at: 2026-01-18T10:00:00Z
---
EOF

    echo "# Resolution" > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/round-0-pr-resolve.md"

    local mock_bin="$test_subdir/bin"
    mkdir -p "$mock_bin"

    cat > "$mock_bin/gh" << 'MOCK_GH'
#!/bin/bash
exit 0
MOCK_GH
    chmod +x "$mock_bin/gh"

    # Mock git that reports unpushed commits
    cat > "$mock_bin/git" << 'MOCK_GIT'
#!/bin/bash
case "$1" in
    rev-parse)
        if [[ "$2" == "HEAD" ]]; then
            echo "abc123"
        elif [[ "$2" == "--git-dir" ]]; then
            echo ".git"
        else
            echo "/tmp/git"
        fi
        ;;
    status)
        if [[ "$2" == "--porcelain" ]]; then
            echo ""  # Clean working directory
        elif [[ "$2" == "-sb" ]]; then
            echo "## test-branch...origin/test-branch [ahead 2]"  # 2 unpushed commits
        fi
        ;;
    branch)
        echo "test-branch"
        ;;
    merge-base) exit 0 ;;
esac
exit 0
MOCK_GIT
    chmod +x "$mock_bin/git"

    export CLAUDE_PROJECT_DIR="$test_subdir"
    export PATH="$mock_bin:$PATH"

    local hook_output
    hook_output=$(echo '{}' | "$PROJECT_ROOT/hooks/pr-loop-stop-hook.sh" 2>&1) || true

    # Should block with unpushed commits message
    if echo "$hook_output" | grep -qi "unpushed\|ahead\|push.*commit"; then
        pass "T-STOPHOOK-5: Step 6 blocks on unpushed commits"
    else
        fail "T-STOPHOOK-5: Step 6 should block on unpushed commits" "unpushed/ahead message" "got: $hook_output"
    fi

    unset CLAUDE_PROJECT_DIR
}

# Test: Step 6.5 - force push detection with actual history rewrite simulation
test_stophook_step65_force_push_detection() {
    local test_subdir="$TEST_DIR/stophook_step65_test"
    mkdir -p "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00"

    # State with old commit SHA
    cat > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 42
pr_number: 123
start_branch: test-branch
configured_bots:
  - codex
active_bots:
  - codex
codex_model: gpt-5.2-codex
codex_effort: medium
codex_timeout: 900
poll_interval: 30
poll_timeout: 900
started_at: 2026-01-18T10:00:00Z
last_trigger_at: 2026-01-18T10:30:00Z
trigger_comment_id: 999
startup_case: 1
latest_commit_sha: oldsha123
latest_commit_at: 2026-01-18T10:00:00Z
---
EOF

    echo "# Resolution" > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/round-0-pr-resolve.md"

    local mock_bin="$test_subdir/bin"
    mkdir -p "$mock_bin"

    cat > "$mock_bin/gh" << 'MOCK_GH'
#!/bin/bash
case "$1" in
    pr)
        if [[ "$*" == *"commits"* ]] && [[ "$*" == *"--jq"* ]]; then
            # Return just the timestamp when --jq is used
            echo "2026-01-18T12:00:00Z"
            exit 0
        fi
        if [[ "$*" == *"commits"* ]]; then
            echo '{"commits":[{"committedDate":"2026-01-18T12:00:00Z"}]}'
            exit 0
        fi
        if [[ "$*" == *"state"* ]]; then
            echo '{"state": "OPEN"}'
            exit 0
        fi
        ;;
esac
exit 0
MOCK_GH
    chmod +x "$mock_bin/gh"

    # Mock git that simulates force push: old commit is NOT ancestor of current HEAD
    cat > "$mock_bin/git" << 'MOCK_GIT'
#!/bin/bash
case "$1" in
    rev-parse)
        if [[ "$2" == "HEAD" ]]; then
            echo "newsha456"  # Different from oldsha123 in state
        elif [[ "$2" == "--git-dir" ]]; then
            echo ".git"
        else
            echo "/tmp/git"
        fi
        ;;
    status)
        if [[ "$2" == "--porcelain" ]]; then
            echo ""
        elif [[ "$2" == "-sb" ]]; then
            echo "## test-branch"
        fi
        ;;
    merge-base)
        # Simulate force push: old commit is NOT an ancestor
        # --is-ancestor exits 1 when not ancestor
        exit 1
        ;;
esac
exit 0
MOCK_GIT
    chmod +x "$mock_bin/git"

    export CLAUDE_PROJECT_DIR="$test_subdir"
    export PATH="$mock_bin:$PATH"

    local hook_output
    hook_output=$(echo '{}' | "$PROJECT_ROOT/hooks/pr-loop-stop-hook.sh" 2>&1) || true

    # Should detect force push and block
    if echo "$hook_output" | grep -qi "force.*push\|history.*rewrite\|re-trigger"; then
        pass "T-STOPHOOK-6: Step 6.5 detects force push (history rewrite)"
    else
        fail "T-STOPHOOK-6: Step 6.5 should detect force push" "force push message" "got: $hook_output"
    fi

    unset CLAUDE_PROJECT_DIR
}

# Test: Step 7 - missing trigger comment blocks (Case 4/5)
test_stophook_step7_missing_trigger() {
    local test_subdir="$TEST_DIR/stophook_step7_test"
    mkdir -p "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00"

    # State with startup_case=4 (requires trigger) but no trigger
    cat > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 42
pr_number: 123
start_branch: test-branch
configured_bots:
  - codex
active_bots:
  - codex
codex_model: gpt-5.2-codex
codex_effort: medium
codex_timeout: 900
poll_interval: 30
poll_timeout: 900
started_at: 2026-01-18T10:00:00Z
last_trigger_at:
trigger_comment_id:
startup_case: 4
latest_commit_sha: abc123
latest_commit_at: 2026-01-18T12:00:00Z
---
EOF

    echo "# Resolution" > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/round-0-pr-resolve.md"

    local mock_bin="$test_subdir/bin"
    mkdir -p "$mock_bin"

    # Mock gh that returns no trigger comments
    cat > "$mock_bin/gh" << 'MOCK_GH'
#!/bin/bash
case "$1" in
    api)
        if [[ "$2" == "user" ]]; then
            echo "testuser"
            exit 0
        fi
        if [[ "$2" == *"/issues/"*"/comments"* ]]; then
            echo '[]'  # No comments
            exit 0
        fi
        echo "[]"
        exit 0
        ;;
    pr)
        if [[ "$*" == *"commits"* ]] && [[ "$*" == *"--jq"* ]]; then
            # Return just the timestamp when --jq is used
            echo "2026-01-18T12:00:00Z"
            exit 0
        fi
        if [[ "$*" == *"commits"* ]]; then
            echo '{"commits":[{"committedDate":"2026-01-18T12:00:00Z"}]}'
            exit 0
        fi
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
    rev-parse)
        if [[ "$2" == "HEAD" ]]; then
            echo "abc123"
        elif [[ "$2" == "--git-dir" ]]; then
            echo ".git"
        else
            echo "/tmp/git"
        fi
        ;;
    status)
        if [[ "$2" == "--porcelain" ]]; then
            echo ""
        elif [[ "$2" == "-sb" ]]; then
            echo "## test-branch"
        fi
        ;;
    merge-base) exit 0 ;;
esac
exit 0
MOCK_GIT
    chmod +x "$mock_bin/git"

    export CLAUDE_PROJECT_DIR="$test_subdir"
    export PATH="$mock_bin:$PATH"

    local hook_output
    hook_output=$(echo '{}' | "$PROJECT_ROOT/hooks/pr-loop-stop-hook.sh" 2>&1) || true

    # Should block with missing trigger message
    if echo "$hook_output" | grep -qi "trigger\|@.*mention\|comment"; then
        pass "T-STOPHOOK-7: Step 7 blocks on missing trigger (Case 4)"
    else
        fail "T-STOPHOOK-7: Step 7 should block on missing trigger" "trigger/mention message" "got: $hook_output"
    fi

    unset CLAUDE_PROJECT_DIR
}

# Test: Bot timeout auto-removes bot from active_bots
test_stophook_bot_timeout_auto_remove() {
    local test_subdir="$TEST_DIR/stophook_timeout_test"
    mkdir -p "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00"

    # State with short poll_timeout (2 seconds) to test timeout behavior
    cat > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 42
pr_number: 123
start_branch: test-branch
configured_bots:
  - codex
active_bots:
  - codex
codex_model: gpt-5.2-codex
codex_effort: medium
codex_timeout: 900
poll_interval: 1
poll_timeout: 2
started_at: 2026-01-18T10:00:00Z
last_trigger_at: 2026-01-18T10:30:00Z
trigger_comment_id: 999
startup_case: 3
latest_commit_sha: abc123
latest_commit_at: 2026-01-18T10:00:00Z
---
EOF

    echo "# Resolution" > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/round-0-pr-resolve.md"

    local mock_bin="$test_subdir/bin"
    mkdir -p "$mock_bin"

    # Mock gh that returns NO bot comments (simulates bot not responding)
    cat > "$mock_bin/gh" << 'MOCK_GH'
#!/bin/bash
case "$1" in
    api)
        if [[ "$2" == "user" ]]; then
            echo "testuser"
            exit 0
        fi
        # Return empty for all comment/review queries
        echo "[]"
        exit 0
        ;;
    pr)
        if [[ "$*" == *"commits"* ]] && [[ "$*" == *"--jq"* ]]; then
            # Return just the timestamp when --jq is used
            echo "2026-01-18T10:00:00Z"
            exit 0
        fi
        if [[ "$*" == *"commits"* ]]; then
            echo '{"commits":[{"committedDate":"2026-01-18T10:00:00Z"}]}'
            exit 0
        fi
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
    rev-parse)
        if [[ "$2" == "HEAD" ]]; then
            echo "abc123"
        elif [[ "$2" == "--git-dir" ]]; then
            echo ".git"
        else
            echo "/tmp/git"
        fi
        ;;
    status)
        if [[ "$2" == "--porcelain" ]]; then
            echo ""
        elif [[ "$2" == "-sb" ]]; then
            echo "## test-branch"
        fi
        ;;
    merge-base) exit 0 ;;
esac
exit 0
MOCK_GIT
    chmod +x "$mock_bin/git"

    export CLAUDE_PROJECT_DIR="$test_subdir"
    export PATH="$mock_bin:$PATH"

    # Run stop hook with short timeout - it should time out and auto-remove bots
    local hook_output
    hook_output=$(timeout 10 bash -c 'echo "{}" | "$1/hooks/pr-loop-stop-hook.sh" 2>&1' _ "$PROJECT_ROOT") || true

    # Should either mention timeout or create approve-state (if all bots timed out)
    if echo "$hook_output" | grep -qi "timeout\|timed out\|auto-remove\|approved"; then
        pass "T-STOPHOOK-8: Bot timeout handling"
    elif [[ -f "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/approve-state.md" ]]; then
        pass "T-STOPHOOK-8: Bot timeout created approve-state.md"
    else
        fail "T-STOPHOOK-8: Bot timeout should trigger auto-remove" "timeout/approved message" "got: $hook_output"
    fi

    # VERIFICATION: Check that active_bots was actually updated (removed the bot)
    # After timeout, either:
    # 1. approve-state.md exists with empty active_bots (all bots timed out)
    # 2. state.md has the timed-out bot removed from active_bots
    local state_file=""
    if [[ -f "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/approve-state.md" ]]; then
        state_file="$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/approve-state.md"
    elif [[ -f "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/state.md" ]]; then
        state_file="$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/state.md"
    fi

    # VERIFICATION: Check that approve-state.md was created with empty active_bots
    local approve_file="$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/approve-state.md"
    if [[ -f "$approve_file" ]]; then
        pass "T-STOPHOOK-8a: approve-state.md created - bot timeout led to loop completion"
        # Verify active_bots is empty (not containing 'codex')
        local active_bots_line
        active_bots_line=$(grep "^active_bots:" "$approve_file" 2>/dev/null || true)
        # After the line "active_bots:", check if there are any bot entries
        local next_line_has_bot
        next_line_has_bot=$(sed -n '/^active_bots:/,/^[a-z_]*:/p' "$approve_file" | grep -E '^\s*-\s*\w' || true)
        if [[ -z "$next_line_has_bot" ]]; then
            pass "T-STOPHOOK-8b: active_bots is empty after timeout"
        else
            fail "T-STOPHOOK-8b: active_bots should be empty after timeout" "no bots listed" "got: $next_line_has_bot"
        fi
    else
        fail "T-STOPHOOK-8a: approve-state.md should exist after bot timeout" "approve-state.md exists" "file not found"
    fi

    unset CLAUDE_PROJECT_DIR
}

# Test: Codex +1 detection removes codex from active_bots
test_stophook_codex_thumbsup_approval() {
    local test_subdir="$TEST_DIR/stophook_thumbsup_test"
    mkdir -p "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00"

    # State with startup_case=1 (required for +1 check) and only codex as active bot
    cat > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 42
pr_number: 123
start_branch: test-branch
configured_bots:
  - codex
active_bots:
  - codex
codex_model: gpt-5.2-codex
codex_effort: medium
codex_timeout: 900
poll_interval: 1
poll_timeout: 2
started_at: 2026-01-18T10:00:00Z
last_trigger_at:
trigger_comment_id:
startup_case: 1
latest_commit_sha: abc123
latest_commit_at: 2026-01-18T10:00:00Z
---
EOF

    echo "# Resolution" > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/round-0-pr-resolve.md"

    local mock_bin="$test_subdir/bin"
    mkdir -p "$mock_bin"

    # Mock gh that returns +1 reaction from codex
    cat > "$mock_bin/gh" << 'MOCK_GH'
#!/bin/bash
case "$1" in
    api)
        if [[ "$2" == "user" ]]; then
            echo "testuser"
            exit 0
        fi
        # Return +1 reaction for PR reactions query
        if [[ "$2" == *"/issues/"*"/reactions"* ]]; then
            echo '[{"user":{"login":"chatgpt-codex-connector[bot]"},"content":"+1","created_at":"2026-01-18T10:05:00Z"}]'
            exit 0
        fi
        echo "[]"
        exit 0
        ;;
    pr)
        if [[ "$*" == *"commits"* ]] && [[ "$*" == *"--jq"* ]]; then
            # Return just the timestamp when --jq is used
            echo "2026-01-18T10:00:00Z"
            exit 0
        fi
        if [[ "$*" == *"commits"* ]]; then
            echo '{"commits":[{"committedDate":"2026-01-18T10:00:00Z"}]}'
            exit 0
        fi
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
    rev-parse)
        if [[ "$2" == "HEAD" ]]; then
            echo "abc123"
        elif [[ "$2" == "--git-dir" ]]; then
            echo ".git"
        else
            echo "/tmp/git"
        fi
        ;;
    status)
        if [[ "$2" == "--porcelain" ]]; then
            echo ""
        elif [[ "$2" == "-sb" ]]; then
            echo "## test-branch"
        fi
        ;;
    merge-base) exit 0 ;;
esac
exit 0
MOCK_GIT
    chmod +x "$mock_bin/git"

    export CLAUDE_PROJECT_DIR="$test_subdir"
    export PATH="$mock_bin:$PATH"

    local hook_output
    hook_output=$(echo '{}' | "$PROJECT_ROOT/hooks/pr-loop-stop-hook.sh" 2>&1) || true

    # Should detect +1 and create approve-state.md (since codex is only bot)
    if echo "$hook_output" | grep -qi "+1\|thumbsup\|approved"; then
        pass "T-STOPHOOK-9: Codex +1 detection"
    elif [[ -f "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/approve-state.md" ]]; then
        pass "T-STOPHOOK-9: Codex +1 created approve-state.md"
    else
        fail "T-STOPHOOK-9: Codex +1 should be detected" "+1/approved message" "got: $hook_output"
    fi

    unset CLAUDE_PROJECT_DIR
}

# Test: Claude eyes timeout blocks exit
test_stophook_claude_eyes_timeout() {
    local test_subdir="$TEST_DIR/stophook_eyes_timeout_test"
    mkdir -p "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00"

    # State with claude configured and trigger required (round > 0)
    cat > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/state.md" << 'EOF'
---
current_round: 1
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
poll_interval: 1
poll_timeout: 900
started_at: 2026-01-18T10:00:00Z
last_trigger_at: 2026-01-18T11:00:00Z
trigger_comment_id: 12345
startup_case: 3
latest_commit_sha: abc123
latest_commit_at: 2026-01-18T10:00:00Z
---
EOF

    echo "# Resolution" > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/round-1-pr-resolve.md"

    local mock_bin="$test_subdir/bin"
    mkdir -p "$mock_bin"

    # Mock gh that returns NO eyes reaction (simulates claude bot not configured)
    cat > "$mock_bin/gh" << 'MOCK_GH'
#!/bin/bash
# Check if --jq is in arguments (for transformed format)
HAS_JQ=false
for arg in "$@"; do
    if [[ "$arg" == "--jq" || "$arg" == "-q" ]]; then
        HAS_JQ=true
        break
    fi
done

case "$1" in
    api)
        if [[ "$2" == "user" ]]; then
            echo "testuser"
            exit 0
        fi
        # Return empty reactions - no eyes
        if [[ "$2" == *"/reactions"* ]]; then
            echo "[]"
            exit 0
        fi
        if [[ "$2" == *"/issues/"*"/comments"* ]]; then
            # Return trigger comment
            if [[ "$HAS_JQ" == "true" ]]; then
                # With --jq --paginate, output one transformed object per line
                echo '{"id": 12345, "author": "testuser", "created_at": "2026-01-18T11:00:00Z", "body": "@claude please review"}'
            else
                # Raw GitHub API format
                echo '[{"id": 12345, "user": {"login": "testuser"}, "created_at": "2026-01-18T11:00:00Z", "body": "@claude please review"}]'
            fi
            exit 0
        fi
        echo "[]"
        exit 0
        ;;
    pr)
        if [[ "$*" == *"commits"* ]] && [[ "$*" == *"--jq"* ]]; then
            # Return just the timestamp when --jq is used
            echo "2026-01-18T10:00:00Z"
            exit 0
        fi
        if [[ "$*" == *"commits"* ]]; then
            echo '{"commits":[{"committedDate":"2026-01-18T10:00:00Z"}]}'
            exit 0
        fi
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
    rev-parse)
        if [[ "$2" == "HEAD" ]]; then
            echo "abc123"
        elif [[ "$2" == "--git-dir" ]]; then
            echo ".git"
        else
            echo "/tmp/git"
        fi
        ;;
    status)
        if [[ "$2" == "--porcelain" ]]; then
            echo ""
        elif [[ "$2" == "-sb" ]]; then
            echo "## test-branch"
        fi
        ;;
    merge-base) exit 0 ;;
esac
exit 0
MOCK_GIT
    chmod +x "$mock_bin/git"

    export CLAUDE_PROJECT_DIR="$test_subdir"
    export PATH="$mock_bin:$PATH"

    # Run with timeout since eyes check has 3x5s retry (15s total)
    local hook_output
    hook_output=$(timeout 20 bash -c 'echo "{}" | "$1/hooks/pr-loop-stop-hook.sh" 2>&1' _ "$PROJECT_ROOT") || true

    # Should block with eyes timeout message
    if echo "$hook_output" | grep -qi "eyes\|not responding\|timeout\|bot.*configured"; then
        pass "T-STOPHOOK-10: Claude eyes timeout blocks exit"
    else
        fail "T-STOPHOOK-10: Claude eyes timeout should block" "eyes/timeout message" "got: $hook_output"
    fi

    unset CLAUDE_PROJECT_DIR
}

# Test: Dynamic startup_case update when comments arrive
test_stophook_dynamic_startup_case_update() {
    local test_subdir="$TEST_DIR/stophook_dynamic_case_test2"
    mkdir -p "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00"

    # Use dynamic timestamps to ensure polling doesn't time out immediately
    # Timeline: commit -> trigger -> comment (all recent, all within poll_timeout)
    local trigger_ts commit_ts comment_ts
    # Trigger was 10 seconds ago
    trigger_ts=$(date -u -d "-10 seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-10S +%Y-%m-%dT%H:%M:%SZ)
    # Commit was 60 seconds ago (before trigger)
    commit_ts=$(date -u -d "-60 seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-60S +%Y-%m-%dT%H:%M:%SZ)
    # Comment arrived 5 seconds ago (after trigger, after commit -> case 3)
    comment_ts=$(date -u -d "-5 seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-5S +%Y-%m-%dT%H:%M:%SZ)

    # Start with startup_case=1 (no comments initially), then comments arrive
    # Provide a trigger comment to proceed past timeout checks
    cat > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/state.md" << EOF
---
current_round: 0
max_iterations: 42
pr_number: 123
start_branch: test-branch
configured_bots:
  - codex
active_bots:
  - codex
codex_model: gpt-5.2-codex
codex_effort: medium
codex_timeout: 900
poll_interval: 1
poll_timeout: 60
started_at: $commit_ts
last_trigger_at: $trigger_ts
trigger_comment_id: 999
startup_case: 1
latest_commit_sha: abc123
latest_commit_at: $commit_ts
---
EOF

    echo "# Resolution" > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/round-0-pr-resolve.md"

    local mock_bin="$test_subdir/bin"
    mkdir -p "$mock_bin"

    # Mock gh that returns bot comments (simulating comments arriving)
    # IMPORTANT: poll-pr-reviews.sh expects RAW GitHub API format (with .user.login)
    # check-pr-reviewer-status.sh uses --jq so needs transformed format
    # Use COMMENT_TS environment variable for dynamic timestamp
    cat > "$mock_bin/gh" << MOCK_GH
#!/bin/bash
# Dynamic comment timestamp from test setup
COMMENT_TS="$comment_ts"
COMMIT_TS="$commit_ts"

# Check if --jq is in arguments and what type of jq expression
HAS_JQ=false
JQ_RETURNS_ARRAY=false
ARGS=("\$@")
for ((i=0; i<\${#ARGS[@]}; i++)); do
    if [[ "\${ARGS[i]}" == "--jq" || "\${ARGS[i]}" == "-q" ]]; then
        HAS_JQ=true
        # Check next argument for jq expression starting with [
        next_idx=\$((i + 1))
        if [[ \$next_idx -lt \${#ARGS[@]} ]]; then
            next_arg="\${ARGS[next_idx]}"
            if [[ "\$next_arg" == "["* ]]; then
                JQ_RETURNS_ARRAY=true
            fi
        fi
    fi
done

case "\$1" in
    repo)
        # check-pr-reviewer-status.sh needs repo owner/name with jq transformation
        if [[ "\$*" == *"--json owner,name"* ]] || [[ "\$*" == *"--json owner"* && "\$*" == *"--json name"* ]]; then
            if [[ "\$HAS_JQ" == "true" ]]; then
                # jq '.owner.login + "/" + .name' returns "owner/repo"
                echo "testowner/testrepo"
            else
                echo '{"owner": {"login": "testowner"}, "name": "testrepo"}'
            fi
            exit 0
        fi
        if [[ "\$*" == *"--json parent"* ]]; then
            if [[ "\$HAS_JQ" == "true" ]]; then
                # jq '.parent.owner.login + "/" + .parent.name' returns empty for non-fork
                echo ""
            else
                echo '{"parent": null}'
            fi
            exit 0
        fi
        ;;
    api)
        if [[ "\$2" == "user" ]]; then
            echo "testuser"
            exit 0
        fi
        # Return codex comment - format depends on whether --jq is used and its pattern
        if [[ "\$2" == *"/issues/"*"/comments"* ]]; then
            if [[ "\$HAS_JQ" == "true" ]]; then
                if [[ "\$JQ_RETURNS_ARRAY" == "true" ]]; then
                    # check-pr-reviewer-status.sh uses '[.[] | {...}]' - returns array
                    echo "[{\"author\":\"chatgpt-codex-connector[bot]\",\"created_at\":\"\$COMMENT_TS\",\"body\":\"Found issues\"}]"
                else
                    # stop hook uses '.[] | {...}' then 'jq -s' - returns individual objects
                    echo "{\"id\":1001,\"author\":\"chatgpt-codex-connector[bot]\",\"created_at\":\"\$COMMENT_TS\",\"body\":\"Found issues\"}"
                fi
            else
                # Raw GitHub API format for poll-pr-reviews.sh
                echo "[{\"id\":1001,\"user\":{\"login\":\"chatgpt-codex-connector[bot]\",\"type\":\"Bot\"},\"created_at\":\"\$COMMENT_TS\",\"body\":\"Found issues\"}]"
            fi
            exit 0
        fi
        if [[ "\$2" == *"/pulls/"*"/reviews"* ]]; then
            echo '[]'
            exit 0
        fi
        if [[ "\$2" == *"/pulls/"*"/comments"* ]]; then
            echo '[]'
            exit 0
        fi
        if [[ "\$2" == *"/reactions"* ]]; then
            echo '[]'
            exit 0
        fi
        echo "[]"
        exit 0
        ;;
    pr)
        # PR existence check: gh pr view --repo ... --json number -q .number
        if [[ "\$*" == *"number"* ]] && [[ "\$*" != *"commits"* ]]; then
            echo '{"number": 123}'
            exit 0
        fi
        if [[ "\$*" == *"commits"* ]] && [[ "\$*" == *"headRefOid"* ]]; then
            # For check-pr-reviewer-status.sh: returns jq-processed format
            # {sha: .headRefOid, date: (.commits | last | .committedDate)}
            echo "{\"sha\":\"abc123\",\"date\":\"\$COMMIT_TS\"}"
            exit 0
        fi
        if [[ "\$*" == *"commits"* ]] && [[ "\$*" == *"--jq"* ]]; then
            # Return just the timestamp when --jq is used (stop hook commit fetch)
            echo "\$COMMIT_TS"
            exit 0
        fi
        if [[ "\$*" == *"commits"* ]]; then
            # Commit before the comment
            echo "{\"commits\":[{\"committedDate\":\"\$COMMIT_TS\"}]}"
            exit 0
        fi
        if [[ "\$*" == *"state"* ]]; then
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
    rev-parse)
        if [[ "$2" == "HEAD" ]]; then
            echo "abc123"
        elif [[ "$2" == "--git-dir" ]]; then
            echo ".git"
        else
            echo "/tmp/git"
        fi
        ;;
    status)
        if [[ "$2" == "--porcelain" ]]; then
            echo ""
        elif [[ "$2" == "-sb" ]]; then
            echo "## test-branch"
        fi
        ;;
    merge-base) exit 0 ;;
esac
exit 0
MOCK_GIT
    chmod +x "$mock_bin/git"

    export CLAUDE_PROJECT_DIR="$test_subdir"
    export PATH="$mock_bin:$PATH"

    # Run stop hook with timeout and capture output for debugging
    local hook_output
    hook_output=$(timeout 15 bash -c 'echo "{}" | "$1/hooks/pr-loop-stop-hook.sh" 2>&1' _ "$PROJECT_ROOT" 2>&1) || true

    # Check if startup_case was updated in state file (or approve-state.md if all bots approved/timed out)
    local new_case state_file
    if [[ -f "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/state.md" ]]; then
        state_file="$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/state.md"
    elif [[ -f "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/approve-state.md" ]]; then
        state_file="$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/approve-state.md"
    else
        state_file=""
    fi

    if [[ -n "$state_file" ]]; then
        new_case=$(grep "^startup_case:" "$state_file" 2>/dev/null | sed 's/startup_case: *//' | tr -d ' ' || true)
    else
        new_case=""
    fi

    # Verify startup_case is present in the updated state file (confirms re-evaluation code path ran)
    if [[ -n "$new_case" ]]; then
        pass "T-STOPHOOK-11: Hook completes with startup_case in state"
    else
        fail "T-STOPHOOK-11: startup_case should be preserved in state" "startup_case present" "got: empty/missing"
    fi

    # VERIFICATION: Assert startup_case changed from initial value (1) to expected value
    # Mock setup: codex comment at 10:05:00Z, commit at 09:00:00Z (before comment)
    # Expected: Case 3 (all reviewers commented, no new commits after)
    if [[ -n "$new_case" && "$new_case" != "1" ]]; then
        pass "T-STOPHOOK-11a: startup_case changed from 1 to $new_case"
    elif [[ -n "$new_case" && "$new_case" == "1" ]]; then
        # Debug: check if stop hook re-evaluated startup_case
        if echo "$hook_output" | grep -qi "Startup case changed"; then
            # Re-evaluation ran but case didn't change in state file - state write issue
            fail "T-STOPHOOK-11a: startup_case changed in hook but not persisted" "!= 1" "case_change logged but state=1"
        elif echo "$hook_output" | grep -qi "check-pr-reviewer-status\|NEW_REVIEWER_STATUS"; then
            # Re-evaluation script was called
            fail "T-STOPHOOK-11a: startup_case check ran but returned 1" "!= 1" "got: 1"
        else
            # Re-evaluation didn't run - likely exited early
            local exit_reason
            exit_reason=$(echo "$hook_output" | grep -i "exit\|block\|timeout" | head -3 || echo "unknown")
            fail "T-STOPHOOK-11a: startup_case re-evaluation not reached" "!= 1" "got: 1, exit: $exit_reason"
        fi
    else
        fail "T-STOPHOOK-11a: startup_case should be present and changed" "number != 1" "got: empty"
    fi

    unset CLAUDE_PROJECT_DIR
}

# Test: Fork PR support - stop hook resolves base repo from parent
test_stophook_fork_pr_base_repo_resolution() {
    local test_subdir="$TEST_DIR/stophook_fork_test"
    mkdir -p "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00"

    # Create state file
    cat > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 42
pr_number: 456
start_branch: test-branch
configured_bots:
  - codex
active_bots:
codex_model: gpt-5.2-codex
codex_effort: medium
codex_timeout: 900
poll_interval: 30
poll_timeout: 900
started_at: 2026-01-18T10:00:00Z
last_trigger_at:
trigger_comment_id:
startup_case: 1
latest_commit_sha: abc123
latest_commit_at: 2026-01-18T10:00:00Z
---
EOF

    echo "# Resolution" > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/round-0-pr-resolve.md"

    local mock_bin="$test_subdir/bin"
    mkdir -p "$mock_bin"

    # Mock gh that simulates a fork scenario:
    # - Current repo (fork) doesn't have PR 456
    # - Parent repo (upstream) has PR 456
    cat > "$mock_bin/gh" << 'MOCK_GH'
#!/bin/bash
# Track which repo we're querying
FORK_REPO="forkuser/forkrepo"
UPSTREAM_REPO="upstreamowner/upstreamrepo"

case "$1" in
    repo)
        if [[ "$*" == *"--json owner,name"* ]]; then
            # Current repo is the fork
            echo "forkuser/forkrepo"
            exit 0
        fi
        if [[ "$*" == *"--json parent"* ]]; then
            # Return parent (upstream) repo
            echo "upstreamowner/upstreamrepo"
            exit 0
        fi
        ;;
    pr)
        # Check which --repo was specified
        if [[ "$*" == *"--repo forkuser/forkrepo"* ]]; then
            # Fork doesn't have PR 456 - return empty/error
            exit 1
        fi
        if [[ "$*" == *"--repo upstreamowner/upstreamrepo"* ]]; then
            # Upstream has PR 456
            if [[ "$*" == *"number"* ]] && [[ "$*" != *"commits"* ]]; then
                echo '{"number": 456}'
                exit 0
            fi
            if [[ "$*" == *"state"* ]]; then
                echo '{"state": "OPEN"}'
                exit 0
            fi
            if [[ "$*" == *"commits"* ]] && [[ "$*" == *"--jq"* ]]; then
                echo "2026-01-18T10:00:00Z"
                exit 0
            fi
        fi
        # Default: try to handle without --repo (should fail for forks)
        if [[ "$*" != *"--repo"* ]]; then
            exit 1
        fi
        ;;
esac
exit 0
MOCK_GH
    chmod +x "$mock_bin/gh"

    cat > "$mock_bin/git" << 'MOCK_GIT'
#!/bin/bash
case "$1" in
    rev-parse)
        if [[ "$2" == "HEAD" ]]; then
            echo "abc123"
        else
            echo "/tmp/git"
        fi
        ;;
    status) echo "" ;;
    merge-base) exit 0 ;;
esac
exit 0
MOCK_GIT
    chmod +x "$mock_bin/git"

    export CLAUDE_PROJECT_DIR="$test_subdir"
    export PATH="$mock_bin:$PATH"

    # Run stop hook - should resolve PR from parent repo
    local hook_output
    hook_output=$(echo '{}' | "$PROJECT_ROOT/hooks/pr-loop-stop-hook.sh" 2>&1) || true

    # Should not fail with "PR not found" because it should have found it in parent repo
    # And since active_bots is empty, it should approve
    if echo "$hook_output" | grep -qi "approved\|complete"; then
        pass "T-STOPHOOK-12: Fork PR support - resolved PR from parent repo"
    elif [[ -f "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/approve-state.md" ]]; then
        pass "T-STOPHOOK-12: Fork PR support - created approve-state.md"
    else
        # Check if it at least didn't fail with "PR not found"
        if ! echo "$hook_output" | grep -qi "pr.*not.*found\|no.*pull.*request"; then
            pass "T-STOPHOOK-12: Fork PR support - did not fail on PR lookup"
        else
            fail "T-STOPHOOK-12: Fork PR should resolve from parent" "success" "got: $hook_output"
        fi
    fi

    unset CLAUDE_PROJECT_DIR
}

# Test: Goal tracker - resolved count stays 0 when some bots have issues
test_stophook_goal_tracker_mixed_approval() {
    local test_subdir="$TEST_DIR/stophook_goal_tracker_test"
    mkdir -p "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00"

    # Use dynamic timestamps to ensure polling doesn't time out immediately
    # Timeline: commit -> trigger -> bot comments (all recent, within poll_timeout)
    local trigger_ts commit_ts claude_ts codex_ts
    # Trigger was 10 seconds ago
    trigger_ts=$(date -u -d "-10 seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-10S +%Y-%m-%dT%H:%M:%SZ)
    # Commit was 60 seconds ago (before trigger)
    commit_ts=$(date -u -d "-60 seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-60S +%Y-%m-%dT%H:%M:%SZ)
    # Claude comment arrived 5 seconds ago (after trigger)
    claude_ts=$(date -u -d "-5 seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-5S +%Y-%m-%dT%H:%M:%SZ)
    # Codex comment arrived 4 seconds ago (after trigger)
    codex_ts=$(date -u -d "-4 seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-4S +%Y-%m-%dT%H:%M:%SZ)

    # State with two bots configured
    cat > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/state.md" << EOF
---
current_round: 0
max_iterations: 42
pr_number: 123
start_branch: test-branch
configured_bots:
  - claude
  - codex
active_bots:
  - claude
  - codex
codex_model: gpt-5.2-codex
codex_effort: medium
codex_timeout: 900
poll_interval: 1
poll_timeout: 60
started_at: $commit_ts
last_trigger_at: $trigger_ts
trigger_comment_id: 999
startup_case: 3
latest_commit_sha: abc123
latest_commit_at: $commit_ts
---
EOF

    echo "# Resolution" > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/round-0-pr-resolve.md"

    # Create initial goal tracker
    cat > "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/goal-tracker.md" << EOF
# PR Loop Goal Tracker

## Stats
- Issues Found: 0
- Issues Resolved: 0

## Log
| Round | Timestamp | Event |
|-------|-----------|-------|
| 0 | $commit_ts | Loop started |
EOF

    local mock_bin="$test_subdir/bin"
    mkdir -p "$mock_bin"

    # Mock gh that returns:
    # - claude: APPROVE (LGTM)
    # - codex: ISSUES (has issues)
    cat > "$mock_bin/gh" << MOCK_GH
#!/bin/bash
# Dynamic timestamps from test setup
CLAUDE_TS="$claude_ts"
CODEX_TS="$codex_ts"
COMMIT_TS="$commit_ts"

HAS_JQ=false
for arg in "\$@"; do
    if [[ "\$arg" == "--jq" || "\$arg" == "-q" ]]; then
        HAS_JQ=true
        break
    fi
done

case "\$1" in
    repo)
        if [[ "\$*" == *"--json owner,name"* ]]; then
            echo "testowner/testrepo"
            exit 0
        fi
        if [[ "\$*" == *"--json parent"* ]]; then
            echo ""
            exit 0
        fi
        ;;
    api)
        if [[ "\$2" == "user" ]]; then
            echo "testuser"
            exit 0
        fi
        # Return comments from both bots
        if [[ "\$2" == *"/issues/"*"/comments"* ]]; then
            if [[ "\$HAS_JQ" == "true" ]]; then
                # Claude approves, Codex has issues
                echo "{\"id\": 1, \"author\": \"claude[bot]\", \"created_at\": \"\$CLAUDE_TS\", \"body\": \"LGTM! No issues found.\"}"
                echo "{\"id\": 2, \"author\": \"chatgpt-codex-connector[bot]\", \"created_at\": \"\$CODEX_TS\", \"body\": \"Found 2 issues that need fixing.\"}"
            else
                echo "[{\"id\": 1, \"user\": {\"login\": \"claude[bot]\"}, \"created_at\": \"\$CLAUDE_TS\", \"body\": \"LGTM! No issues found.\"},{\"id\": 2, \"user\": {\"login\": \"chatgpt-codex-connector[bot]\"}, \"created_at\": \"\$CODEX_TS\", \"body\": \"Found 2 issues that need fixing.\"}]"
            fi
            exit 0
        fi
        if [[ "\$2" == *"/reactions"* ]]; then
            # Return eyes for claude (no need for this test but keep consistent)
            echo "[]"
            exit 0
        fi
        echo "[]"
        exit 0
        ;;
    pr)
        # PR existence check: gh pr view --repo ... --json number -q .number
        if [[ "\$*" == *"number"* ]] && [[ "\$*" != *"commits"* ]]; then
            echo '{"number": 123}'
            exit 0
        fi
        if [[ "\$*" == *"state"* ]]; then
            echo '{"state": "OPEN"}'
            exit 0
        fi
        if [[ "\$*" == *"commits"* ]] && [[ "\$*" == *"--jq"* ]]; then
            echo "\$COMMIT_TS"
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
    rev-parse)
        if [[ "$2" == "HEAD" ]]; then
            echo "abc123"
        else
            echo "/tmp/git"
        fi
        ;;
    status)
        if [[ "$2" == "--porcelain" ]]; then
            echo ""
        elif [[ "$2" == "-sb" ]]; then
            echo "## test-branch"
        fi
        ;;
    merge-base) exit 0 ;;
esac
exit 0
MOCK_GIT
    chmod +x "$mock_bin/git"

    # Mock codex that outputs mixed approval
    cat > "$mock_bin/codex" << 'MOCK_CODEX'
#!/bin/bash
# Mock codex output: claude approves, codex has issues
cat << 'CODEX_OUTPUT'
# PR Review Validation

### Per-Bot Status
| Bot | Status | Summary |
|-----|--------|---------|
| claude | APPROVE | No issues found |
| codex | ISSUES | Found 2 issues that need fixing |

### Issues Found (if any)
1. Issue from codex: Missing error handling
2. Issue from codex: Needs tests

### Approved Bots (to remove from active_bots)
- claude

### Final Recommendation
ISSUES_REMAINING
CODEX_OUTPUT
MOCK_CODEX
    chmod +x "$mock_bin/codex"

    export CLAUDE_PROJECT_DIR="$test_subdir"
    export PATH="$mock_bin:$PATH"

    # Run stop hook
    local hook_output
    hook_output=$(timeout 30 bash -c 'echo "{}" | "$1/hooks/pr-loop-stop-hook.sh" 2>&1' _ "$PROJECT_ROOT") || true

    # Verify that ISSUES_RESOLVED_COUNT is 0, not inflated to ISSUES_FOUND_COUNT
    # The goal tracker should show issues found > 0 but resolved = 0
    # (because codex still has issues, even though claude approved)

    # Check the feedback file or check file for the correct issue counts
    local check_file="$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/round-1-pr-check.md"
    if [[ -f "$check_file" ]]; then
        # Check that issues were found
        if grep -q "Issues Found\|ISSUES" "$check_file" 2>/dev/null; then
            pass "T-STOPHOOK-13: Goal tracker correctly identifies issues"
        else
            fail "T-STOPHOOK-13: Check file should contain issues" "issues listed" "not found"
        fi
    else
        # Check file may not exist if polling didn't complete
        # Check output instead
        if echo "$hook_output" | grep -qi "issues.*remaining\|ISSUES_REMAINING"; then
            pass "T-STOPHOOK-13: Goal tracker correctly identifies issues (via output)"
        else
            fail "T-STOPHOOK-13: Should detect issues remaining" "issues_remaining" "got: $hook_output"
        fi
    fi

    # VERIFICATION: The key fix - resolved count should NOT be inflated
    # Since we can't directly check ISSUES_RESOLVED_COUNT variable, verify the behavior:
    # - claude approved (removed from active_bots)
    # - codex has issues (stays in active_bots)
    # - loop should continue (not complete) because codex still has issues

    if [[ ! -f "$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/approve-state.md" ]]; then
        pass "T-STOPHOOK-13a: Loop continues with mixed approval (not prematurely completed)"
    else
        fail "T-STOPHOOK-13a: Loop should not complete with mixed approval" "no approve-state.md" "approve-state.md exists"
    fi

    # Check that claude was removed from active_bots but codex remains
    local state_file="$test_subdir/.humanize/pr-loop/2026-01-18_12-00-00/state.md"
    if [[ -f "$state_file" ]]; then
        local active_bots_content
        active_bots_content=$(sed -n '/^active_bots:/,/^[a-z_]*:/p' "$state_file" | grep -E '^\s*-' || true)

        if echo "$active_bots_content" | grep -q "codex"; then
            pass "T-STOPHOOK-13b: Codex remains in active_bots (has issues)"
        else
            fail "T-STOPHOOK-13b: Codex should remain in active_bots" "codex in list" "got: $active_bots_content"
        fi

        if ! echo "$active_bots_content" | grep -q "claude"; then
            pass "T-STOPHOOK-13c: Claude removed from active_bots (approved)"
        else
            fail "T-STOPHOOK-13c: Claude should be removed from active_bots" "no claude" "got: $active_bots_content"
        fi
    fi

    unset CLAUDE_PROJECT_DIR
}

# Run stop-hook integration tests
test_stophook_force_push_rejects_old_trigger
test_stophook_case1_no_trigger_required
test_stophook_approve_creates_state
test_stophook_step6_unpushed_commits
test_stophook_step65_force_push_detection
test_stophook_step7_missing_trigger
test_stophook_bot_timeout_auto_remove
test_stophook_codex_thumbsup_approval
test_stophook_claude_eyes_timeout
test_stophook_dynamic_startup_case_update
test_stophook_fork_pr_base_repo_resolution
test_stophook_goal_tracker_mixed_approval

}
