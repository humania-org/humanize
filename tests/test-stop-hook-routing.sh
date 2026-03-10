#!/bin/bash
# Tests for loop-codex-stop-hook.sh provider routing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"
STOP_HOOK="$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh"
SETUP_SCRIPT="$PROJECT_ROOT/scripts/setup-rlcr-loop.sh"
SAFE_BASE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
HOOK_INPUT='{"stop_hook_active": false, "transcript": [], "session_id": ""}'
LOOP_TIMESTAMP="2024-02-01_12-00-00"

echo "=========================================="
echo "Stop Hook Routing Tests"
echo "=========================================="
echo ""

setup_stop_hook_repo() {
    local model="$1"
    local review_started="${2:-false}"
    local round="${3:-1}"
    local reviewer_effort="${4:-high}"

    setup_test_dir
    cd "$TEST_DIR"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test User"
    git config commit.gpgsign false

    mkdir -p plans
    cat > tracked.txt <<'EOF'
initial content
EOF
    cat > plans/plan.md <<'EOF'
# Test Plan

## Goal
Verify stop-hook routing.
EOF
    cat > .gitignore <<'EOF'
.humanize/
.cache/
bin/
mock-calls/
no-user/
EOF
    git add tracked.txt plans/plan.md .gitignore
    git -c commit.gpgsign=false commit -q -m "Initial test setup"

    BASE_COMMIT=$(git rev-parse HEAD)
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

    LOOP_DIR="$TEST_DIR/.humanize/rlcr/$LOOP_TIMESTAMP"
    mkdir -p "$LOOP_DIR"

    cp plans/plan.md "$LOOP_DIR/plan.md"
    cat > "$LOOP_DIR/goal-tracker.md" <<'EOF'
# Goal Tracker
## IMMUTABLE SECTION
### Ultimate Goal
Verify stop-hook routing.
### Acceptance Criteria
| ID | Criterion |
|----|-----------|
| AC-1 | Stop hook routes to the correct CLI |
---
## MUTABLE SECTION
#### Active Tasks
| Task | Target AC | Status | Notes |
|------|-----------|--------|-------|
| Route provider calls | AC-1 | in_progress | - |
EOF
    cat > "$LOOP_DIR/state.md" <<EOF
---
current_round: $round
max_iterations: 10
codex_model: $model
codex_effort: xhigh
loop_reviewer_effort: $reviewer_effort
codex_timeout: 120
push_every_round: false
plan_file: plans/plan.md
plan_tracked: false
start_branch: $CURRENT_BRANCH
base_branch: $CURRENT_BRANCH
base_commit: $BASE_COMMIT
review_started: $review_started
ask_codex_question: false
full_review_round: 5
session_id:
agent_teams: false
delegation_enforcement: warn
---
EOF
    cat > "$LOOP_DIR/round-${round}-summary.md" <<EOF
# Round $round Summary

Implementation status for routing test.
EOF

    export XDG_CACHE_HOME="$TEST_DIR/.cache"
    mkdir -p "$XDG_CACHE_HOME"
}

cache_dir_for_loop() {
    local project_dir="$1"
    local loop_dir="$2"
    local sanitized_project_path=""

    sanitized_project_path=$(echo "$project_dir" | sed 's/[^a-zA-Z0-9._-]/-/g' | sed 's/--*/-/g')
    echo "$project_dir/.cache/humanize/$sanitized_project_path/$(basename "$loop_dir")"
}

