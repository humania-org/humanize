#!/usr/bin/env bash
#
# Ensure Humanize's nested Codex reviewer calls disable native hooks to avoid recursion.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo -e "${GREEN}PASS${NC}: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "${RED}FAIL${NC}: $1"
    echo "  Expected: $2"
    echo "  Got: $3"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

echo "=========================================="
echo "Disable Nested Codex Hooks Tests"
echo "=========================================="
echo ""

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

export XDG_CACHE_HOME="$TEST_DIR/.cache"
mkdir -p "$XDG_CACHE_HOME"

STOP_HOOK="$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh"

setup_repo() {
    local repo_dir="$1"

    mkdir -p "$repo_dir"
    cd "$repo_dir"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test User"
    git config commit.gpgsign false

    cat > .gitignore <<'EOF'
.humanize/
plans/
.cache/
EOF
    mkdir -p plans
    cat > plans/test-plan.md <<'EOF'
# Test Plan
EOF
    echo "init" > init.txt
    git add .gitignore init.txt
    git -c commit.gpgsign=false commit -q -m "initial"
}

setup_mock_codex() {
    local bin_dir="$1"
    local args_file="$2"

    mkdir -p "$bin_dir"
    cat > "$bin_dir/codex" <<EOF
#!/usr/bin/env bash
# The stop hook probes feature support with \`codex --help\`; advertise
# --disable so the nested invocation is expected to include it.
if [[ "\$1" == "--help" ]]; then
    cat <<HELP
Usage: codex [OPTIONS] <COMMAND>

Options:
  --disable <HOOK>         Disable a specific Codex hook (e.g. hooks)
  --skip-git-repo-check    Skip git repo validation
HELP
    exit 0
fi

printf '%s\n' "\$*" > "$args_file"

subcommand=""
for arg in "\$@"; do
    if [[ "\$arg" == "exec" || "\$arg" == "review" ]]; then
        subcommand="\$arg"
        break
    fi
done

if [[ "\$subcommand" == "exec" ]]; then
    echo "Review: keep iterating."
    exit 0
fi

if [[ "\$subcommand" == "review" ]]; then
    saw_base=false
    saw_prompt=false
    for arg in "\$@"; do
        if [[ "\$arg" == "--base" ]]; then
            saw_base=true
        elif [[ "\$arg" == "-" ]]; then
            saw_prompt=true
        fi
    done
    if [[ "\$saw_base" == "true" && "\$saw_prompt" == "true" ]]; then
        echo "codex 0.130.0 rejects --base with prompt input" >&2
        exit 64
    fi
    if IFS= read -r stdin_line || [[ -n "\$stdin_line" ]]; then
        printf 'STDIN:%s\n' "\$stdin_line" >> "$args_file"
        echo "codex review must not receive stdin when --base is used" >&2
        exit 65
    fi
    echo "No issues found."
    exit 0
fi

echo "unexpected codex args: \$*" >&2
exit 1
EOF
    chmod +x "$bin_dir/codex"
}

setup_loop_dir() {
    local repo_dir="$1"
    local review_started="$2"
    local loop_dir="$repo_dir/.humanize/rlcr/2026-03-14_12-00-00"
    local current_branch
    local base_commit

    current_branch="$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD)"
    base_commit="$(git -C "$repo_dir" rev-parse HEAD)"

    mkdir -p "$loop_dir"
    cat > "$loop_dir/state.md" <<EOF
---
current_round: 1
max_iterations: 42
plan_file: plans/test-plan.md
plan_tracked: false
start_branch: $current_branch
base_branch: $current_branch
base_commit: $base_commit
push_every_round: false
codex_model: gpt-5.5
codex_effort: high
codex_timeout: 120
review_started: $review_started
started_at: 2026-03-14T12:00:00Z
ask_codex_question: false
agent_teams: false
---
EOF

    cp "$repo_dir/plans/test-plan.md" "$loop_dir/plan.md"
    cat > "$loop_dir/goal-tracker.md" <<'EOF'
# Goal Tracker
## IMMUTABLE SECTION
### Ultimate Goal
Test nested codex disable
### Acceptance Criteria
- AC-1: Hook can run

## MUTABLE SECTION
### Active Tasks
- Verify hook argv
EOF

    cat > "$loop_dir/round-1-summary.md" <<'EOF'
# Round Summary
Implemented initial changes.
EOF

    if [[ "$review_started" == "true" ]]; then
        echo "build_finish_round=1" > "$loop_dir/.review-phase-started"
    fi
}

