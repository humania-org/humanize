#!/bin/bash
#
# Tests for legacy compatibility fixes in loop-codex-stop-hook.sh
#
# Covers:
# - Untracked legacy .humanize-* directories do not trigger git-dirty blocks
# - Untracked .humanizeconfig still triggers git-dirty blocks as a real file
# - Legacy loops without bitlesson_required stay disabled even if
#   .humanize/bitlesson.md exists
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

STOP_HOOK="$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh"

setup_test_dir

export XDG_CACHE_HOME="$TEST_DIR/.cache"
mkdir -p "$XDG_CACHE_HOME"

setup_mock_codex() {
    mkdir -p "$TEST_DIR/bin"
    cat > "$TEST_DIR/bin/codex" << 'EOF'
#!/bin/bash
if [[ -n "${MOCK_CODEX_MARKER:-}" ]]; then
    : > "$MOCK_CODEX_MARKER"
fi

printf '%s\n' "${MOCK_CODEX_OUTPUT:-Mock review feedback}"
exit 0
EOF
    chmod +x "$TEST_DIR/bin/codex"
    export PATH="$TEST_DIR/bin:$PATH"
}

create_stop_hook_fixture() {
    local repo_dir="$1"
    local include_bitlesson="${2:-false}"
    local branch
    local base_commit
    local loop_dir

    init_test_git_repo "$repo_dir"

    printf 'plans/\n' > "$repo_dir/.gitignore"
    git -C "$repo_dir" add .gitignore
    git -C "$repo_dir" commit -q -m "Add test gitignore"

    mkdir -p "$repo_dir/plans"
    cat > "$repo_dir/plans/test-plan.md" << 'EOF'
# Test Plan

Keep stop-hook legacy compatibility intact.
EOF

    branch=$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD)
    base_commit=$(git -C "$repo_dir" rev-parse HEAD)
    loop_dir="$repo_dir/.humanize/rlcr/2026-03-01_00-00-00"
    mkdir -p "$loop_dir"

    cp "$repo_dir/plans/test-plan.md" "$loop_dir/plan.md"

    cat > "$loop_dir/state.md" << EOF
---
current_round: 0
max_iterations: 42
codex_model: gpt-5.4
codex_effort: high
codex_timeout: 60
push_every_round: false
full_review_round: 5
plan_file: "plans/test-plan.md"
plan_tracked: false
start_branch: $branch
base_branch: $branch
base_commit: $base_commit
review_started: false
ask_codex_question: false
agent_teams: false
---
EOF

    # Intentionally omit BitLesson Delta in the summary so the legacy
    # bitlesson_required fallback would block before Codex if it regresses.
    cat > "$loop_dir/round-0-summary.md" << 'EOF'
# Summary

Validated stop-hook compatibility behavior.
EOF

    cat > "$loop_dir/goal-tracker.md" << 'EOF'
# Goal Tracker
## IMMUTABLE SECTION
### Ultimate Goal
Preserve legacy stop-hook compatibility.
### Acceptance Criteria
- AC-1: Hook reaches Codex review.
## MUTABLE SECTION
### Plan Version: 1 (Updated: Round 0)
#### Active Tasks
| Task | Target AC | Status | Notes |
|------|-----------|--------|-------|
| Validate stop-hook | AC-1 | completed | - |
EOF

    if [[ "$include_bitlesson" == "true" ]]; then
        mkdir -p "$repo_dir/.humanize"
        cat > "$repo_dir/.humanize/bitlesson.md" << 'EOF'
# BitLesson

- L-1: Example lesson entry.
EOF
    fi
}

run_stop_hook() {
    local repo_dir="$1"

    RUN_MARKER="$repo_dir/codex-called.marker"
    rm -f "$RUN_MARKER"

    set +e
    RUN_OUTPUT=$(
        cd "$repo_dir"
        CLAUDE_PROJECT_DIR="$repo_dir" \
        MOCK_CODEX_MARKER="$RUN_MARKER" \
        MOCK_CODEX_OUTPUT="Mock review feedback" \
        "$STOP_HOOK" <<< '{}' 2>&1
    )
    RUN_EXIT_CODE=$?
    set -e
}

setup_mock_codex

echo "=========================================="
echo "Stop Hook Legacy Compatibility Tests"
echo "=========================================="
echo ""

echo "Test 1: Untracked legacy .humanize-* paths are ignored for dirty checks"
TEST1_REPO="$TEST_DIR/test1"
create_stop_hook_fixture "$TEST1_REPO"
mkdir -p "$TEST1_REPO/.humanize-old"
echo "legacy state" > "$TEST1_REPO/.humanize-old/legacy.txt"
run_stop_hook "$TEST1_REPO"

if [[ "$RUN_EXIT_CODE" -eq 0 ]] && [[ -f "$RUN_MARKER" ]] && \
   ! echo "$RUN_OUTPUT" | grep -q "Loop: Blocked - uncommitted changes"; then
    pass "Stop hook ignores untracked .humanize-old paths when checking git dirtiness"
else
    fail \
        "Stop hook ignores untracked .humanize-old paths when checking git dirtiness" \
        "exit 0, Codex invoked, no uncommitted-changes block" \
        "exit $RUN_EXIT_CODE, marker=$(test -f "$RUN_MARKER" && echo present || echo missing), output: $RUN_OUTPUT"
fi

echo "Test 1b: Untracked .humanizeconfig still blocks dirty checks"
TEST1B_REPO="$TEST_DIR/test1b"
create_stop_hook_fixture "$TEST1B_REPO"
touch "$TEST1B_REPO/.humanizeconfig"
run_stop_hook "$TEST1B_REPO"

if [[ "$RUN_EXIT_CODE" -eq 0 ]] && [[ ! -f "$RUN_MARKER" ]] && \
   echo "$RUN_OUTPUT" | grep -q "Loop: Blocked - uncommitted changes" && \
   echo "$RUN_OUTPUT" | grep -q "Special Case - \\.humanize directory detected" && \
   echo "$RUN_OUTPUT" | grep -q "Note on Untracked Files"; then
    pass "Stop hook treats .humanizeconfig as a normal untracked file"
else
    fail \
        "Stop hook treats .humanizeconfig as a normal untracked file" \
        "blocked before Codex with both humanize-runtime and generic untracked-file notes" \
        "exit $RUN_EXIT_CODE, marker=$(test -f "$RUN_MARKER" && echo present || echo missing), output: $RUN_OUTPUT"
fi

echo "Test 2: Legacy loops keep bitlesson_required disabled when state omits it"
TEST2_REPO="$TEST_DIR/test2"
create_stop_hook_fixture "$TEST2_REPO" true
run_stop_hook "$TEST2_REPO"

if [[ "$RUN_EXIT_CODE" -eq 0 ]] && [[ -f "$RUN_MARKER" ]]; then
    pass "Legacy loops without bitlesson_required still reach Codex even when .humanize/bitlesson.md exists"
else
    fail \
        "Legacy loops without bitlesson_required still reach Codex even when .humanize/bitlesson.md exists" \
        "exit 0 and Codex invoked" \
        "exit $RUN_EXIT_CODE, marker=$(test -f "$RUN_MARKER" && echo present || echo missing), output: $RUN_OUTPUT"
fi

print_test_summary "Stop Hook Legacy Compatibility Test Summary"
exit $?