create_mock_codex() {
    local bin_dir="$1"

    mkdir -p "$bin_dir"
    cat > "$bin_dir/codex" <<'EOF'
#!/bin/bash
mkdir -p "$MOCK_CALL_DIR"
touch "$MOCK_CALL_DIR/codex.called"
printf '%s\n' "$PWD" > "$MOCK_CALL_DIR/codex.cwd"
printf '%s\n' "$*" > "$MOCK_CALL_DIR/codex.args"

mode="${1:-}"
if [[ "$mode" == "exec" ]]; then
    cat > "$MOCK_CALL_DIR/codex.stdin"
    if [[ -n "${MOCK_CODEX_EXEC_RESPONSE_FILE:-}" ]] && [[ -f "$MOCK_CODEX_EXEC_RESPONSE_FILE" ]]; then
        cat "$MOCK_CODEX_EXEC_RESPONSE_FILE"
    fi
    exit 0
fi

if [[ "$mode" == "review" ]]; then
    if [[ -n "${MOCK_CODEX_REVIEW_RESPONSE_FILE:-}" ]] && [[ -f "$MOCK_CODEX_REVIEW_RESPONSE_FILE" ]]; then
        cat "$MOCK_CODEX_REVIEW_RESPONSE_FILE"
    fi
    exit 0
fi

echo "Unexpected codex mode: $mode" >&2
exit 2
EOF
    chmod +x "$bin_dir/codex"
}

create_mock_claude() {
    local bin_dir="$1"

    mkdir -p "$bin_dir"
    cat > "$bin_dir/claude" <<'EOF'
#!/bin/bash
mkdir -p "$MOCK_CALL_DIR"
touch "$MOCK_CALL_DIR/claude.called"
printf '%s\n' "$PWD" > "$MOCK_CALL_DIR/claude.cwd"
printf '%s\n' "$*" > "$MOCK_CALL_DIR/claude.args"
cat > "$MOCK_CALL_DIR/claude.stdin"
if [[ -n "${MOCK_CLAUDE_RESPONSE_FILE:-}" ]] && [[ -f "$MOCK_CLAUDE_RESPONSE_FILE" ]]; then
    cat "$MOCK_CLAUDE_RESPONSE_FILE"
fi
EOF
    chmod +x "$bin_dir/claude"
}

create_stub_binary() {
    local bin_dir="$1"
    local binary_name="$2"

    mkdir -p "$bin_dir"
    cat > "$bin_dir/$binary_name" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$bin_dir/$binary_name"
}

run_stop_hook() {
    local project_dir="$1"
    local path_override="$2"

    (
        cd "$project_dir"
        export CLAUDE_PROJECT_DIR="$project_dir"
        export XDG_CONFIG_HOME="$project_dir/no-user"
        export MOCK_CALL_DIR="$project_dir/mock-calls"
        mkdir -p "$MOCK_CALL_DIR"
        PATH="$path_override" bash "$STOP_HOOK" <<<"$HOOK_INPUT"
    )
}

run_setup_skip_impl() {
    local project_dir="$1"
    local path_override="$2"
    local output_file="$3"

    (
        cd "$project_dir"
        CLAUDE_PROJECT_DIR="$project_dir" XDG_CACHE_HOME="$project_dir/.cache" PATH="$path_override" bash "$SETUP_SCRIPT" --skip-impl
    ) >"$output_file" 2>&1
}

# ========================================
# Test 1: gpt-* model routes summary review to codex exec
# ========================================
echo "--- Test 1: gpt-* model routes summary review to codex exec ---"
echo ""

setup_stop_hook_repo "gpt-5.2" "false" "1"
BIN_DIR="$TEST_DIR/bin"
create_mock_codex "$BIN_DIR"
cat > "$TEST_DIR/.cache/codex-exec-response.txt" <<'EOF'
## Review Feedback

Continue with another iteration.

CONTINUE
EOF
export MOCK_CODEX_EXEC_RESPONSE_FILE="$TEST_DIR/.cache/codex-exec-response.txt"
unset MOCK_CODEX_REVIEW_RESPONSE_FILE || true
unset MOCK_CLAUDE_RESPONSE_FILE || true

exit_code=0
stdout_file="$TEST_DIR/.cache/stdout.txt"
stderr_file="$TEST_DIR/.cache/stderr.txt"
run_stop_hook "$TEST_DIR" "$BIN_DIR:$SAFE_BASE_PATH" >"$stdout_file" 2>"$stderr_file" || exit_code=$?
CACHE_DIR="$(cache_dir_for_loop "$TEST_DIR" "$LOOP_DIR")"

