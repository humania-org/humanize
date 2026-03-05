#!/bin/bash
#
# Tests for task-tag routing in RLCR loop prompts
#
# Validates:
# - round-0 prompt includes coding/analyze routing instructions
# - goal-tracker Active Tasks table includes Tag/Owner columns
# - stop hook keeps task-tag routing reminder in follow-up prompts
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

SETUP_SCRIPT="$PROJECT_ROOT/scripts/setup-rlcr-loop.sh"
STOP_HOOK="$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh"

echo "=========================================="
echo "Task Tag Routing Tests"
echo "=========================================="
echo ""

create_mock_codex() {
    local bin_dir="$1"
    local exec_output="${2:-Need follow-up work}"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/codex" << MOCK_EOF
#!/bin/bash
if [[ "\$1" == "exec" ]]; then
    cat << 'OUT'
$exec_output
OUT
elif [[ "\$1" == "review" ]]; then
    echo "No issues found."
else
    echo "mock-codex: unsupported command \$1" >&2
    exit 1
fi
MOCK_EOF
    chmod +x "$bin_dir/codex"
}

create_plan_and_repo() {
    local repo_dir="$1"
    local plan_body="$2"

    init_test_git_repo "$repo_dir"
    mkdir -p "$repo_dir/plans"
    cat > "$repo_dir/plans/plan.md" << EOF
$plan_body
EOF
    cat > "$repo_dir/.gitignore" << 'EOF'
plans/
.humanize/
bin/
.cache/
EOF
    git -C "$repo_dir" add .gitignore
    git -C "$repo_dir" commit -q -m "Add gitignore for test artifacts"
}

# ========================================
# Test: round-0 prompt includes task-tag routing guidance
# ========================================

setup_test_dir
create_plan_and_repo "$TEST_DIR/repo-routing" '# Feature Plan

## Goal
Implement and validate feature behavior.

## Acceptance Criteria
- AC-1: Endpoint works
- AC-2: Analysis notes captured

## Task Breakdown
| Task ID | Description | Target AC | Tag (`coding`/`analyze`) | Depends On |
|---------|-------------|-----------|----------------------------|------------|
| task1 | Implement endpoint | AC-1 | coding | - |
| task2 | Analyze rollout risk | AC-2 | analyze | task1
'
create_mock_codex "$TEST_DIR/repo-routing/bin"

cd "$TEST_DIR/repo-routing"
PATH="$TEST_DIR/repo-routing/bin:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR/repo-routing" bash "$SETUP_SCRIPT" plans/plan.md > /dev/null 2>&1

PROMPT_FILE=$(find "$TEST_DIR/repo-routing/.humanize/rlcr" -name "round-0-prompt.md" -type f | head -1)
GOAL_TRACKER_FILE=$(find "$TEST_DIR/repo-routing/.humanize/rlcr" -name "goal-tracker.md" -type f | head -1)

if [[ -n "$PROMPT_FILE" ]] && grep -q "## Task Tag Routing (MUST FOLLOW)" "$PROMPT_FILE"; then
    pass "round-0 prompt includes task tag routing section"
else
    fail "round-0 prompt includes task tag routing section" "routing section present" "missing"
fi

if [[ -n "$PROMPT_FILE" ]] && grep -q "/humanize:ask-codex" "$PROMPT_FILE"; then
    pass "round-0 prompt includes ask-codex routing for analyze tasks"
else
    fail "round-0 prompt includes ask-codex routing for analyze tasks" "ask-codex instruction" "missing"
fi

if [[ -n "$GOAL_TRACKER_FILE" ]] && grep -q "^| Task | Target AC | Status | Tag | Owner | Notes |" "$GOAL_TRACKER_FILE"; then
    pass "goal tracker Active Tasks table includes Tag/Owner columns"
else
    fail "goal tracker Active Tasks table includes Tag/Owner columns" "table header with Tag/Owner" "missing"
fi