run_loop_hook() {
    local repo_dir="$1"
    local args_file="$2"
    local review_started="$3"
    local bin_dir="$TEST_DIR/bin-${review_started}"

    setup_mock_codex "$bin_dir" "$args_file"
    setup_loop_dir "$repo_dir" "$review_started"

    set +e
    OUTPUT=$(echo '{}' | PATH="$bin_dir:$PATH" CLAUDE_PROJECT_DIR="$repo_dir" bash "$STOP_HOOK" 2>&1)
    EXIT_CODE=$?
    set -e

    if [[ $EXIT_CODE -ne 0 ]]; then
        fail "loop hook completes in $review_started mode" "exit 0" "exit=$EXIT_CODE output=$OUTPUT"
        return
    fi
}

REPO_IMPL="$TEST_DIR/repo-impl"
setup_repo "$REPO_IMPL"
run_loop_hook "$REPO_IMPL" "$TEST_DIR/impl.args" "false"

if grep -q -- 'exec --disable hooks' "$TEST_DIR/impl.args"; then
    pass "implementation-phase stop hook disables hooks for codex exec"
else
    fail "implementation-phase stop hook disables hooks for codex exec" \
        "exec --disable hooks" "$(cat "$TEST_DIR/impl.args" 2>/dev/null || echo missing)"
fi

REPO_REVIEW="$TEST_DIR/repo-review"
setup_repo "$REPO_REVIEW"
run_loop_hook "$REPO_REVIEW" "$TEST_DIR/review.args" "true"

if grep -q -- 'review --disable hooks' "$TEST_DIR/review.args"; then
    pass "review-phase stop hook disables hooks for codex review"
else
    fail "review-phase stop hook disables hooks for codex review" \
        "review --disable hooks" "$(cat "$TEST_DIR/review.args" 2>/dev/null || echo missing)"
fi

if ! grep -q 'codex --help 2>&1 | grep -q' "$STOP_HOOK"; then
    pass "stop hook captures codex help before grepping for --disable"
else
    fail "stop hook captures codex help before grepping for --disable" \
        "no codex --help | grep -q pipeline" \
        "pipeline still present"
fi

if grep -q -- ' --base ' "$TEST_DIR/review.args" && ! grep -q -- ' -$' "$TEST_DIR/review.args" && ! grep -q '^STDIN:' "$TEST_DIR/review.args"; then
    pass "review-phase codex review uses --base without prompt input"
else
    fail "review-phase codex review avoids --base plus prompt input" \
        "--base arguments with no trailing '-' and no stdin" "$(cat "$TEST_DIR/review.args" 2>/dev/null || echo missing)"
fi

REVIEW_PROMPT=""
if [[ -d "$REPO_REVIEW/.humanize/rlcr" ]]; then
    REVIEW_PROMPT=$(find "$REPO_REVIEW/.humanize/rlcr" -mindepth 2 -maxdepth 2 -type f -name 'round-*-review-prompt.md' -print | sort | tail -n 1)
fi
if [[ -f "$REVIEW_PROMPT" ]] && grep -q -- 'must not pass prompt input when `--base` is used' "$REVIEW_PROMPT"; then
    pass "review audit prompt documents --base prompt incompatibility"
else
    fail "review audit prompt documents --base prompt incompatibility" \
        'must not pass prompt input when `--base` is used' "$(cat "$REVIEW_PROMPT" 2>/dev/null || echo missing)"
fi

echo ""
echo "========================================"
echo "Disable Nested Codex Hooks Tests"
echo "========================================"
echo "Passed: $TESTS_PASSED"
echo "Failed: $TESTS_FAILED"

if [[ $TESTS_FAILED -ne 0 ]]; then
    exit 1
fi