if [[ $exit_code -eq 0 ]] \
    && grep -q '"decision"' "$stdout_file" \
    && [[ -f "$TEST_DIR/mock-calls/codex.called" ]] \
    && [[ ! -f "$TEST_DIR/mock-calls/claude.called" ]] \
    && grep -q "^exec " "$TEST_DIR/mock-calls/codex.args" \
    && [[ -f "$CACHE_DIR/round-1-codex-run.cmd" ]] \
    && [[ -f "$CACHE_DIR/round-1-codex-run.out" ]] \
    && [[ -f "$CACHE_DIR/round-1-codex-run.log" ]] \
    && grep -q "codex exec" "$CACHE_DIR/round-1-codex-run.cmd"; then
    pass "gpt-* model routes summary review to codex exec with codex-run.* debug files"
else
    fail "gpt-* model routes summary review to codex exec with codex-run.* debug files" "codex exec path with codex-run.* files" "exit=$exit_code"
fi

# ========================================
# Test 2: sonnet routes summary review to claude -p
# ========================================
echo ""
echo "--- Test 2: sonnet model routes summary review to claude -p ---"
echo ""

setup_stop_hook_repo "sonnet" "false" "1"
BIN_DIR="$TEST_DIR/bin"
create_mock_claude "$BIN_DIR"
cat > "$TEST_DIR/.cache/claude-response.txt" <<'EOF'
[P1] Route the setup-derived review through Claude.
EOF
export MOCK_CLAUDE_RESPONSE_FILE="$TEST_DIR/.cache/claude-response.txt"
unset MOCK_CODEX_EXEC_RESPONSE_FILE || true
unset MOCK_CODEX_REVIEW_RESPONSE_FILE || true

exit_code=0
stdout_file="$TEST_DIR/.cache/stdout.txt"
stderr_file="$TEST_DIR/.cache/stderr.txt"
run_stop_hook "$TEST_DIR" "$BIN_DIR:$SAFE_BASE_PATH" >"$stdout_file" 2>"$stderr_file" || exit_code=$?
CACHE_DIR="$(cache_dir_for_loop "$TEST_DIR" "$LOOP_DIR")"

if [[ $exit_code -eq 0 ]] \
    && grep -q '"decision"' "$stdout_file" \
    && [[ -f "$TEST_DIR/mock-calls/claude.called" ]] \
    && [[ ! -f "$TEST_DIR/mock-calls/codex.called" ]] \
    && grep -q -- "-p" "$TEST_DIR/mock-calls/claude.args" \
    && grep -q -- "--model sonnet" "$TEST_DIR/mock-calls/claude.args" \
    && grep -q -- "--output-format text" "$TEST_DIR/mock-calls/claude.args" \
    && grep -q -- "--disable-slash-commands" "$TEST_DIR/mock-calls/claude.args" \
    && grep -q -- "--effort high" "$TEST_DIR/mock-calls/claude.args" \
    && grep -qx "$TEST_DIR" "$TEST_DIR/mock-calls/claude.cwd" \
    && [[ -f "$CACHE_DIR/round-1-claude-run.cmd" ]] \
    && [[ -f "$CACHE_DIR/round-1-claude-run.out" ]] \
    && [[ -f "$CACHE_DIR/round-1-claude-run.log" ]] \
    && grep -q "claude -p" "$CACHE_DIR/round-1-claude-run.cmd"; then
    pass "sonnet routes summary review to claude -p with mapped effort and claude-run.* files"
else
    fail "sonnet routes summary review to claude -p with mapped effort and claude-run.* files" "claude -p path with mapped effort and claude-run.* files" "exit=$exit_code"
fi

# ========================================
# Test 3: review phase with sonnet uses git diff + claude -p
# ========================================
echo ""
echo "--- Test 3: review phase with sonnet uses git diff + claude -p ---"
echo ""

setup_stop_hook_repo "sonnet" "true" "0"
echo "build_finish_round=0" > "$LOOP_DIR/.review-phase-started"
echo "review change" >> "$TEST_DIR/tracked.txt"
git -C "$TEST_DIR" add tracked.txt
git -C "$TEST_DIR" -c commit.gpgsign=false commit -q -m "Change for review"

