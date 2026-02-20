#!/bin/bash
#
# Tests for _humanize_monitor_skill (humanize monitor skill)
#
# Tests the --once mode output and helper functions for the skill monitor.
# Interactive mode is not tested here (requires terminal).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    ((TESTS_PASSED++))
    ((TESTS_RUN++))
    echo "  PASS: $1"
}

fail() {
    ((TESTS_FAILED++))
    ((TESTS_RUN++))
    echo "  FAIL: $1"
    [[ -n "${2:-}" ]] && echo "        $2"
}

# ========================================
# Test Environment Setup
# ========================================

TEST_DIR=$(mktemp -d)
cleanup() {
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Setup a mock git repo and skill invocations
setup_test_env() {
    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_DIR"
    cd "$TEST_DIR"

    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    touch dummy && git add dummy && git commit -q -m "init"

    # Source humanize.sh (which sources monitor-common.sh and monitor-skill.sh)
    source "$PROJECT_ROOT/scripts/humanize.sh"
}

# Create a completed skill invocation directory
# Usage: create_skill_invocation <unique_id> <status> <model> <effort> <duration> <question>
create_skill_invocation() {
    local unique_id="$1"
    local status="$2"
    local model="${3:-gpt-5.3-codex}"
    local effort="${4:-xhigh}"
    local duration="${5:-15s}"
    local question="${6:-How should I structure this?}"

    local dir=".humanize/skill/$unique_id"
    mkdir -p "$dir"

    # Create input.md
    cat > "$dir/input.md" << EOF
# Ask Codex Input

## Question

$question

## Configuration

- Model: $model
- Effort: $effort
- Timeout: 600s
- Timestamp: $(echo "$unique_id" | cut -d- -f1-3 | tr '_' ' ')
EOF

    # Create metadata.md (unless status is "running")
    if [[ "$status" != "running" ]]; then
        cat > "$dir/metadata.md" << EOF
---
model: $model
effort: $effort
timeout: 600
exit_code: $( [[ "$status" == "success" ]] && echo 0 || echo 1 )
duration: $duration
status: $status
started_at: 2026-02-19T21:02:35Z
---
EOF
    fi

    # Create output.md for successful invocations
    if [[ "$status" == "success" ]]; then
        echo "This is the response from the model." > "$dir/output.md"
    fi
}

# ========================================
# Tests: Directory not found
# ========================================

echo "=== Skill Monitor: Directory Checks ==="

setup_test_env
output=$(_humanize_monitor_skill --once 2>&1) && rc=0 || rc=$?
if [[ $rc -ne 0 ]] && echo "$output" | grep -q "directory not found"; then
    pass "Returns error when .humanize/skill does not exist"
else
    fail "Should error when skill dir missing" "got: $output"
fi

# ========================================
# Tests: Empty skill directory
# ========================================

echo "=== Skill Monitor: Empty Directory ==="

setup_test_env
mkdir -p .humanize/skill
output=$(_humanize_monitor_skill --once 2>&1) && rc=0 || rc=$?
if [[ $rc -ne 0 ]] && echo "$output" | grep -q "No skill invocations found"; then
    pass "Returns error when no invocations exist"
else
    fail "Should error when no invocations" "got: $output"
fi

# ========================================
# Tests: Single completed invocation
# ========================================

echo "=== Skill Monitor: Single Invocation ==="

setup_test_env
mkdir -p .humanize/skill
create_skill_invocation "2026-02-19_21-02-35-12345-abc123" "success" "gpt-5.3-codex" "xhigh" "15s" "How should I structure the auth module?"

output=$(_humanize_monitor_skill --once 2>&1) && rc=0 || rc=$?
if [[ $rc -eq 0 ]]; then
    pass "--once mode exits successfully with one invocation"
else
    fail "--once mode should succeed" "exit code: $rc"
fi

if echo "$output" | grep -q "Total Invocations: 1"; then
    pass "Shows total invocation count"
else
    fail "Should show total count" "got: $output"
fi

if echo "$output" | grep -q "Success: 1"; then
    pass "Shows success count"
else
    fail "Should show success count" "got: $output"
fi

if echo "$output" | grep -q "success"; then
    pass "Shows success status for focused invocation"
else
    fail "Should show success status" "got: $output"
fi

if echo "$output" | grep -q "gpt-5.3-codex"; then
    pass "Shows model name"
else
    fail "Should show model" "got: $output"
fi

if echo "$output" | grep -q "15s"; then
    pass "Shows duration"
else
    fail "Should show duration" "got: $output"
fi

if echo "$output" | grep -q "How should I structure the auth module"; then
    pass "Shows question text"
else
    fail "Should show question" "got: $output"
fi

if echo "$output" | grep -q "This is the response"; then
    pass "Shows output content"
else
    fail "Should show output" "got: $output"
fi

# ========================================
# Tests: Multiple invocations with mixed statuses
# ========================================

echo "=== Skill Monitor: Multiple Invocations ==="

setup_test_env
mkdir -p .humanize/skill
create_skill_invocation "2026-02-19_20-00-00-111-aaa" "success" "gpt-5.3-codex" "high" "10s" "First question"
create_skill_invocation "2026-02-19_20-30-00-222-bbb" "error" "gpt-5.3-codex" "xhigh" "5s" "Second question"
create_skill_invocation "2026-02-19_21-00-00-333-ccc" "timeout" "gpt-5.3-codex" "xhigh" "600s" "Third question"
create_skill_invocation "2026-02-19_21-30-00-444-ddd" "success" "gpt-5.3-codex" "xhigh" "20s" "Latest question"

output=$(_humanize_monitor_skill --once 2>&1) && rc=0 || rc=$?
if echo "$output" | grep -q "Total Invocations: 4"; then
    pass "Counts all invocations"
else
    fail "Should count all invocations" "got: $(echo "$output" | grep 'Total')"
fi

if echo "$output" | grep -q "Success: 2"; then
    pass "Counts success invocations"
else
    fail "Should count 2 successes" "got: $(echo "$output" | grep 'Success')"
fi

if echo "$output" | grep -q "Error: 1"; then
    pass "Counts error invocations"
else
    fail "Should count 1 error" "got: $(echo "$output" | grep 'Error')"
fi

if echo "$output" | grep -q "Timeout: 1"; then
    pass "Counts timeout invocations"
else
    fail "Should count 1 timeout" "got: $(echo "$output" | grep 'Timeout')"
fi

# Latest should be the newest (2026-02-19_21-30-00)
if echo "$output" | grep "Focused:" | grep -q "2026-02-19_21-30-00"; then
    pass "Shows the most recent invocation with content as focused"
else
    fail "Should show newest with content as focused" "got: $(echo "$output" | grep 'Focused:')"
fi

if echo "$output" | grep -q "Latest question"; then
    pass "Shows question from latest invocation"
else
    fail "Should show latest question" "got: $output"
fi

# ========================================
# Tests: Running invocation (no metadata.md)
# ========================================

echo "=== Skill Monitor: Running Invocation ==="

setup_test_env
mkdir -p .humanize/skill
create_skill_invocation "2026-02-19_21-00-00-111-aaa" "success" "gpt-5.3-codex" "xhigh" "10s" "Completed question"
create_skill_invocation "2026-02-19_21-30-00-222-bbb" "running" "gpt-5.3-codex" "high" "" "Running question"

output=$(_humanize_monitor_skill --once 2>&1) && rc=0 || rc=$?
if echo "$output" | grep -q "Running: 1"; then
    pass "Counts running invocations"
else
    fail "Should count 1 running" "got: $(echo "$output" | grep 'Running')"
fi

if echo "$output" | grep -q "running"; then
    pass "Shows running status for focused invocation"
else
    fail "Should show running status" "got: $output"
fi

# ========================================
# Tests: Recent invocations list
# ========================================

echo "=== Skill Monitor: Recent Invocations List ==="

setup_test_env
mkdir -p .humanize/skill
create_skill_invocation "2026-02-19_20-00-00-111-aaa" "success" "gpt-5.3-codex" "xhigh" "10s" "Question one"
create_skill_invocation "2026-02-19_20-30-00-222-bbb" "error" "gpt-5.3-codex" "xhigh" "5s" "Question two"
create_skill_invocation "2026-02-19_21-00-00-333-ccc" "success" "gpt-5.3-codex" "xhigh" "20s" "Question three"

output=$(_humanize_monitor_skill --once 2>&1) && rc=0 || rc=$?
if echo "$output" | grep -q "Recent Invocations"; then
    pass "Shows recent invocations section"
else
    fail "Should show recent section" "got: $output"
fi

# Check that invocations appear in the output
if echo "$output" | grep -q "2026-02-19_21-00-00-333-ccc"; then
    pass "Lists invocations in recent section"
else
    fail "Should list invocations" "got: $(echo "$output" | grep '2026-02-19')"
fi

# ========================================
# Tests: Question extraction from input.md
# ========================================

echo "=== Skill Monitor: Question Extraction ==="

setup_test_env
mkdir -p .humanize/skill
# Create an invocation with a multi-line question (only first line should be extracted)
local_dir=".humanize/skill/2026-02-19_22-00-00-555-eee"
mkdir -p "$local_dir"
cat > "$local_dir/input.md" << 'EOF'
# Ask Codex Input

## Question

What are the performance bottlenecks in the API layer?

Additional context about the question.

## Configuration

- Model: gpt-5.3-codex
- Effort: xhigh
- Timeout: 600s
EOF
cat > "$local_dir/metadata.md" << 'EOF'
---
model: gpt-5.3-codex
effort: xhigh
timeout: 600
exit_code: 0
duration: 25s
status: success
started_at: 2026-02-19T22:00:00Z
---
EOF
echo "Performance analysis result" > "$local_dir/output.md"

output=$(_humanize_monitor_skill --once 2>&1) && rc=0 || rc=$?
if echo "$output" | grep -q "What are the performance bottlenecks"; then
    pass "Extracts first line of question"
else
    fail "Should extract question first line" "got: $output"
fi

# Should NOT contain the second line
if ! echo "$output" | grep -q "Additional context"; then
    pass "Does not include subsequent lines from question"
else
    fail "Should only show first line" "got: $output"
fi

# ========================================
# Tests: Empty response invocation
# ========================================

echo "=== Skill Monitor: Empty Response ==="

setup_test_env
mkdir -p .humanize/skill
create_skill_invocation "2026-02-19_21-00-00-111-aaa" "empty_response" "gpt-5.3-codex" "xhigh" "30s" "Why is the sky blue?"

output=$(_humanize_monitor_skill --once 2>&1) && rc=0 || rc=$?
if echo "$output" | grep -q "Empty: 1"; then
    pass "Counts empty response invocations"
else
    fail "Should count 1 empty" "got: $(echo "$output" | grep 'Empty')"
fi

if echo "$output" | grep -q "No output available"; then
    pass "Shows no output message for empty response"
else
    fail "Should show no output message" "got: $output"
fi

# ========================================
# Tests: Non-skill directories are ignored
# ========================================

echo "=== Skill Monitor: Non-skill Dir Filtering ==="

setup_test_env
mkdir -p .humanize/skill
create_skill_invocation "2026-02-19_21-00-00-111-aaa" "success" "gpt-5.3-codex" "xhigh" "10s" "Real question"
# Create a non-matching directory
mkdir -p ".humanize/skill/not-a-skill-dir"
echo "junk" > ".humanize/skill/not-a-skill-dir/input.md"

output=$(_humanize_monitor_skill --once 2>&1) && rc=0 || rc=$?
if echo "$output" | grep -q "Total Invocations: 1"; then
    pass "Ignores non-timestamp directories"
else
    fail "Should only count valid skill dirs" "got: $(echo "$output" | grep 'Total')"
fi

# ========================================
# Summary
# ========================================

echo ""
echo "=========================================="
echo "  Passed: $TESTS_PASSED"
echo "  Failed: $TESTS_FAILED"
echo "=========================================="

if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
fi
exit 0
