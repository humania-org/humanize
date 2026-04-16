#!/usr/bin/env bash
#
# Tests for rlcr-stop-gate wrapper project root detection
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

GATE_SCRIPT="$SCRIPT_DIR/../scripts/rlcr-stop-gate.sh"

echo "=========================================="
echo "RLCR Stop Gate Wrapper Tests"
echo "=========================================="
echo ""

# Build a minimal active loop that should block on missing summary file.
setup_active_loop_fixture() {
    local project_dir="$1"

    init_test_git_repo "$project_dir"
    local branch
    branch=$(git -C "$project_dir" rev-parse --abbrev-ref HEAD)

    mkdir -p "$project_dir/.humanize/rlcr/2026-03-01_00-00-00"

    cat > "$project_dir/plan.md" << 'PLANEOF'
# Test Plan

Line 1
Line 2
Line 3
Line 4
PLANEOF

    cp "$project_dir/plan.md" "$project_dir/.humanize/rlcr/2026-03-01_00-00-00/plan.md"

    cat > "$project_dir/.humanize/rlcr/2026-03-01_00-00-00/state.md" <<EOF_STATE
---
current_round: 0
max_iterations: 42
codex_model: gpt-5.4
codex_effort: high
codex_timeout: 60
push_every_round: false
full_review_round: 5
plan_file: plan.md
plan_tracked: false
start_branch: $branch
base_branch: $branch
base_commit: deadbeef
review_started: false
ask_codex_question: true
session_id:
agent_teams: false
---
EOF_STATE
}

# Single setup_test_dir call to avoid EXIT trap overwrite and temp dir leak.
setup_test_dir

# Test 1: Default project root should be caller cwd (not plugin install dir)
T1_DIR="$TEST_DIR/t1"
mkdir -p "$T1_DIR"
setup_active_loop_fixture "$T1_DIR/project"

set +e
(
    cd "$T1_DIR/project"
    "$GATE_SCRIPT"
) > "$T1_DIR/out.txt" 2>&1
EXIT1=$?
set -e

if [[ "$EXIT1" -eq 10 ]]; then
    pass "rlcr-stop-gate default project root uses cwd and blocks active loop"
else
    OUTPUT1=$(cat "$T1_DIR/out.txt" 2>/dev/null || true)
    fail "rlcr-stop-gate default project root uses cwd and blocks active loop" "exit 10" "exit $EXIT1; output: $OUTPUT1"
fi

if grep -q "^BLOCK:" "$T1_DIR/out.txt" 2>/dev/null; then
    pass "rlcr-stop-gate reports a real loop blocking reason"
else
    OUTPUT1=$(cat "$T1_DIR/out.txt" 2>/dev/null || true)
    fail "rlcr-stop-gate reports a real loop blocking reason" "output containing BLOCK:" "$OUTPUT1"
fi

# Test 2: --project-root override works from outside target repository
T2_DIR="$TEST_DIR/t2"
mkdir -p "$T2_DIR"
setup_active_loop_fixture "$T2_DIR/project"

set +e
(
    cd "$T2_DIR"
    "$GATE_SCRIPT" --project-root "$T2_DIR/project"
) > "$T2_DIR/out.txt" 2>&1
EXIT2=$?
set -e

if [[ "$EXIT2" -eq 10 ]]; then
    pass "rlcr-stop-gate --project-root override blocks using target repo loop"
else
    OUTPUT2=$(cat "$T2_DIR/out.txt" 2>/dev/null || true)
    fail "rlcr-stop-gate --project-root override blocks using target repo loop" "exit 10" "exit $EXIT2; output: $OUTPUT2"
fi

if grep -q "^BLOCK:" "$T2_DIR/out.txt" 2>/dev/null; then
    pass "rlcr-stop-gate --project-root output contains expected block reason"
else
    OUTPUT2=$(cat "$T2_DIR/out.txt" 2>/dev/null || true)
    fail "rlcr-stop-gate --project-root output contains expected block reason" "output containing BLOCK:" "$OUTPUT2"
fi