BIN_DIR="$TEST_DIR/bin"
create_mock_claude "$BIN_DIR"
create_stub_binary "$BIN_DIR" "codex"
cat > "$TEST_DIR/.cache/claude-review-response.txt" <<'EOF'
No issues found.
EOF
export MOCK_CLAUDE_RESPONSE_FILE="$TEST_DIR/.cache/claude-review-response.txt"
unset MOCK_CODEX_EXEC_RESPONSE_FILE || true
unset MOCK_CODEX_REVIEW_RESPONSE_FILE || true

exit_code=0
stdout_file="$TEST_DIR/.cache/stdout.txt"
stderr_file="$TEST_DIR/.cache/stderr.txt"
run_stop_hook "$TEST_DIR" "$BIN_DIR:$SAFE_BASE_PATH" >"$stdout_file" 2>"$stderr_file" || exit_code=$?
CACHE_DIR="$(cache_dir_for_loop "$TEST_DIR" "$LOOP_DIR")"

if [[ $exit_code -eq 0 ]] \
    && grep -q '"decision"' "$stdout_file" \
    && [[ -f "$TEST_DIR/mock-calls/claude.called" ]] \
    && [[ ! -f "$TEST_DIR/mock-calls/codex.called" ]] \
    && grep -q -- "-p" "$TEST_DIR/mock-calls/claude.args" \
    && grep -q -- "--output-format text" "$TEST_DIR/mock-calls/claude.args" \
    && grep -q -- "--disable-slash-commands" "$TEST_DIR/mock-calls/claude.args" \
    && grep -q "## Diff (" "$TEST_DIR/mock-calls/claude.stdin" \
    && grep -q "review change" "$TEST_DIR/mock-calls/claude.stdin" \
    && [[ -f "$CACHE_DIR/round-1-codex-review.cmd" ]] \
    && grep -q "claude -p" "$CACHE_DIR/round-1-codex-review.cmd" \
    && [[ -f "$LOOP_DIR/finalize-state.md" ]]; then
    pass "review phase with sonnet uses git diff + claude -p and transitions to finalize"
else
    fail "review phase with sonnet uses git diff + claude -p and transitions to finalize" "claude review path with diff prompt and finalize-state.md" "exit=$exit_code"
fi

# ========================================
# Test 4: project loop_reviewer_model routes setup-derived state to Claude
# ========================================
echo ""
echo "--- Test 4: project loop_reviewer_model routes setup-derived state to Claude ---"
echo ""

setup_test_dir
init_test_git_repo "$TEST_DIR"
mkdir -p "$TEST_DIR/.humanize"
cat > "$TEST_DIR/.humanize/config.json" <<'EOF'
{"loop_reviewer_model":"sonnet"}
EOF
cat > "$TEST_DIR/.gitignore" <<'EOF'
.humanize/
.cache/
bin/
mock-calls/
no-user/
EOF
git -C "$TEST_DIR" add .gitignore
git -C "$TEST_DIR" -c commit.gpgsign=false commit -q -m "Ignore test artifacts"
mkdir -p "$TEST_DIR/.cache"
BIN_DIR="$TEST_DIR/bin"
create_stub_binary "$BIN_DIR" "codex"
create_mock_claude "$BIN_DIR"
if run_setup_skip_impl "$TEST_DIR" "$BIN_DIR:$SAFE_BASE_PATH" "$TEST_DIR/.cache/setup.out"; then
    pass "setup-rlcr-loop succeeds with project loop_reviewer_model for stop-hook routing"
else
    fail "setup-rlcr-loop succeeds with project loop_reviewer_model for stop-hook routing" "exit 0" "$(cat "$TEST_DIR/.cache/setup.out" 2>/dev/null || true)"
fi

LOOP_DIR="$(find "$TEST_DIR/.humanize/rlcr" -mindepth 1 -maxdepth 1 -type d | head -1)"
STATE_FILE="$LOOP_DIR/state.md"
if [[ -f "$STATE_FILE" ]] && grep -q "^codex_model: sonnet$" "$STATE_FILE"; then
    pass "setup-derived state records codex_model: sonnet from loop_reviewer_model"
else
    fail "setup-derived state records codex_model: sonnet from loop_reviewer_model" "codex_model: sonnet" "$(grep '^codex_model:' "$STATE_FILE" 2>/dev/null || echo missing)"