# ========================================
# Stop hook follow-up prompt routing reminder
# ========================================

setup_stophook_repo() {
    local repo_dir="$1"

    init_test_git_repo "$repo_dir"
    mkdir -p "$repo_dir/plans"
    cat > "$repo_dir/plans/plan.md" << 'EOF'
# Routing Hook Plan

## Goal
Ensure task routing remains consistent.

## Acceptance Criteria
- AC-1: Routing reminder is present

## Task Breakdown
| Task ID | Description | Target AC | Tag (`coding`/`analyze`) | Depends On |
|---------|-------------|-----------|----------------------------|------------|
| task1 | Implement output | AC-1 | coding | - |
| task2 | Analyze constraints | AC-1 | analyze | task1
EOF
    cat > "$repo_dir/.gitignore" << 'EOF'
plans/
.humanize/
bin/
.cache/
EOF
    git -C "$repo_dir" add .gitignore
    git -C "$repo_dir" commit -q -m "Add gitignore"

    local current_branch
    current_branch=$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD)

    local loop_dir="$repo_dir/.humanize/rlcr/2024-02-01_12-00-00"
    mkdir -p "$loop_dir"
    cat > "$loop_dir/state.md" << EOF
---
current_round: 0
max_iterations: 10
codex_model: gpt-5.3-codex
codex_effort: xhigh
codex_timeout: 5400
push_every_round: false
plan_file: plans/plan.md
plan_tracked: false
start_branch: $current_branch
base_branch: main
base_commit: abc123
review_started: false
ask_codex_question: false
full_review_round: 5
session_id:
---
EOF
    cp "$repo_dir/plans/plan.md" "$loop_dir/plan.md"
    cat > "$loop_dir/goal-tracker.md" << 'EOF'
# Goal Tracker
## IMMUTABLE SECTION
### Ultimate Goal
Keep routing behavior stable.
### Acceptance Criteria
| ID | Criterion |
|----|-----------|
| AC-1 | Routing reminder is present |
---
## MUTABLE SECTION
#### Active Tasks
| Task | Target AC | Status | Tag | Owner | Notes |
|------|-----------|--------|-----|-------|-------|
| Keep routing note | AC-1 | in_progress | analyze | codex | -
EOF
    cat > "$loop_dir/round-0-summary.md" << 'EOF'
# Round 0 Summary

More work remains.
EOF
}

setup_test_dir
setup_stophook_repo "$TEST_DIR/hook-routing"
create_mock_codex "$TEST_DIR/hook-routing/bin" "## Review Feedback

Issue remains unresolved.

CONTINUE"
export PATH="$TEST_DIR/hook-routing/bin:$PATH"
export XDG_CACHE_HOME="$TEST_DIR/hook-routing/.cache"
HOOK_INPUT='{"stop_hook_active": false, "transcript": [], "session_id": ""}'
echo "$HOOK_INPUT" | CLAUDE_PROJECT_DIR="$TEST_DIR/hook-routing" bash "$STOP_HOOK" > /dev/null 2>&1 || true
NEXT_PROMPT="$TEST_DIR/hook-routing/.humanize/rlcr/2024-02-01_12-00-00/round-1-prompt.md"

if [[ -f "$NEXT_PROMPT" ]] && grep -q "## Task Tag Routing Reminder" "$NEXT_PROMPT"; then
    pass "stop hook follow-up prompt includes task tag routing reminder"
else
    fail "stop hook follow-up prompt includes task tag routing reminder" "routing reminder section" "missing"
fi

if [[ -f "$NEXT_PROMPT" ]] && grep -q "/humanize:ask-codex" "$NEXT_PROMPT"; then
    pass "stop hook follow-up prompt includes ask-codex instruction for analyze tasks"
else
    fail "stop hook follow-up prompt includes ask-codex instruction for analyze tasks" "ask-codex instruction in round-1 prompt" "missing"
fi

print_test_summary "Task Tag Routing Tests"