# Test 3: Tracked Humanize state blocks before normal loop validation
T3_DIR="$TEST_DIR/t3"
mkdir -p "$T3_DIR"
setup_active_loop_fixture "$T3_DIR/project"
echo "tracked" > "$T3_DIR/project/.humanize/rlcr/2026-03-01_00-00-00/goal-tracker.md"
git -C "$T3_DIR/project" add -f .humanize/rlcr/2026-03-01_00-00-00/goal-tracker.md

set +e
(
    cd "$T3_DIR/project"
    "$GATE_SCRIPT"
) > "$T3_DIR/out.txt" 2>&1
EXIT3=$?
set -e

if [[ "$EXIT3" -eq 10 ]]; then
    pass "rlcr-stop-gate blocks tracked Humanize state"
else
    OUTPUT3=$(cat "$T3_DIR/out.txt" 2>/dev/null || true)
    fail "rlcr-stop-gate blocks tracked Humanize state" "exit 10" "exit $EXIT3; output: $OUTPUT3"
fi

if grep -q "Tracked Humanize State Blocked" "$T3_DIR/out.txt" 2>/dev/null; then
    pass "rlcr-stop-gate reports tracked Humanize state with dedicated reason"
else
    OUTPUT3=$(cat "$T3_DIR/out.txt" 2>/dev/null || true)
    fail "rlcr-stop-gate reports tracked Humanize state with dedicated reason" "output containing Tracked Humanize State Blocked" "$OUTPUT3"
fi

# Test 4: Unrelated dot-prefixed files that happen to start with .humanize-
# must not be treated as loop state. .humanize-backup and .humanizeconfig are
# explicitly allowed by the git add validator (tests/test-humanize-escape.sh);
# the tracked-state guard must stay consistent and ignore them.
T4_DIR="$TEST_DIR/t4"
mkdir -p "$T4_DIR"
setup_active_loop_fixture "$T4_DIR/project"
echo "not loop state" > "$T4_DIR/project/.humanize-backup"
echo "not loop state" > "$T4_DIR/project/.humanizeconfig"
git -C "$T4_DIR/project" add -f .humanize-backup .humanizeconfig

set +e
(
    cd "$T4_DIR/project"
    "$GATE_SCRIPT"
) > "$T4_DIR/out.txt" 2>&1
EXIT4=$?
set -e

if [[ "$EXIT4" -eq 10 ]]; then
    pass "rlcr-stop-gate does not confuse .humanize-backup with loop state"
else
    OUTPUT4=$(cat "$T4_DIR/out.txt" 2>/dev/null || true)
    fail "rlcr-stop-gate does not confuse .humanize-backup with loop state" "exit 10" "exit $EXIT4; output: $OUTPUT4"
fi

if ! grep -q "Tracked Humanize State Blocked" "$T4_DIR/out.txt" 2>/dev/null; then
    pass "rlcr-stop-gate does not emit tracked-state reason for .humanize-backup"
else
    OUTPUT4=$(cat "$T4_DIR/out.txt" 2>/dev/null || true)
    fail "rlcr-stop-gate does not emit tracked-state reason for .humanize-backup" "no Tracked Humanize State Blocked line" "$OUTPUT4"
fi

# Test 5: No active loop -> gate allows exit (exit 0)
T5_DIR="$TEST_DIR/t5"
mkdir -p "$T5_DIR/empty-project"

set +e
(
    cd "$T5_DIR/empty-project"
    "$GATE_SCRIPT"
) > "$T5_DIR/out.txt" 2>&1
EXIT5=$?
set -e

if [[ "$EXIT5" -eq 0 ]]; then
    pass "rlcr-stop-gate exits 0 when no active loop exists"
else
    OUTPUT5=$(cat "$T5_DIR/out.txt" 2>/dev/null || true)
    fail "rlcr-stop-gate exits 0 when no active loop exists" "exit 0" "exit $EXIT5; output: $OUTPUT5"
fi

if grep -q "^ALLOW:" "$T5_DIR/out.txt" 2>/dev/null; then
    pass "rlcr-stop-gate reports ALLOW when no active loop"
else
    OUTPUT5=$(cat "$T5_DIR/out.txt" 2>/dev/null || true)
    fail "rlcr-stop-gate reports ALLOW when no active loop" "output containing ALLOW:" "$OUTPUT5"
fi

print_test_summary "RLCR Stop Gate Wrapper Test Summary"
exit $?