fi
cat > "$LOOP_DIR/round-0-summary.md" <<'EOF'
# Review Round 0 Summary

## Work Completed
- Prepared setup-derived routing test state.

## Files Changed
- file.txt

## Validation
- Pending stop-hook review routing validation.

## Remaining Items
- Confirm Claude is selected from loop_reviewer_model.

## BitLesson Delta
- Action: none
- Lesson ID(s): NONE
- Notes: No bitlesson update for routing fixture.
EOF
echo "build_finish_round=0" > "$LOOP_DIR/.review-phase-started"
echo "config-driven review change" >> "$TEST_DIR/file.txt"
git -C "$TEST_DIR" add file.txt
git -C "$TEST_DIR" -c commit.gpgsign=false commit -q -m "Change for config-driven review"
cat > "$TEST_DIR/.cache/claude-response.txt" <<'EOF'
[P1] Route the setup-derived review through Claude.
EOF
export MOCK_CLAUDE_RESPONSE_FILE="$TEST_DIR/.cache/claude-response.txt"
unset MOCK_CODEX_EXEC_RESPONSE_FILE || true
unset MOCK_CODEX_REVIEW_RESPONSE_FILE || true

exit_code=0
stdout_file="$TEST_DIR/.cache/stdout.txt"
stderr_file="$TEST_DIR/.cache/stderr.txt"
run_stop_hook "$TEST_DIR" "$BIN_DIR:$SAFE_BASE_PATH" >"$stdout_file" 2>"$stderr_file" || exit_code=$?
CACHE_DIR="$(cache_dir_for_loop "$TEST_DIR" "$LOOP_DIR")"

if [[ $exit_code -eq 0 ]] \
    && grep -q '"decision"' "$stdout_file" \
    && [[ -f "$TEST_DIR/mock-calls/claude.called" ]] \
    && grep -q -- "--model sonnet" "$TEST_DIR/mock-calls/claude.args"; then
    pass "project loop_reviewer_model=sonnet produces state codex_model: sonnet and routes stop hook to Claude"
else
    fail "project loop_reviewer_model=sonnet produces state codex_model: sonnet and routes stop hook to Claude" "setup-derived state uses sonnet/Claude" "exit=$exit_code, stdout=$(cat "$stdout_file" 2>/dev/null || true)"
fi

# ========================================
# Test 5: summary review prefers loop_reviewer_effort from state
# ========================================
echo ""
echo "--- Test 5: summary review uses loop_reviewer_effort from state ---"
echo ""

setup_stop_hook_repo "sonnet" "false" "1" "medium"
BIN_DIR="$TEST_DIR/bin"
create_mock_claude "$BIN_DIR"
cat > "$TEST_DIR/.cache/claude-medium-response.txt" <<'EOF'
[P1] Keep iterating after the medium-effort summary review.
EOF
export MOCK_CLAUDE_RESPONSE_FILE="$TEST_DIR/.cache/claude-medium-response.txt"
unset MOCK_CODEX_EXEC_RESPONSE_FILE || true
unset MOCK_CODEX_REVIEW_RESPONSE_FILE || true

exit_code=0
stdout_file="$TEST_DIR/.cache/stdout.txt"
stderr_file="$TEST_DIR/.cache/stderr.txt"
run_stop_hook "$TEST_DIR" "$BIN_DIR:$SAFE_BASE_PATH" >"$stdout_file" 2>"$stderr_file" || exit_code=$?

if [[ $exit_code -eq 0 ]] \
    && grep -q '"decision"' "$stdout_file" \
    && [[ -f "$TEST_DIR/mock-calls/claude.called" ]] \
    && [[ ! -f "$TEST_DIR/mock-calls/codex.called" ]] \
    && grep -q -- "--model sonnet" "$TEST_DIR/mock-calls/claude.args" \
    && grep -q -- "--effort medium" "$TEST_DIR/mock-calls/claude.args" \
    && ! grep -q -- "--effort high" "$TEST_DIR/mock-calls/claude.args"; then
    pass "summary review uses loop_reviewer_effort from state for Claude effort"
