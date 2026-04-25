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
codex_model: gpt-5.5
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

# Test 6: Empty session_id must NOT drop transcript_path from the hook
# input JSON (regression: a `select(length > 0)` used as a plain object
# value would collapse the whole enclosing object to empty whenever any
# selected field was empty, wiping forwarded fields like transcript_path
# even though only session_id was missing). The fix replaces the plain
# select with explicit if/then/else so each field independently becomes
# null on empty input.
T6_DIR="$TEST_DIR/t6"
mkdir -p "$T6_DIR/bin"

# Mock hook that echoes the raw stdin it received, so we can inspect the
# JSON rlcr-stop-gate.sh builds without depending on the real hook's
# pending-bg logic.
cat > "$T6_DIR/bin/loop-codex-stop-hook.sh" <<'MOCK_HOOK_EOF'
#!/usr/bin/env bash
set -euo pipefail
INPUT="$(cat)"
# Emit a JSON block so the gate wrapper walks the non-"allow on empty"
# branch. We set decision:"block" AND include a recognizable reason the
# test can grep for.
printf '%s\n' "$INPUT" > "${MOCK_HOOK_INPUT_LOG:-/dev/null}"
printf '%s\n' '{"decision":"block","reason":"mock-hook","systemMessage":"mock"}'
MOCK_HOOK_EOF
chmod +x "$T6_DIR/bin/loop-codex-stop-hook.sh"

# Layout expected by rlcr-stop-gate.sh: HUMANIZE_ROOT/hooks/loop-codex-stop-hook.sh.
# We stage a fake plugin root pointing at the mock hook and copy the gate
# wrapper next to it so the relative resolution resolves to the mock.
mkdir -p "$T6_DIR/plugin/scripts" "$T6_DIR/plugin/hooks/lib"
cp "$T6_DIR/bin/loop-codex-stop-hook.sh" "$T6_DIR/plugin/hooks/loop-codex-stop-hook.sh"
cp "$GATE_SCRIPT" "$T6_DIR/plugin/scripts/rlcr-stop-gate.sh"
# rlcr-stop-gate sources hooks/lib/project-root.sh for PROJECT_ROOT resolution.
REAL_PROJECT_ROOT_LIB="$(dirname "$GATE_SCRIPT")/../hooks/lib/project-root.sh"
cp "$REAL_PROJECT_ROOT_LIB" "$T6_DIR/plugin/hooks/lib/project-root.sh"
chmod +x "$T6_DIR/plugin/scripts/rlcr-stop-gate.sh"

T6_INPUT_LOG="$T6_DIR/hook-input.json"
T6_TRANSCRIPT="$T6_DIR/fake-transcript.jsonl"
: > "$T6_TRANSCRIPT"

set +e
(
    cd "$T6_DIR"
    # Pin CLAUDE_PROJECT_DIR so rlcr-stop-gate resolves a root even though
    # the fixture is not a git repo. This test exercises the JSON-object-
    # collapse regression for empty session_id; project-root resolution is
    # orthogonal and must not short-circuit the gate with an ALLOW.
    CLAUDE_PROJECT_DIR="$T6_DIR" \
    MOCK_HOOK_INPUT_LOG="$T6_INPUT_LOG" \
    "$T6_DIR/plugin/scripts/rlcr-stop-gate.sh" \
        --transcript-path "$T6_TRANSCRIPT" \
        --json
) > "$T6_DIR/out.txt" 2>&1
EXIT6=$?
set -e

if [[ ! -f "$T6_INPUT_LOG" ]]; then
    fail "rlcr-stop-gate forwards transcript_path when session_id is empty" \
        "mock hook to capture hook input JSON" \
        "captured input log missing; gate output: $(cat "$T6_DIR/out.txt" 2>/dev/null || true)"
else
    T6_TRANSCRIPT_SEEN=$(jq -r '.transcript_path // "__MISSING__"' "$T6_INPUT_LOG" 2>/dev/null || echo "__PARSE_ERROR__")
    T6_SESSION_SEEN=$(jq -r '.session_id | if . == null then "__NULL__" else . end' "$T6_INPUT_LOG" 2>/dev/null || echo "__PARSE_ERROR__")
    if [[ "$T6_TRANSCRIPT_SEEN" == "$T6_TRANSCRIPT" ]] && [[ "$T6_SESSION_SEEN" == "__NULL__" ]]; then
        pass "rlcr-stop-gate forwards transcript_path when session_id is empty (jq object-collapse fix)"
    else
        fail "rlcr-stop-gate forwards transcript_path when session_id is empty (jq object-collapse fix)" \
            "transcript_path=$T6_TRANSCRIPT, session_id=__NULL__" \
            "transcript_path=$T6_TRANSCRIPT_SEEN, session_id=$T6_SESSION_SEEN; raw: $(cat "$T6_INPUT_LOG" 2>/dev/null || true)"
    fi
fi

# Exit 10 because the mock hook always returns decision:"block"; ensure
# the wrapper reached the decision branch rather than exiting 20
# (wrapper error) or 0 (bogus ALLOW from lost transcript_path).
if [[ "$EXIT6" -eq 10 ]]; then
    pass "rlcr-stop-gate reaches decision branch with empty session_id + real transcript_path"
else
    T6_BODY=$(cat "$T6_DIR/out.txt" 2>/dev/null || true)
    fail "rlcr-stop-gate reaches decision branch with empty session_id + real transcript_path" \
        "exit 10 (mock hook returns block)" "exit $EXIT6; output: $T6_BODY"
fi

print_test_summary "RLCR Stop Gate Wrapper Test Summary"
exit $?