else
    fail "summary review uses loop_reviewer_effort from state for Claude effort" "--effort medium without --effort high" "exit=$exit_code, args=$(cat "$TEST_DIR/mock-calls/claude.args" 2>/dev/null || echo missing)"
fi

# ========================================
# Test 6: invalid base commit blocks review instead of advancing to finalize
# ========================================
echo ""
echo "--- Test 6: invalid base commit blocks review instead of advancing ---"
echo ""

setup_stop_hook_repo "sonnet" "true" "0"
sed -i.bak 's/^base_commit: .*/base_commit: deadbeef000000000000000000000000deadbeef/' "$LOOP_DIR/state.md"
rm -f "$LOOP_DIR/state.md.bak"
echo "build_finish_round=0" > "$LOOP_DIR/.review-phase-started"
echo "review change" >> "$TEST_DIR/tracked.txt"
git -C "$TEST_DIR" add tracked.txt
git -C "$TEST_DIR" -c commit.gpgsign=false commit -q -m "Change for invalid base review"

BIN_DIR="$TEST_DIR/bin"
create_mock_claude "$BIN_DIR"
create_stub_binary "$BIN_DIR" "codex"
unset MOCK_CLAUDE_RESPONSE_FILE || true
unset MOCK_CODEX_EXEC_RESPONSE_FILE || true
unset MOCK_CODEX_REVIEW_RESPONSE_FILE || true

exit_code=0
stdout_file="$TEST_DIR/.cache/stdout.txt"
stderr_file="$TEST_DIR/.cache/stderr.txt"
run_stop_hook "$TEST_DIR" "$BIN_DIR:$SAFE_BASE_PATH" >"$stdout_file" 2>"$stderr_file" || exit_code=$?
CACHE_DIR="$(cache_dir_for_loop "$TEST_DIR" "$LOOP_DIR")"

if [[ $exit_code -eq 0 ]] \
    && grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' "$stdout_file" \
    && grep -q "Codex review failed" "$stdout_file" \
    && grep -q "git diff failed" "$stdout_file" \
    && [[ ! -f "$LOOP_DIR/finalize-state.md" ]] \
    && [[ -f "$CACHE_DIR/round-1-codex-review.log" ]] \
    && grep -q "git diff failed" "$CACHE_DIR/round-1-codex-review.log"; then
    pass "invalid base commit blocks review when Claude git diff fails"
else
    fail "invalid base commit blocks review when Claude git diff fails" "decision:block without finalize-state.md" "exit=$exit_code, stdout=$(cat "$stdout_file" 2>/dev/null || true)"
fi

# ========================================
# Test 7: provider dependency check blocks missing claude even if codex exists
# ========================================
echo ""
echo "--- Test 7: missing claude CLI blocks before review execution ---"
echo ""

setup_stop_hook_repo "sonnet" "false" "1"
BIN_DIR="$TEST_DIR/bin"
create_stub_binary "$BIN_DIR" "codex"

exit_code=0
stdout_file="$TEST_DIR/.cache/stdout.txt"
stderr_file="$TEST_DIR/.cache/stderr.txt"
run_stop_hook "$TEST_DIR" "$BIN_DIR:$SAFE_BASE_PATH" >"$stdout_file" 2>"$stderr_file" || exit_code=$?

if [[ $exit_code -eq 0 ]] \
    && grep -q '"decision"[[:space:]]*:[[:space:]]*"block"' "$stdout_file" \
    && grep -q "Provider CLI Not Found" "$stdout_file" \
    && grep -q "claude" "$stdout_file"; then
    pass "provider dependency check blocks when claude is missing even if codex is present"
else
    fail "provider dependency check blocks when claude is missing even if codex is present" "JSON block mentioning missing claude CLI" "exit=$exit_code, stdout=$(cat "$stdout_file")"
fi

# ========================================
# Test 8: config-driven loop_reviewer_effort flows end-to-end to summary-review CLI args
# ========================================
echo ""
echo "--- Test 8: config-driven loop_reviewer_effort flows end-to-end ---"
echo ""

setup_test_dir
init_test_git_repo "$TEST_DIR"
mkdir -p "$TEST_DIR/.humanize"
cat > "$TEST_DIR/.humanize/config.json" <<'EOF'
{"loop_reviewer_model":"sonnet","loop_reviewer_effort":"medium"}
EOF
cat > "$TEST_DIR/.gitignore" <<'EOF'
.humanize/
.cache/
bin/
mock-calls/
no-user/
EOF
git -C "$TEST_DIR" add .gitignore
git -C "$TEST_DIR" -c commit.gpgsign=false commit -q -m "Ignore test artifacts"
mkdir -p "$TEST_DIR/.cache"
BIN_DIR="$TEST_DIR/bin"
create_stub_binary "$BIN_DIR" "codex"
create_mock_claude "$BIN_DIR"
if run_setup_skip_impl "$TEST_DIR" "$BIN_DIR:$SAFE_BASE_PATH" "$TEST_DIR/.cache/setup.out"; then
    pass "setup-rlcr-loop succeeds with config-driven loop_reviewer_effort"
else
    fail "setup-rlcr-loop succeeds with config-driven loop_reviewer_effort" "exit 0" "$(cat "$TEST_DIR/.cache/setup.out" 2>/dev/null || true)"
fi

LOOP_DIR="$(find "$TEST_DIR/.humanize/rlcr" -mindepth 1 -maxdepth 1 -type d | head -1)"
STATE_FILE="$LOOP_DIR/state.md"
if [[ -f "$STATE_FILE" ]] \
    && grep -q "^loop_reviewer_effort: medium$" "$STATE_FILE" \
    && grep -q "^codex_effort: medium$" "$STATE_FILE"; then
    pass "state.md records both loop_reviewer_effort and codex_effort as medium from config"
else
    fail "state.md records both loop_reviewer_effort and codex_effort as medium from config" "both effort fields = medium" "$(grep -E '^(codex_effort|loop_reviewer_effort):' "$STATE_FILE" 2>/dev/null || echo missing)"
fi

# Advance state to round 1 with review_started=false to trigger summary review path
sed -i 's/^current_round: 0$/current_round: 1/;s/^review_started: true$/review_started: false/' "$STATE_FILE"

cat > "$LOOP_DIR/round-1-summary.md" <<'EOF'
# Round 1 Summary

Config-driven effort routing test fixture.

## BitLesson Delta
- Action: none
- Lesson ID(s): NONE
- Notes: Config-driven effort test fixture.
EOF
cat > "$TEST_DIR/.cache/claude-e2e-response.txt" <<'EOF'
[P1] Config-driven effort medium summary review response.
EOF
export MOCK_CLAUDE_RESPONSE_FILE="$TEST_DIR/.cache/claude-e2e-response.txt"
unset MOCK_CODEX_EXEC_RESPONSE_FILE || true
unset MOCK_CODEX_REVIEW_RESPONSE_FILE || true

exit_code=0
stdout_file="$TEST_DIR/.cache/stdout.txt"
stderr_file="$TEST_DIR/.cache/stderr.txt"
run_stop_hook "$TEST_DIR" "$BIN_DIR:$SAFE_BASE_PATH" >"$stdout_file" 2>"$stderr_file" || exit_code=$?

if [[ $exit_code -eq 0 ]] \
    && grep -q '"decision"' "$stdout_file" \
    && [[ -f "$TEST_DIR/mock-calls/claude.called" ]] \
    && [[ ! -f "$TEST_DIR/mock-calls/codex.called" ]] \
    && grep -q -- "--model sonnet" "$TEST_DIR/mock-calls/claude.args" \
    && grep -q -- "--effort medium" "$TEST_DIR/mock-calls/claude.args" \
    && ! grep -q -- "--effort high" "$TEST_DIR/mock-calls/claude.args"; then
    pass "config-driven loop_reviewer_effort=medium flows to summary-review --effort medium"
else
    fail "config-driven loop_reviewer_effort=medium flows to summary-review --effort medium" "--model sonnet --effort medium" "exit=$exit_code, args=$(cat "$TEST_DIR/mock-calls/claude.args" 2>/dev/null || echo missing)"
fi

print_test_summary "Stop Hook Routing Test Summary"
