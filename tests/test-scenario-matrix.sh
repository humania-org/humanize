#!/usr/bin/env bash
#
# Tests for scenario matrix foundation in setup-rlcr-loop.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

SETUP_SCRIPT="$PROJECT_ROOT/scripts/setup-rlcr-loop.sh"
STOP_HOOK="$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh"
HUMANIZE_SCRIPT="$PROJECT_ROOT/scripts/humanize.sh"
SCENARIO_MATRIX_LIB="$PROJECT_ROOT/hooks/lib/scenario-matrix.sh"

source "$SCENARIO_MATRIX_LIB"

echo "========================================"
echo "Scenario Matrix Foundation Tests"
echo "========================================"
echo ""

create_mock_codex() {
    local bin_dir="$1"
    local exec_output="${2:-Need follow-up work}"
    local review_output="${3:-No issues found.}"

    mkdir -p "$bin_dir"
    printf '%s\n' "$exec_output" > "$bin_dir/exec-output.txt"
    printf '%s\n' "$review_output" > "$bin_dir/review-output.txt"
    cat > "$bin_dir/codex" << 'EOF'
#!/usr/bin/env bash
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
subcommand=""
for arg in "$@"; do
    if [[ "$arg" == "exec" || "$arg" == "review" ]]; then
        subcommand="$arg"
        break
    fi
done
if [[ "$subcommand" == "exec" ]]; then
    cat "$script_dir/exec-output.txt"
elif [[ "$subcommand" == "review" ]]; then
    cat "$script_dir/review-output.txt"
else
    exit 0
fi
EOF
    chmod +x "$bin_dir/codex"
}

create_repo_with_plan() {
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
    git -C "$repo_dir" commit -q -m "Add gitignore for scenario matrix tests"
}

run_setup() {
    local repo_dir="$1"
    shift

    (
        cd "$repo_dir"
        PATH="$repo_dir/bin:$PATH" CLAUDE_PROJECT_DIR="$repo_dir" bash "$SETUP_SCRIPT" "$@"
    )
}

run_setup_from_subdir() {
    local repo_dir="$1"
    local subdir="$2"
    shift 2

    (
        cd "$repo_dir/$subdir"
        PATH="$repo_dir/bin:$PATH" CLAUDE_PROJECT_DIR="$repo_dir" bash "$SETUP_SCRIPT" "$@"
    )
}

setup_matrix_test_dir() {
    setup_test_dir
    export XDG_CACHE_HOME="$TEST_DIR/.cache"
    mkdir -p "$XDG_CACHE_HOME"
}

find_matrix_file() {
    local repo_dir="$1"
    find "$repo_dir/.humanize/rlcr" -name "scenario-matrix.json" -type f | head -1
}

setup_manual_loop_repo() {
    local repo_dir="$1"
    local round="$2"
    local review_started="$3"
    local scenario_matrix_required="${4:-true}"

    init_test_git_repo "$repo_dir"
    mkdir -p "$repo_dir/plans"
    cat > "$repo_dir/plans/plan.md" << 'EOF'
# Hook Plan

## Goal
Keep matrix state aligned with runtime prompts.

## Acceptance Criteria
- AC-1: Scenario matrix is refreshed
EOF
    cat > "$repo_dir/.gitignore" << 'EOF'
plans/
.humanize/
bin/
.cache/
EOF
    git -C "$repo_dir" add .gitignore
    git -C "$repo_dir" commit -q -m "Add gitignore for hook matrix tests"

    local current_branch
    current_branch=$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD)

    local loop_dir="$repo_dir/.humanize/rlcr/2024-03-01_12-00-00"
    mkdir -p "$loop_dir"
    cat > "$loop_dir/state.md" << EOF
---
current_round: $round
max_iterations: 10
codex_model: gpt-5.4
codex_effort: high
codex_timeout: 5400
push_every_round: false
plan_file: plans/plan.md
plan_tracked: false
start_branch: $current_branch
base_branch: main
base_commit: abc123
review_started: $review_started
ask_codex_question: false
full_review_round: 5
session_id:
scenario_matrix_file: .humanize/rlcr/2024-03-01_12-00-00/scenario-matrix.json
scenario_matrix_required: $scenario_matrix_required
drift_status: normal
mainline_stall_count: 0
last_mainline_verdict: unknown
---
EOF
    cp "$repo_dir/plans/plan.md" "$loop_dir/plan.md"
    cat > "$loop_dir/goal-tracker.md" << 'EOF'
# Goal Tracker
## IMMUTABLE SECTION
### Ultimate Goal
Keep matrix state aligned with runtime prompts.
### Acceptance Criteria
| ID | Criterion |
|----|-----------|
| AC-1 | Matrix instructions remain present |
---
## MUTABLE SECTION
#### Active Tasks
| Task | Target AC | Status | Tag | Owner | Notes |
|------|-----------|--------|-----|-------|-------|
| Keep matrix aligned | AC-1 | in_progress | coding | claude | matrix-aware round |

### Blocking Side Issues
| Issue | Discovered Round | Blocking AC | Resolution Path |
|-------|-----------------|-------------|-----------------|

### Queued Side Issues
| Issue | Discovered Round | Why Not Blocking | Revisit Trigger |
|-------|-----------------|------------------|-----------------|
EOF
    cat > "$loop_dir/round-${round}-contract.md" << EOF
# Round $round Contract

- Mainline Objective: Keep the scenario matrix aligned with the current round.
- Target ACs: AC-1
- Blocking Side Issues In Scope: none
- Queued Side Issues Out of Scope: none
- Success Criteria: The next prompt still re-anchors on the scenario matrix.
EOF
    cat > "$loop_dir/round-${round}-prompt.md" << EOF
# Round $round Prompt

Continue the work.
EOF
    cat > "$loop_dir/round-${round}-summary.md" << 'EOF'
# Round Summary

Progress made, but more work remains.

## BitLesson Delta
- Action: none
- Lesson ID(s): NONE
- Notes: No new lessons in this fixture.
EOF

    if [[ "$review_started" == "true" ]]; then
        echo "build_finish_round=$round" > "$loop_dir/.review-phase-started"
    fi

    cat > "$loop_dir/scenario-matrix.json" << 'EOF'
{
  "schema_version": 2,
  "created_at": "2026-04-01T00:00:00Z",
  "plan": {
    "file": "plans/plan.md",
    "backup_file": ".humanize/rlcr/2024-03-01_12-00-00/plan.md",
    "task_breakdown_status": "parsed",
    "warnings": []
  },
  "runtime": {
    "mode": "implementation",
    "current_round": 2,
    "projection_mode": "compatibility"
  },
  "metadata": {
    "seed_task_count": 2,
    "seed_source": "task_breakdown"
  },
  "manager": {
    "role": "top_level_session",
    "authority_mode": "manager_reconcile",
    "authoritative_writer": "manager",
    "current_primary_task_id": "task1",
    "last_reconciled_at": "2026-04-01T00:00:00Z"
  },
  "feedback": {
    "execution": [],
    "review": []
  },
  "tasks": [
    {
      "id": "task1",
      "title": "Repair parser contract",
      "lane": "mainline",
      "routing": "coding",
      "owner": null,
      "scope": {
        "summary": "",
        "paths": [],
        "constraints": []
      },
      "cluster_id": null,
      "repair_wave": null,
      "risk_bucket": "planned",
      "admission": {
        "status": "active",
        "reason": "fixture"
      },
      "authority": {
        "write_mode": "manager_only",
        "authoritative_source": "manager"
      },
      "target_ac": ["AC-1"],
      "depends_on": [],
      "state": "ready",
      "assumptions": [],
      "strategy": {
        "current": "repair-parser",
        "attempt_count": 0,
        "repeated_failure_count": 0,
        "method_switch_required": false
      },
      "health": {
        "stuck_score": 0,
        "last_progress_round": 0
      },
      "metadata": {
        "seed_source": "fixture"
      }
    },
    {
      "id": "task2",
      "title": "Update downstream validator",
      "lane": "supporting",
      "routing": "coding",
      "owner": null,
      "scope": {
        "summary": "",
        "paths": [],
        "constraints": []
      },
      "cluster_id": null,
      "repair_wave": null,
      "risk_bucket": "planned",
      "admission": {
        "status": "active",
        "reason": "fixture"
      },
      "authority": {
        "write_mode": "manager_only",
        "authoritative_source": "manager"
      },
      "target_ac": ["AC-1"],
      "depends_on": ["task1"],
      "state": "pending",
      "assumptions": [],
      "strategy": {
        "current": "update-validator",
        "attempt_count": 0,
        "repeated_failure_count": 0,
        "method_switch_required": false
      },
      "health": {
        "stuck_score": 0,
        "last_progress_round": 0
      },
      "metadata": {
        "seed_source": "fixture"
      }
    }
  ],
  "events": [],
  "oversight": {
    "status": "idle",
    "last_action": "none",
    "updated_at": null
  }
}
EOF
}

# ========================================
# Test 1: Valid task breakdown seeds tasks and dependencies
# ========================================

setup_matrix_test_dir
REPO_VALID_DIR="$TEST_DIR/repo-valid"
create_repo_with_plan "$REPO_VALID_DIR" '# Scenario Matrix Plan

## Goal
Seed the scenario matrix from a valid task table.

## Acceptance Criteria
- AC-1: Parsed successfully
- AC-2: Dependencies preserved

## Task Breakdown
| Task ID | Description | Target AC | Tag (`coding`/`analyze`) | Depends On |
|---------|-------------|-----------|----------------------------|------------|
| task1 | Implement parser | AC-1 | coding | - |
| task2 | Analyze rollout risk | AC-2 | analyze | task1
'
create_mock_codex "$REPO_VALID_DIR/bin"

run_setup "$REPO_VALID_DIR" plans/plan.md > /dev/null 2>&1
MATRIX_FILE=$(find_matrix_file "$REPO_VALID_DIR")

if [[ -n "$MATRIX_FILE" && -f "$MATRIX_FILE" ]]; then
    pass "setup creates scenario-matrix.json for valid task table"
else
    fail "setup creates scenario-matrix.json for valid task table" "matrix file exists" "not found"
fi

if [[ -n "$MATRIX_FILE" ]] && jq -e '.schema_version == 2 and .plan.task_breakdown_status == "parsed" and .metadata.seed_task_count == 2' "$MATRIX_FILE" >/dev/null 2>&1; then
    pass "matrix metadata records parsed task table under manager-owned schema"
else
    fail "matrix metadata records parsed task table under manager-owned schema" "schema_version 2 with parsed status and 2 tasks" "$(cat "$MATRIX_FILE" 2>/dev/null || echo 'missing file')"
fi

if [[ -n "$MATRIX_FILE" ]] && jq -e '
    .tasks[0].id == "task1"
    and .tasks[0].lane == "mainline"
    and .tasks[0].routing == "coding"
    and .tasks[0].state == "ready"
    and .tasks[1].id == "task2"
    and .tasks[1].lane == "queued"
    and .tasks[1].routing == "analyze"
    and .tasks[1].depends_on == ["task1"]
    and .tasks[1].state == "pending"
' "$MATRIX_FILE" >/dev/null 2>&1; then
    pass "matrix seeds routing, queue placement, and dependency state from task table"
else
    fail "matrix seeds routing, queue placement, and dependency state from task table" "task1 ready, task2 queued pending with dependency" "$(cat "$MATRIX_FILE" 2>/dev/null || echo 'missing file')"
fi

if [[ -n "$MATRIX_FILE" ]] && jq -e '
    .manager.authority_mode == "manager_reconcile"
    and .manager.authoritative_writer == "manager"
    and .manager.current_primary_task_id == "task1"
    and .runtime.checkpoint.sequence == 1
    and .runtime.checkpoint.current_id == "checkpoint-1"
    and .runtime.checkpoint.primary_task_id == "task1"
    and .runtime.checkpoint.supporting_task_ids == []
    and .runtime.convergence.status == "continue"
    and .runtime.convergence.active_task_count == 2
    and (.feedback.execution | length) == 0
    and (.feedback.review | length) == 0
    and .tasks[0].authority.write_mode == "manager_only"
    and .tasks[0].authority.authoritative_source == "manager"
    and .tasks[0].scope.paths == []
    and .tasks[0].owner == null
    and .tasks[0].risk_bucket == "planned"
    and .tasks[0].admission.status == "active"
' "$MATRIX_FILE" >/dev/null 2>&1; then
    pass "manager authority and task ownership metadata seed into new matrix"
else
    fail "manager authority and task ownership metadata seed into new matrix" "manager block plus task authority/scope/admission defaults" "$(cat "$MATRIX_FILE" 2>/dev/null || echo 'missing file')"
fi

PACKET_MARKDOWN=$(scenario_matrix_current_task_packet_markdown "$MATRIX_FILE" 2>/dev/null || true)
if echo "$PACKET_MARKDOWN" | grep -q '^## Current Task Packet$' && \
   echo "$PACKET_MARKDOWN" | grep -q 'Primary Objective: `task1`' && \
   echo "$PACKET_MARKDOWN" | grep -q 'Assigned Task: `task1` - Implement parser' && \
   echo "$PACKET_MARKDOWN" | grep -q 'Direct Downstream Impact: task2' && \
   echo "$PACKET_MARKDOWN" | grep -q 'Target ACs: AC-1'; then
    pass "scenario matrix renders primary task packet with dependency and AC context"
else
    fail "scenario matrix renders primary task packet with dependency and AC context" "task packet markdown with primary objective, downstream impact, and ACs" "$PACKET_MARKDOWN"
fi

CHECKPOINT_MARKDOWN=$(scenario_matrix_current_checkpoint_markdown "$MATRIX_FILE" 2>/dev/null || true)
if echo "$CHECKPOINT_MARKDOWN" | grep -q '^## Manager Checkpoint$' && \
   echo "$CHECKPOINT_MARKDOWN" | grep -q 'Checkpoint: `checkpoint-1`' && \
   echo "$CHECKPOINT_MARKDOWN" | grep -q 'Supporting Window: none' && \
   echo "$CHECKPOINT_MARKDOWN" | grep -q 'Convergence Status: `continue`'; then
    pass "scenario matrix renders checkpoint and convergence guidance"
else
    fail "scenario matrix renders checkpoint and convergence guidance" "checkpoint markdown with supporting window and convergence state" "$CHECKPOINT_MARKDOWN"
fi

GOAL_TRACKER_FILE=$(find "$REPO_VALID_DIR/.humanize/rlcr" -name "goal-tracker.md" -type f | head -1)
if [[ -n "$GOAL_TRACKER_FILE" ]] && \
   grep -q '\[mainline\] Implement parser' "$GOAL_TRACKER_FILE" && \
   grep -q 'Analyze rollout risk \[task2\]' "$GOAL_TRACKER_FILE" && \
   ! grep -q '\[To be populated by Claude based on plan\]' "$GOAL_TRACKER_FILE"; then
    pass "setup projects scenario matrix into goal tracker mutable sections"
else
    fail "setup projects scenario matrix into goal tracker mutable sections" "mainline and queued task rows without placeholder" "$(cat "$GOAL_TRACKER_FILE" 2>/dev/null || echo 'missing tracker')"
fi

ROUND0_CONTRACT=$(find "$REPO_VALID_DIR/.humanize/rlcr" -name "round-0-contract.md" -type f | head -1)
if [[ -n "$ROUND0_CONTRACT" ]] && \
   grep -q 'Mainline Objective: task1: Implement parser' "$ROUND0_CONTRACT" && \
   grep -q 'Checkpoint: checkpoint-1' "$ROUND0_CONTRACT" && \
   grep -q 'Supporting Window In Scope: none' "$ROUND0_CONTRACT" && \
   grep -q 'Queued Side Issues Out of Scope: task2: Analyze rollout risk' "$ROUND0_CONTRACT" && \
   grep -q 'Convergence Status: continue' "$ROUND0_CONTRACT"; then
    pass "setup seeds round-0 contract scaffold from scenario matrix"
else
    fail "setup seeds round-0 contract scaffold from scenario matrix" "matrix-derived mainline and queued task in contract" "$(cat "$ROUND0_CONTRACT" 2>/dev/null || echo 'missing contract')"
fi

if ! grep -q "mapfile" "$PROJECT_ROOT/hooks/lib/scenario-matrix.sh"; then
    pass "scenario matrix parser avoids bash-4-only mapfile"
else
    fail "scenario matrix parser avoids bash-4-only mapfile" "no mapfile usage" "$(grep -n "mapfile" "$PROJECT_ROOT/hooks/lib/scenario-matrix.sh")"
fi

# ========================================
# Test 1b: Setup from subdirectory still parses copied plan backup
# ========================================

setup_matrix_test_dir
REPO_SUBDIR_DIR="$TEST_DIR/repo-subdir"
create_repo_with_plan "$REPO_SUBDIR_DIR" '# Scenario Matrix Plan

## Goal
Seed the scenario matrix even when launched below repo root.

## Acceptance Criteria
- AC-1: Parsed successfully
- AC-2: Dependencies preserved

## Task Breakdown
| Task ID | Description | Target AC | Tag (`coding`/`analyze`) | Depends On |
|---------|-------------|-----------|----------------------------|------------|
| task1 | Implement parser | AC-1 | coding | - |
| task2 | Analyze rollout risk | AC-2 | analyze | task1
'
mkdir -p "$REPO_SUBDIR_DIR/work/nested"
create_mock_codex "$REPO_SUBDIR_DIR/bin"

run_setup_from_subdir "$REPO_SUBDIR_DIR" "work/nested" "plans/plan.md" > /dev/null 2>&1
MATRIX_FILE=$(find_matrix_file "$REPO_SUBDIR_DIR")

if [[ -n "$MATRIX_FILE" ]] && jq -e '.plan.task_breakdown_status == "parsed" and .metadata.seed_task_count == 2 and (.tasks | length) == 2' "$MATRIX_FILE" >/dev/null 2>&1; then
    pass "setup launched from subdirectory still resolves copied plan backup for matrix seed"
else
    fail "setup launched from subdirectory still resolves copied plan backup for matrix seed" "parsed task breakdown from copied backup plan" "$(cat "$MATRIX_FILE" 2>/dev/null || echo 'missing file')"
fi

# ========================================
# Test 2: Missing task breakdown still creates valid empty matrix
# ========================================

setup_matrix_test_dir
create_repo_with_plan "$TEST_DIR/repo-missing" '# No Task Table Plan

## Goal
Still create a matrix.

## Acceptance Criteria
- AC-1: Setup succeeds
- AC-2: Matrix is valid
'
create_mock_codex "$TEST_DIR/repo-missing/bin"

run_setup "$TEST_DIR/repo-missing" plans/plan.md > /dev/null 2>&1
MATRIX_FILE=$(find_matrix_file "$TEST_DIR/repo-missing")

if [[ -n "$MATRIX_FILE" ]] && jq -e '.plan.task_breakdown_status == "missing" and .metadata.seed_task_count == 0 and (.tasks | length) == 0' "$MATRIX_FILE" >/dev/null 2>&1; then
    pass "missing task table produces empty valid matrix"
else
    fail "missing task table produces empty valid matrix" "missing status with zero tasks" "$(cat "$MATRIX_FILE" 2>/dev/null || echo 'missing file')"
fi

# ========================================
# Test 3: Malformed task breakdown degrades safely
# ========================================

setup_matrix_test_dir
create_repo_with_plan "$TEST_DIR/repo-malformed" '# Broken Task Table Plan

## Goal
Do not write invalid matrix JSON.

## Acceptance Criteria
- AC-1: Setup succeeds safely
- AC-2: Matrix reports malformed task table

## Task Breakdown
| Task ID | Description | Target AC | Tag (`coding`/`analyze`) | Depends On |
|---------|-------------|-----------|----------------------------|------------|
| task1 | Broken tag row | AC-1 | codng | -
'
create_mock_codex "$TEST_DIR/repo-malformed/bin"

run_setup "$TEST_DIR/repo-malformed" plans/plan.md > /dev/null 2>&1
MATRIX_FILE=$(find_matrix_file "$TEST_DIR/repo-malformed")

if [[ -n "$MATRIX_FILE" ]] && jq -e '.plan.task_breakdown_status == "malformed" and .metadata.seed_task_count == 0 and (.tasks | length) == 0 and (.plan.warnings | length) >= 1' "$MATRIX_FILE" >/dev/null 2>&1; then
    pass "malformed task table produces warning-backed empty matrix"
else
    fail "malformed task table produces warning-backed empty matrix" "malformed status with warnings and zero tasks" "$(cat "$MATRIX_FILE" 2>/dev/null || echo 'missing file')"
fi

INVALID_MATRIX="$TEST_DIR/invalid-structure.json"
cat > "$INVALID_MATRIX" << 'EOF'
{
  "schema_version": 2,
  "plan": {
    "task_breakdown_status": "parsed",
    "warnings": []
  },
  "runtime": {
    "mode": "implementation",
    "current_round": 0
  },
  "manager": {
    "role": "top_level_session",
    "authority_mode": "manager_reconcile",
    "authoritative_writer": "manager",
    "current_primary_task_id": "task1",
    "last_reconciled_at": null
  },
  "feedback": {
    "execution": [],
    "review": []
  },
  "tasks": [1],
  "events": [],
  "oversight": {
    "status": "idle",
    "last_action": "none"
  }
}
EOF

if ! scenario_matrix_validate_file "$INVALID_MATRIX"; then
    pass "scenario matrix validation rejects structurally invalid task entries"
else
    fail "scenario matrix validation rejects structurally invalid task entries" "invalid tasks array should fail validation" "$(cat "$INVALID_MATRIX")"
fi

INVALID_AUTHORITY_MATRIX="$TEST_DIR/invalid-authority.json"
VALID_SEEDED_MATRIX=$(find_matrix_file "$REPO_VALID_DIR")
jq '
    .tasks = [
      .tasks[0],
      (
        .tasks[0]
        | .id = "task-conflict"
        | .title = "Conflicting mainline"
        | .owner = "manager"
      )
    ]
' "$VALID_SEEDED_MATRIX" > "$INVALID_AUTHORITY_MATRIX"

if ! scenario_matrix_validate_file "$INVALID_AUTHORITY_MATRIX"; then
    pass "scenario matrix validation rejects contradictory manager ownership and multiple active mainlines"
else
    fail "scenario matrix validation rejects contradictory manager ownership and multiple active mainlines" "invalid owner and duplicate active mainline should fail validation" "$(cat "$INVALID_AUTHORITY_MATRIX")"
fi

FEEDBACK_MATRIX="$TEST_DIR/feedback-matrix.json"
cp "$VALID_SEEDED_MATRIX" "$FEEDBACK_MATRIX"
scenario_matrix_record_execution_feedback "$FEEDBACK_MATRIX" "task2" "subagent-1" "state_suggestion" "Suggest keeping validator work queued behind parser repair."
scenario_matrix_record_review_feedback "$FEEDBACK_MATRIX" "task1" "review-agent" "cluster_hint" "This issue likely belongs to the parser-contract repair wave."

if jq -e '
    .manager.current_primary_task_id == "task1"
    and .tasks[0].state == "ready"
    and .tasks[1].state == "pending"
    and (.feedback.execution | length) == 1
    and .feedback.execution[0].authoritative == false
    and .feedback.execution[0].task_id == "task2"
    and .feedback.execution[0].suggested_by == "subagent-1"
    and (.feedback.review | length) == 1
    and .feedback.review[0].authoritative == false
    and .feedback.review[0].task_id == "task1"
    and .feedback.review[0].kind == "cluster_hint"
' "$FEEDBACK_MATRIX" >/dev/null 2>&1; then
    pass "non-authoritative subagent and review feedback stay in feedback queues without mutating task state"
else
    fail "non-authoritative subagent and review feedback stay in feedback queues without mutating task state" "feedback queues updated while authoritative task state stays unchanged" "$(cat "$FEEDBACK_MATRIX")"
fi

# ========================================
# Test 4: Skip-impl without a plan uses not_applicable seed mode
# ========================================

setup_matrix_test_dir
init_test_git_repo "$TEST_DIR/repo-skip"
cat > "$TEST_DIR/repo-skip/.gitignore" << 'EOF'
.humanize/
bin/
.cache/
EOF
git -C "$TEST_DIR/repo-skip" add .gitignore
git -C "$TEST_DIR/repo-skip" commit -q -m "Add gitignore for skip-impl matrix test"
create_mock_codex "$TEST_DIR/repo-skip/bin"

run_setup "$TEST_DIR/repo-skip" --skip-impl > /dev/null 2>&1
MATRIX_FILE=$(find_matrix_file "$TEST_DIR/repo-skip")

if [[ -n "$MATRIX_FILE" ]] && jq -e '.runtime.mode == "skip_impl" and .plan.task_breakdown_status == "not_applicable" and .metadata.seed_source == "not_applicable" and (.tasks | length) == 0' "$MATRIX_FILE" >/dev/null 2>&1; then
    pass "skip-impl without plan creates not_applicable matrix scaffold"
else
    fail "skip-impl without plan creates not_applicable matrix scaffold" "skip_impl mode with not_applicable seed" "$(cat "$MATRIX_FILE" 2>/dev/null || echo 'missing file')"
fi

PROMPT_FILE=$(find "$REPO_VALID_DIR/.humanize/rlcr" -name "round-0-prompt.md" -type f | head -1)
if [[ -n "$PROMPT_FILE" ]] && grep -q "Scenario Matrix Setup" "$PROMPT_FILE" && grep -q "scenario-matrix.json" "$PROMPT_FILE"; then
    pass "round-0 prompt includes scenario matrix setup guidance"
else
    fail "round-0 prompt includes scenario matrix setup guidance" "scenario matrix setup section in prompt" "$(cat "$PROMPT_FILE" 2>/dev/null || echo 'missing prompt')"
fi

if [[ -n "$PROMPT_FILE" ]] && \
   grep -q '^## Current Task Packet$' "$PROMPT_FILE" && \
   grep -q 'Primary Objective: `task1`' "$PROMPT_FILE" && \
   grep -q '^## Manager Checkpoint$' "$PROMPT_FILE" && \
   grep -q '^## Task Packet Feedback Readback$' "$PROMPT_FILE" && \
   grep -q 'manager-issued scope' "$PROMPT_FILE"; then
    pass "round-0 prompt includes current task packet, manager checkpoint, and scope authority note"
else
    fail "round-0 prompt includes current task packet, manager checkpoint, and scope authority note" "round-0 prompt with task packet, checkpoint, feedback readback, and manager-issued scope guidance" "$(cat "$PROMPT_FILE" 2>/dev/null || echo 'missing prompt')"
fi

SUMMARY_FILE=$(find "$REPO_VALID_DIR/.humanize/rlcr" -name "round-0-summary.md" -type f | head -1)
if [[ -n "$SUMMARY_FILE" ]] && \
   grep -q '^## Task Packet Feedback (Optional)$' "$SUMMARY_FILE" && \
   grep -q '^| Task ID | Source | Kind | Summary |$' "$SUMMARY_FILE"; then
    pass "summary scaffold includes task packet feedback table"
else
    fail "summary scaffold includes task packet feedback table" "summary scaffold with optional task packet feedback section" "$(cat "$SUMMARY_FILE" 2>/dev/null || echo 'missing summary')"
fi

# ========================================
# Test 5: Stop hook refreshes matrix and next-round prompt after implementation review
# ========================================

setup_matrix_test_dir
setup_manual_loop_repo "$TEST_DIR/repo-hook-impl" 2 false true
create_mock_codex "$TEST_DIR/repo-hook-impl/bin" "## Review Feedback

## Touched Failure Surfaces
- dependency-contract | why: parser and downstream validator drifted together | confidence: high
- rollback-symmetry | why: replanning touches recovery and invalidation paths | confidence: medium

## Likely Sibling Risks
- Validator follow-up may still assume the old parser shape | derived_from: dependency-contract | axis: adjacent state transitions | why: downstream synchronization already regressed once | check: audit the validator update path and stale assumptions | confidence: high

## Mainline Gaps
- [P1] Dependency mismatch still breaks review.

Mainline Progress Verdict: REGRESSED

An upstream dependency changed and downstream work must be replanned.

## Coverage Ledger
| Surface | Status | Notes |
|---------|--------|-------|
| dependency-contract | covered | checked the parser and downstream validator contract edges |
| rollback-symmetry | partial | replanning path inspected, but downstream restore path still needs follow-up |

CONTINUE"

HOOK_INPUT='{"stop_hook_active": false, "transcript": [], "session_id": ""}'
echo "$HOOK_INPUT" | PATH="$TEST_DIR/repo-hook-impl/bin:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR/repo-hook-impl" bash "$STOP_HOOK" > /dev/null 2>&1 || true

NEXT_PROMPT="$TEST_DIR/repo-hook-impl/.humanize/rlcr/2024-03-01_12-00-00/round-3-prompt.md"
MATRIX_FILE="$TEST_DIR/repo-hook-impl/.humanize/rlcr/2024-03-01_12-00-00/scenario-matrix.json"
GOAL_TRACKER_FILE="$TEST_DIR/repo-hook-impl/.humanize/rlcr/2024-03-01_12-00-00/goal-tracker.md"
NEXT_CONTRACT="$TEST_DIR/repo-hook-impl/.humanize/rlcr/2024-03-01_12-00-00/round-3-contract.md"

if [[ -f "$NEXT_PROMPT" ]] && grep -q "Scenario Matrix Re-anchor" "$NEXT_PROMPT" && grep -q "Current matrix mainline projection" "$NEXT_PROMPT"; then
    pass "implementation follow-up prompt includes scenario matrix re-anchor"
else
    fail "implementation follow-up prompt includes scenario matrix re-anchor" "scenario matrix section in round-3 prompt" "$(cat "$NEXT_PROMPT" 2>/dev/null || echo 'missing prompt')"
fi

if [[ -f "$NEXT_PROMPT" ]] && \
   grep -q '^## Current Task Packet$' "$NEXT_PROMPT" && \
   grep -q '^## Manager Checkpoint$' "$NEXT_PROMPT" && \
   grep -q '^## Recent Review Coverage$' "$NEXT_PROMPT" && \
   grep -q '^## Task Packet Feedback Readback$' "$NEXT_PROMPT"; then
    pass "implementation follow-up prompt includes task packet projection, recent review coverage, and readback instructions"
else
    fail "implementation follow-up prompt includes task packet projection, recent review coverage, and readback instructions" "task packet, checkpoint, recent review coverage, and feedback readback sections in round-3 prompt" "$(cat "$NEXT_PROMPT" 2>/dev/null || echo 'missing prompt')"
fi

if [[ -f "$GOAL_TRACKER_FILE" ]] && \
   grep -q 'Repair parser contract' "$GOAL_TRACKER_FILE" && \
   grep -q 'Update downstream validator \[task2\]' "$GOAL_TRACKER_FILE"; then
    pass "implementation review syncs matrix projection back into goal tracker"
else
    fail "implementation review syncs matrix projection back into goal tracker" "tracker shows mainline and blocking projection" "$(cat "$GOAL_TRACKER_FILE" 2>/dev/null || echo 'missing tracker')"
fi

if [[ -f "$NEXT_CONTRACT" ]] && \
   grep -q 'Mainline Objective: task1: Repair parser contract' "$NEXT_CONTRACT" && \
   grep -q 'Checkpoint: checkpoint-' "$NEXT_CONTRACT" && \
   grep -q 'Residual Risk: score=' "$NEXT_CONTRACT" && \
   grep -q 'Blocking Side Issues In Scope: task2: Update downstream validator' "$NEXT_CONTRACT"; then
    pass "implementation review writes next-round contract scaffold from scenario matrix"
else
    fail "implementation review writes next-round contract scaffold from scenario matrix" "matrix-derived next-round contract" "$(cat "$NEXT_CONTRACT" 2>/dev/null || echo 'missing contract')"
fi

if jq -e '
    .runtime.current_round == 3
    and .runtime.last_review.phase == "implementation"
    and .runtime.last_review.verdict == "regressed"
    and .runtime.last_review.coverage_available == true
    and .runtime.last_review.coverage_summary.surface_count == 2
    and .runtime.last_review.coverage_summary.sibling_risk_count == 1
    and .runtime.last_review.coverage_summary.partial_or_unclear_count == 1
    and .runtime.review_coverage.source_phase == "implementation"
    and .runtime.review_coverage.source_round == 3
    and ([.runtime.review_coverage.touched_failure_surfaces[] | select(.surface == "dependency-contract" and .confidence == "high")] | length) == 1
    and ([.runtime.review_coverage.likely_sibling_risks[] | select(.derived_from == "dependency-contract" and .confidence == "high")] | length) == 1
    and ([.runtime.review_coverage.coverage_ledger[] | select(.surface == "rollback-symmetry" and .status == "partial")] | length) == 1
    and (.events | length) >= 1
    and .tasks[0].state == "needs_replan"
    and .tasks[1].state == "blocked"
    and .oversight.status == "idle"
' "$MATRIX_FILE" >/dev/null 2>&1; then
    pass "implementation review stores review coverage, event log, and dependent task states"
else
    fail "implementation review stores review coverage, event log, and dependent task states" "round advanced with review coverage snapshot and replanning states" "$(cat "$MATRIX_FILE" 2>/dev/null || echo 'missing matrix')"
fi

# ========================================
# Test 5a: Paragraph-format coverage ledgers are parsed into retained review coverage
# ========================================

PARAGRAPH_COVERAGE_JSON=$(scenario_matrix_extract_review_coverage_json $'## Touched Failure Surfaces\n- rollback-symmetry | why: cancellation and restore touch the same state machine | confidence: high\n\n## Coverage Ledger\nrollback-symmetry: partial. cancel path checked; restore path still unclear.\n\nresource-cleanup is covered. release path and rollback path were both inspected.\n\nCONTINUE')

if jq -e '
    ([.touched_failure_surfaces[] | select(.surface == "rollback-symmetry" and .confidence == "high")] | length) == 1
    and ([.coverage_ledger[] | select(.surface == "rollback-symmetry" and .status == "partial")] | length) == 1
    and ([.coverage_ledger[] | select(.surface == "resource-cleanup" and .status == "covered")] | length) == 1
    and .summary.covered_count == 1
    and .summary.partial_or_unclear_count == 1
' <<< "$PARAGRAPH_COVERAGE_JSON" >/dev/null 2>&1; then
    pass "paragraph-format coverage ledgers are parsed into structured review coverage"
else
    fail "paragraph-format coverage ledgers are parsed into structured review coverage" "paragraph coverage entries retained with correct counts" "$PARAGRAPH_COVERAGE_JSON"
fi

# ========================================
# Test 5aa: Code review cycle preserves the most recent implementation review coverage snapshot
# ========================================

setup_matrix_test_dir
setup_manual_loop_repo "$TEST_DIR/repo-review-coverage-preserve" 2 false true
MATRIX_FILE="$TEST_DIR/repo-review-coverage-preserve/.humanize/rlcr/2024-03-01_12-00-00/scenario-matrix.json"

scenario_matrix_apply_implementation_review "$MATRIX_FILE" 3 "stalled" $'## Touched Failure Surfaces\n- dependency-contract | why: parser and validator drifted together | confidence: high\n\n## Likely Sibling Risks\n- Validator update path may still rely on the old parser contract | derived_from: dependency-contract | axis: adjacent state transitions | why: downstream sync is brittle | check: inspect stale field assumptions | confidence: medium\n\nMainline Progress Verdict: STALLED\n\n## Coverage Ledger\n| Surface | Status | Notes |\n|---------|--------|-------|\n| dependency-contract | partial | parser repair checked; downstream validation path still open |\n\nCONTINUE'
scenario_matrix_record_code_review_cycle "$MATRIX_FILE" 4 "code_review_issues"

if jq -e '
    .runtime.current_round == 4
    and .runtime.last_review.phase == "review"
    and .runtime.last_review.verdict == "code_review_issues"
    and .runtime.last_review.coverage_available == true
    and .runtime.last_review.coverage_summary.surface_count == 1
    and .runtime.review_coverage.source_phase == "implementation"
    and .runtime.review_coverage.source_round == 3
    and ([.runtime.review_coverage.coverage_ledger[] | select(.surface == "dependency-contract" and .status == "partial")] | length) == 1
' "$MATRIX_FILE" >/dev/null 2>&1; then
    pass "code review cycle preserves the latest implementation review coverage snapshot"
else
    fail "code review cycle preserves the latest implementation review coverage snapshot" "review phase keeps the last implementation coverage analysis intact" "$(cat "$MATRIX_FILE" 2>/dev/null || echo 'missing matrix')"
fi

# ========================================
# Test 5ab: COMPLETE -> code review handoff preserves the newest implementation review coverage snapshot
# ========================================

setup_matrix_test_dir
setup_manual_loop_repo "$TEST_DIR/repo-complete-handoff-coverage" 2 false true
create_mock_codex "$TEST_DIR/repo-complete-handoff-coverage/bin" $'## Review Feedback\n\n## Touched Failure Surfaces\n- handoff-hotspot | why: the final implementation review still touches the same rollback hotspot | confidence: high\n\n## Likely Sibling Risks\n- Restore path may still drift from cancel semantics | derived_from: handoff-hotspot | axis: symmetric paths | why: the hotspot already needed multiple follow-up adjustments | check: audit the rollback restore branch and neighboring call sites | confidence: high\n\nMainline Progress Verdict: ADVANCED\n\n## Coverage Ledger\nrollback-symmetry: partial. cancel path checked; restore path still unclear.\n\nCOMPLETE' $'[P1] rollback restore path still breaks review.\n'

echo "$HOOK_INPUT" | PATH="$TEST_DIR/repo-complete-handoff-coverage/bin:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR/repo-complete-handoff-coverage" bash "$STOP_HOOK" > /dev/null 2>&1 || true

NEXT_PROMPT="$TEST_DIR/repo-complete-handoff-coverage/.humanize/rlcr/2024-03-01_12-00-00/round-3-prompt.md"
MATRIX_FILE="$TEST_DIR/repo-complete-handoff-coverage/.humanize/rlcr/2024-03-01_12-00-00/scenario-matrix.json"

if [[ -f "$NEXT_PROMPT" ]] && \
   grep -q '^## Recent Review Coverage$' "$NEXT_PROMPT" && \
   grep -q 'handoff-hotspot' "$NEXT_PROMPT" && \
   grep -q 'rollback-symmetry' "$NEXT_PROMPT"; then
    pass "review follow-up prompt keeps the newest implementation review coverage after COMPLETE handoff"
else
    fail "review follow-up prompt keeps the newest implementation review coverage after COMPLETE handoff" "recent review coverage from the final implementation review in round-3 prompt" "$(cat "$NEXT_PROMPT" 2>/dev/null || echo 'missing prompt')"
fi

if jq -e '
    .runtime.current_round == 3
    and .runtime.last_review.phase == "review"
    and .runtime.last_review.verdict == "code_review_issues"
    and .runtime.last_review.coverage_available == true
    and .runtime.last_review.coverage_summary.surface_count == 1
    and .runtime.last_review.coverage_summary.partial_or_unclear_count == 1
    and .runtime.review_coverage.source_phase == "implementation"
    and .runtime.review_coverage.source_round == 3
    and ([.runtime.review_coverage.touched_failure_surfaces[] | select(.surface == "handoff-hotspot" and .confidence == "high")] | length) == 1
    and ([.runtime.review_coverage.coverage_ledger[] | select(.surface == "rollback-symmetry" and .status == "partial")] | length) == 1
' "$MATRIX_FILE" >/dev/null 2>&1; then
    pass "code-review follow-up retains the latest implementation review coverage after COMPLETE handoff"
else
    fail "code-review follow-up retains the latest implementation review coverage after COMPLETE handoff" "review phase matrix keeps the final implementation review coverage snapshot" "$(cat "$MATRIX_FILE" 2>/dev/null || echo 'missing matrix')"
fi

# ========================================
# Test 5d: Summary task-packet feedback is ingested as non-authoritative execution feedback
# ========================================

setup_matrix_test_dir
setup_manual_loop_repo "$TEST_DIR/repo-hook-feedback" 2 false true
cat >> "$TEST_DIR/repo-hook-feedback/.humanize/rlcr/2024-03-01_12-00-00/round-2-summary.md" << 'EOF'

## Task Packet Feedback
| Task ID | Source | Kind | Summary |
|---------|--------|------|---------|
| task2 | subagent-validator | dependency_note | Validator work should stay queued until parser repair stabilizes. |
EOF
create_mock_codex "$TEST_DIR/repo-hook-feedback/bin" "## Review Feedback

Mainline Progress Verdict: ADVANCED

Continue with the current mainline.

CONTINUE"

echo "$HOOK_INPUT" | PATH="$TEST_DIR/repo-hook-feedback/bin:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR/repo-hook-feedback" bash "$STOP_HOOK" > /dev/null 2>&1 || true
MATRIX_FILE="$TEST_DIR/repo-hook-feedback/.humanize/rlcr/2024-03-01_12-00-00/scenario-matrix.json"

if jq -e '
    (.feedback.execution | length) == 1
    and .feedback.execution[0].task_id == "task2"
    and .feedback.execution[0].suggested_by == "subagent-validator"
    and .feedback.execution[0].kind == "dependency_note"
    and .feedback.execution[0].source_file == "round-2-summary.md"
    and .feedback.execution[0].authoritative == false
    and (.feedback.execution[0].summary | contains("queued until parser repair stabilizes"))
    and .tasks[0].state == "in_progress"
    and .tasks[1].state == "pending"
' "$MATRIX_FILE" >/dev/null 2>&1; then
    pass "stop hook ingests task packet feedback into non-authoritative execution queue"
else
    fail "stop hook ingests task packet feedback into non-authoritative execution queue" "execution feedback entry with preserved authoritative task state" "$(cat "$MATRIX_FILE" 2>/dev/null || echo 'missing matrix')"
fi

# ========================================
# Test 5b: Recovered mainline clears stale replan state and reopens dependents
# ========================================

setup_matrix_test_dir
setup_manual_loop_repo "$TEST_DIR/repo-recovery" 2 false true
MATRIX_FILE="$TEST_DIR/repo-recovery/.humanize/rlcr/2024-03-01_12-00-00/scenario-matrix.json"

scenario_matrix_apply_implementation_review "$MATRIX_FILE" 3 "regressed" "An upstream dependency changed and downstream work must be replanned."
scenario_matrix_apply_implementation_review "$MATRIX_FILE" 4 "advanced" "Recovered the parser contract and resumed steady mainline progress."

if jq -e '
    .runtime.current_round == 4
    and .runtime.last_review.phase == "implementation"
    and .runtime.last_review.verdict == "advanced"
    and .tasks[0].state == "in_progress"
    and .tasks[0].health.stuck_score == 0
    and .tasks[0].strategy.repeated_failure_count == 0
    and .tasks[1].state == "pending"
    and .oversight.status == "idle"
' "$MATRIX_FILE" >/dev/null 2>&1; then
    pass "advanced review clears stale needs_replan state and reopens dependent tasks"
else
    fail "advanced review clears stale needs_replan state and reopens dependent tasks" "mainline in_progress with dependent task pending" "$(cat "$MATRIX_FILE" 2>/dev/null || echo 'missing matrix')"
fi

# ========================================
# Test 5e: Frontier reconcile promotes the next active task when the current primary is complete
# ========================================

setup_matrix_test_dir
setup_manual_loop_repo "$TEST_DIR/repo-frontier-reconcile" 2 false true
MATRIX_FILE="$TEST_DIR/repo-frontier-reconcile/.humanize/rlcr/2024-03-01_12-00-00/scenario-matrix.json"

jq '
    .tasks[0].state = "done"
    | .tasks[0].health.last_progress_round = 2
    | .manager.current_primary_task_id = "task1"
' "$MATRIX_FILE" > "$MATRIX_FILE.tmp" && mv "$MATRIX_FILE.tmp" "$MATRIX_FILE"

scenario_matrix_reconcile_manager_state "$MATRIX_FILE" 3 "frontier_shift"

if jq -e '
    .manager.current_primary_task_id == "task2"
    and .runtime.checkpoint.primary_task_id == "task2"
    and .runtime.checkpoint.frontier_changed == true
    and .runtime.checkpoint.sequence == 1
    and .tasks[1].lane == "mainline"
    and .runtime.convergence.status == "stabilizing"
' "$MATRIX_FILE" >/dev/null 2>&1; then
    pass "frontier reconcile promotes the next active task into the single primary objective"
else
    fail "frontier reconcile promotes the next active task into the single primary objective" "task2 promoted to checkpoint primary" "$(cat "$MATRIX_FILE" 2>/dev/null || echo 'missing matrix')"
fi

# ========================================
# Test 5g: Frontier reconcile prefers runnable work over blocked follow-up
# ========================================

setup_matrix_test_dir
setup_manual_loop_repo "$TEST_DIR/repo-frontier-runnable" 2 false true
MATRIX_FILE="$TEST_DIR/repo-frontier-runnable/.humanize/rlcr/2024-03-01_12-00-00/scenario-matrix.json"

jq '
    .metadata.seed_task_count = 3
    | .tasks[0].state = "done"
    | .tasks[0].health.last_progress_round = 2
    | .tasks[1].state = "blocked"
    | .tasks += [
        (
            .tasks[1]
            | .id = "task3"
            | .title = "Finalize executor cleanup"
            | .lane = "queued"
            | .state = "ready"
            | .depends_on = []
            | .metadata.seed_source = "fixture"
        )
    ]
    | .manager.current_primary_task_id = "task1"
' "$MATRIX_FILE" > "$MATRIX_FILE.tmp" && mv "$MATRIX_FILE.tmp" "$MATRIX_FILE"

scenario_matrix_reconcile_manager_state "$MATRIX_FILE" 3 "frontier_shift"

if jq -e '
    .manager.current_primary_task_id == "task3"
    and .runtime.checkpoint.primary_task_id == "task3"
    and (.tasks[] | select(.id == "task3") | .lane == "mainline" and .state == "ready")
    and (.tasks[] | select(.id == "task2") | .lane == "supporting" and .state == "blocked")
' "$MATRIX_FILE" >/dev/null 2>&1; then
    pass "frontier reconcile prefers runnable work over blocked follow-up when selecting a new primary objective"
else
    fail "frontier reconcile prefers runnable work over blocked follow-up when selecting a new primary objective" "task3 promoted while blocked task2 stays supporting" "$(cat "$MATRIX_FILE" 2>/dev/null || echo 'missing matrix')"
fi

# ========================================
# Test 5f: Convergence stabilizes when only deferred watchlist work remains
# ========================================

setup_matrix_test_dir
setup_manual_loop_repo "$TEST_DIR/repo-convergence" 2 false true
MATRIX_FILE="$TEST_DIR/repo-convergence/.humanize/rlcr/2024-03-01_12-00-00/scenario-matrix.json"

jq '
    .tasks[0].state = "done"
    | .tasks[1].state = "deferred"
    | .tasks[1].lane = "queued"
    | .tasks[1].admission.status = "watchlist"
    | .tasks[1].admission.reason = "deferred_by_manager"
    | .tasks[1].metadata.deferred_since_round = 2
' "$MATRIX_FILE" > "$MATRIX_FILE.tmp" && mv "$MATRIX_FILE.tmp" "$MATRIX_FILE"

scenario_matrix_reconcile_manager_state "$MATRIX_FILE" 3 "convergence_check"

if jq -e '
    .manager.current_primary_task_id == null
    and .runtime.convergence.status == "converged"
    and .runtime.convergence.next_action == "prepare_closure"
    and .runtime.convergence.must_fix_open_count == 0
    and .runtime.convergence.high_risk_open_count == 0
    and .runtime.convergence.active_task_count == 0
    and .runtime.convergence.watchlist_count == 1
' "$MATRIX_FILE" >/dev/null 2>&1; then
    pass "convergence reconcile recognizes when only deferred watchlist work remains"
else
    fail "convergence reconcile recognizes when only deferred watchlist work remains" "converged runtime with only watchlist residue" "$(cat "$MATRIX_FILE" 2>/dev/null || echo 'missing matrix')"
fi

# ========================================
# Test 5g: Blocked finding backlog prevents premature convergence
# ========================================

setup_matrix_test_dir
setup_manual_loop_repo "$TEST_DIR/repo-convergence-finding-groups" 2 false true
MATRIX_FILE="$TEST_DIR/repo-convergence-finding-groups/.humanize/rlcr/2024-03-01_12-00-00/scenario-matrix.json"

jq '
    .tasks[0].state = "done"
    | .tasks[1].state = "done"
    | .tasks[1].lane = "queued"
    | .manager.current_primary_task_id = null
    | .runtime.checkpoint.primary_task_id = null
' "$MATRIX_FILE" > "$MATRIX_FILE.tmp" && mv "$MATRIX_FILE.tmp" "$MATRIX_FILE"

scenario_matrix_ingest_review_findings "$MATRIX_FILE" 4 "review" "[P1] Downstream dependency mismatch still breaks review."
scenario_matrix_reconcile_manager_state "$MATRIX_FILE" 4 "finding_group_frontier"

if jq -e '
    .manager.current_primary_task_id == null
    and .runtime.convergence.status == "continue"
    and .runtime.convergence.next_action == "advance_checkpoint"
    and .runtime.convergence.must_fix_open_count == 1
    and .runtime.convergence.high_risk_open_count == 1
    and .runtime.convergence.active_task_count == 1
    and .runtime.convergence.watchlist_count == 0
    and ((.runtime.checkpoint.frontier_signature | fromjson | .blocked_finding_group_ids | length) == 1)
' "$MATRIX_FILE" >/dev/null 2>&1; then
    pass "blocked grouped review backlog keeps the manager frontier open until it is resolved"
else
    fail "blocked grouped review backlog keeps the manager frontier open until it is resolved" "continue convergence state with one blocked finding group in the checkpoint frontier" "$(cat "$MATRIX_FILE" 2>/dev/null || echo 'missing matrix')"
fi
# ========================================
# Test 5c: Blocked dependents reopen once upstream starts advancing again
# ========================================

setup_matrix_test_dir
setup_manual_loop_repo "$TEST_DIR/repo-recovery-blocked" 2 false true
MATRIX_FILE="$TEST_DIR/repo-recovery-blocked/.humanize/rlcr/2024-03-01_12-00-00/scenario-matrix.json"

scenario_matrix_apply_implementation_review "$MATRIX_FILE" 3 "stalled" "The upstream dependency changed and downstream work is blocked."
scenario_matrix_apply_implementation_review "$MATRIX_FILE" 4 "advanced" "Recovered the parser contract and resumed steady mainline progress."

if jq -e '
    .tasks[0].state == "in_progress"
    and .tasks[1].state == "pending"
' "$MATRIX_FILE" >/dev/null 2>&1; then
    pass "advanced review reopens previously blocked dependent tasks"
else
    fail "advanced review reopens previously blocked dependent tasks" "dependent task returns to pending after upstream recovery" "$(cat "$MATRIX_FILE" 2>/dev/null || echo 'missing matrix')"
fi

# ========================================
# Test 6: Repeated failures trigger bounded oversight intervention
# ========================================

setup_matrix_test_dir
setup_manual_loop_repo "$TEST_DIR/repo-hook-oversight" 2 false true
MATRIX_FILE="$TEST_DIR/repo-hook-oversight/.humanize/rlcr/2024-03-01_12-00-00/scenario-matrix.json"
jq '
    .tasks[0].strategy.repeated_failure_count = 1
    | .tasks[0].health.stuck_score = 1
' "$MATRIX_FILE" > "$MATRIX_FILE.tmp" && mv "$MATRIX_FILE.tmp" "$MATRIX_FILE"
create_mock_codex "$TEST_DIR/repo-hook-oversight/bin" "## Review Feedback

Mainline Progress Verdict: REGRESSED

The current approach is too broad. Split the recovery into smaller steps before editing more files.

CONTINUE"

echo "$HOOK_INPUT" | PATH="$TEST_DIR/repo-hook-oversight/bin:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR/repo-hook-oversight" bash "$STOP_HOOK" > /dev/null 2>&1 || true

NEXT_PROMPT="$TEST_DIR/repo-hook-oversight/.humanize/rlcr/2024-03-01_12-00-00/round-3-prompt.md"
MATRIX_FILE="$TEST_DIR/repo-hook-oversight/.humanize/rlcr/2024-03-01_12-00-00/scenario-matrix.json"

if [[ -f "$NEXT_PROMPT" ]] && grep -q "Oversight Intervention" "$NEXT_PROMPT" && grep -q 'Action: `split`' "$NEXT_PROMPT"; then
    pass "repeated failures inject oversight intervention into next-round prompt"
else
    fail "repeated failures inject oversight intervention into next-round prompt" "oversight section with split action" "$(cat "$NEXT_PROMPT" 2>/dev/null || echo 'missing prompt')"
fi

if jq -e '
    .oversight.status == "active"
    and .oversight.last_action == "split"
    and .oversight.intervention.action == "split"
    and .oversight.intervention.target_task_id == "task1"
    and .tasks[0].strategy.method_switch_required == true
    and .tasks[0].strategy.repeated_failure_count == 2
    and .tasks[0].health.stuck_score == 2
' "$MATRIX_FILE" >/dev/null 2>&1; then
    pass "repeated failures persist oversight action and task health in matrix"
else
    fail "repeated failures persist oversight action and task health in matrix" "active split intervention with incremented health counters" "$(cat "$MATRIX_FILE" 2>/dev/null || echo 'missing matrix')"
fi

# ========================================
# Test 7: Missing required matrix blocks stop hook
# ========================================

setup_matrix_test_dir
setup_manual_loop_repo "$TEST_DIR/repo-hook-missing" 1 false true
rm -f "$TEST_DIR/repo-hook-missing/.humanize/rlcr/2024-03-01_12-00-00/scenario-matrix.json"
create_mock_codex "$TEST_DIR/repo-hook-missing/bin"

OUTPUT=$(echo "$HOOK_INPUT" | PATH="$TEST_DIR/repo-hook-missing/bin:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR/repo-hook-missing" bash "$STOP_HOOK" 2>&1 || true)
if echo "$OUTPUT" | grep -q "Scenario Matrix Missing"; then
    pass "missing required matrix blocks stop hook"
else
    fail "missing required matrix blocks stop hook" "Scenario Matrix Missing block" "$OUTPUT"
fi

# ========================================
# Test 8: Review-phase follow-up prompt includes scenario matrix re-anchor
# ========================================

setup_matrix_test_dir
setup_manual_loop_repo "$TEST_DIR/repo-hook-review" 4 true true
create_mock_codex "$TEST_DIR/repo-hook-review/bin" "unused" "[P1] Dependency mismatch still breaks review."

echo "$HOOK_INPUT" | PATH="$TEST_DIR/repo-hook-review/bin:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR/repo-hook-review" bash "$STOP_HOOK" > /dev/null 2>&1 || true

NEXT_PROMPT="$TEST_DIR/repo-hook-review/.humanize/rlcr/2024-03-01_12-00-00/round-5-prompt.md"
MATRIX_FILE="$TEST_DIR/repo-hook-review/.humanize/rlcr/2024-03-01_12-00-00/scenario-matrix.json"

if [[ -f "$NEXT_PROMPT" ]] && grep -q "scenario matrix" "$NEXT_PROMPT" && grep -q "Scenario Matrix Re-anchor" "$NEXT_PROMPT" && grep -q 'manager-issued fix scope' "$NEXT_PROMPT"; then
    pass "review-phase follow-up prompt includes scenario matrix guidance"
else
    fail "review-phase follow-up prompt includes scenario matrix guidance" "scenario matrix text in round-5 prompt" "$(cat "$NEXT_PROMPT" 2>/dev/null || echo 'missing prompt')"
fi

if [[ -f "$NEXT_PROMPT" ]] && ! grep -q 'Out Of Scope: task2: Update downstream validator' "$NEXT_PROMPT"; then
    pass "review-phase task packet does not mark blocking in-scope work as out of scope"
else
    fail "review-phase task packet does not mark blocking in-scope work as out of scope" "task packet without blocking task2 in Out Of Scope" "$(cat "$NEXT_PROMPT" 2>/dev/null || echo 'missing prompt')"
fi

if jq -e '.runtime.current_round == 5 and .runtime.last_review.phase == "review" and .runtime.last_review.verdict == "code_review_issues"' "$MATRIX_FILE" >/dev/null 2>&1; then
    pass "review-phase follow-up records review cycle in matrix runtime state"
else
    fail "review-phase follow-up records review cycle in matrix runtime state" "round 5 review-phase runtime state" "$(cat "$MATRIX_FILE" 2>/dev/null || echo 'missing matrix')"
fi

if jq -e '
    (.tasks | length) == 2
    and (
        .tasks[]
        | select(.id == "task2")
        | .state == "blocked"
        and .risk_bucket == "high"
        and .metadata.last_review_finding_key == "dependency-mismatch-still-breaks-review"
        and .metadata.review_finding_keys == ["dependency-mismatch-still-breaks-review"]
    )
    and (.raw_findings | length) == 1
    and (
        .raw_findings[0]
        | .finding_key == "dependency-mismatch-still-breaks-review"
        and .link_task_id == "task2"
        and .cluster_id == "cluster-dependency-contract"
        and .repair_wave_hint == "wave-r5-dependency-contract"
    )
    and (.finding_groups | length) == 0
    and (.feedback.review | length) == 1
    and ([.events[] | select(.type == "review_finding" and .task_id == "task2")] | length) == 1
' "$MATRIX_FILE" >/dev/null 2>&1; then
    pass "review-phase findings annotate linked tasks while keeping review findings out of the task graph"
else
    fail "review-phase findings annotate linked tasks while keeping review findings out of the task graph" "task2 annotated plus one linked raw finding" "$(cat "$MATRIX_FILE" 2>/dev/null || echo 'missing matrix')"
fi

# ========================================
# Test 9: Finalize phase does not require matrix artifact to complete
# ========================================

setup_matrix_test_dir
setup_manual_loop_repo "$TEST_DIR/repo-hook-finalize" 2 false true
LOOP_DIR="$TEST_DIR/repo-hook-finalize/.humanize/rlcr/2024-03-01_12-00-00"
mv "$LOOP_DIR/state.md" "$LOOP_DIR/finalize-state.md"
cat > "$LOOP_DIR/finalize-summary.md" << 'EOF'
# Finalize Summary

Ready to exit.
EOF
rm -f "$LOOP_DIR/scenario-matrix.json"

OUTPUT=$(echo "$HOOK_INPUT" | PATH="$TEST_DIR/repo-hook-finalize/bin:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR/repo-hook-finalize" bash "$STOP_HOOK" 2>&1 || true)
if [[ -f "$LOOP_DIR/complete-state.md" ]] && [[ ! -f "$LOOP_DIR/finalize-state.md" ]] && ! echo "$OUTPUT" | grep -q "Scenario Matrix Missing"; then
    pass "finalize phase ignores missing matrix artifact"
else
    fail "finalize phase ignores missing matrix artifact" "complete-state.md without matrix enforcement block" "$OUTPUT"
fi

# ========================================
# Test 10: Legacy loops do not receive matrix re-anchor instructions
# ========================================

setup_matrix_test_dir
setup_manual_loop_repo "$TEST_DIR/repo-hook-legacy" 2 false false
STATE_FILE="$TEST_DIR/repo-hook-legacy/.humanize/rlcr/2024-03-01_12-00-00/state.md"
grep -v '^scenario_matrix_' "$STATE_FILE" > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
rm -f "$TEST_DIR/repo-hook-legacy/.humanize/rlcr/2024-03-01_12-00-00/scenario-matrix.json"
create_mock_codex "$TEST_DIR/repo-hook-legacy/bin" "## Review Feedback

Mainline Progress Verdict: STALLED

Please tighten the current implementation path.

CONTINUE"

echo "$HOOK_INPUT" | PATH="$TEST_DIR/repo-hook-legacy/bin:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR/repo-hook-legacy" bash "$STOP_HOOK" > /dev/null 2>&1 || true

NEXT_PROMPT="$TEST_DIR/repo-hook-legacy/.humanize/rlcr/2024-03-01_12-00-00/round-3-prompt.md"
if [[ -f "$NEXT_PROMPT" ]] && ! grep -qi "scenario matrix" "$NEXT_PROMPT"; then
    pass "legacy loops omit scenario matrix prompt guidance"
else
    fail "legacy loops omit scenario matrix prompt guidance" "next-round prompt without scenario matrix references" "$(cat "$NEXT_PROMPT" 2>/dev/null || echo 'missing prompt')"
fi

# ========================================
# Test 11: Implementation review findings create structured tasks and watchlist work
# ========================================

setup_matrix_test_dir
setup_manual_loop_repo "$TEST_DIR/repo-hook-impl-findings" 2 false true
create_mock_codex "$TEST_DIR/repo-hook-impl-findings/bin" $'## Review Feedback\n\nMainline Progress Verdict: STALLED\n\n- [P1] Dependency mismatch still breaks review.\n- [P3] Monitor wording nit should stay deferred.\n\nCONTINUE'

echo "$HOOK_INPUT" | PATH="$TEST_DIR/repo-hook-impl-findings/bin:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR/repo-hook-impl-findings" bash "$STOP_HOOK" > /dev/null 2>&1 || true

MATRIX_FILE="$TEST_DIR/repo-hook-impl-findings/.humanize/rlcr/2024-03-01_12-00-00/scenario-matrix.json"
if jq -e '
    (.runtime.last_review.phase == "implementation")
    and (
        .tasks[]
        | select(.id == "task2")
        | .state == "blocked"
        and .risk_bucket == "high"
        and .metadata.last_review_finding_key == "dependency-mismatch-still-breaks-review"
    )
    and (.raw_findings | length) == 2
    and ([.raw_findings[] | select(.link_task_id == "task2" and .finding_key == "dependency-mismatch-still-breaks-review")] | length) == 1
    and ([.raw_findings[] | select(.admission_status == "watchlist" and .state == "deferred" and .finding_key == "monitor-wording-nit-should-stay-deferred")] | length) == 1
    and ([.finding_groups[] | select(.state == "deferred" and .surface_key == "docs-cleanup")] | length) == 1
    and (.feedback.review | length) == 2
    and ([.events[] | select(.type == "review_finding")] | length) == 2
' "$MATRIX_FILE" >/dev/null 2>&1; then
    pass "implementation review findings annotate linked tasks and defer grouped backlog entries"
else
    fail "implementation review findings annotate linked tasks and defer grouped backlog entries" "linked blocking finding plus deferred cleanup backlog" "$(cat "$MATRIX_FILE" 2>/dev/null || echo 'missing matrix')"
fi

# ========================================
# Test 12: Repeated findings dedupe and deferred projection stay stable
# ========================================

setup_matrix_test_dir
setup_manual_loop_repo "$TEST_DIR/repo-finding-dedupe" 2 false true
LOOP_DIR="$TEST_DIR/repo-finding-dedupe/.humanize/rlcr/2024-03-01_12-00-00"
GOAL_TRACKER_FILE="$LOOP_DIR/goal-tracker.md"
cat >> "$GOAL_TRACKER_FILE" << 'EOF'

### Completed and Verified
| AC | Task | Completed Round | Verified Round | Evidence |
|----|------|-----------------|----------------|----------|

### Explicitly Deferred
| Task | Original AC | Deferred Since | Justification | When to Reconsider |
|------|-------------|----------------|---------------|-------------------|
EOF

MATRIX_FILE="$LOOP_DIR/scenario-matrix.json"
REVIEW_FINDINGS=$'[P1] Dependency mismatch still breaks review.\n[P3] Monitor wording nit should stay deferred.'
scenario_matrix_ingest_review_findings "$MATRIX_FILE" 4 "review" "$REVIEW_FINDINGS"
scenario_matrix_ingest_review_findings "$MATRIX_FILE" 5 "review" "$REVIEW_FINDINGS"
scenario_matrix_sync_goal_tracker "$MATRIX_FILE" "$GOAL_TRACKER_FILE"

if jq -e '
    (.tasks | length) == 2
    and (.raw_findings | length) == 2
    and ([.raw_findings[] | select(.finding_key == "dependency-mismatch-still-breaks-review" and .occurrence_count == 2 and .link_task_id == "task2")] | length) == 1
    and ([.raw_findings[] | select(.finding_key == "monitor-wording-nit-should-stay-deferred" and .occurrence_count == 2 and .admission_status == "watchlist")] | length) == 1
    and ([.finding_groups[] | select(.state == "deferred" and .finding_count == 1)] | length) == 1
' "$MATRIX_FILE" >/dev/null 2>&1; then
    pass "repeated findings dedupe into raw findings without duplicating executable tasks"
else
    fail "repeated findings dedupe into raw findings without duplicating executable tasks" "two raw findings with occurrence_count=2 and one deferred backlog group" "$(cat "$MATRIX_FILE" 2>/dev/null || echo 'missing matrix')"
fi

if grep -q '^### Explicitly Deferred$' "$GOAL_TRACKER_FILE" && grep -q 'Monitor wording nit should stay deferred' "$GOAL_TRACKER_FILE"; then
    pass "deferred watchlist tasks project into the goal tracker deferred section"
else
    fail "deferred watchlist tasks project into the goal tracker deferred section" "deferred section containing the watchlist finding" "$(cat "$GOAL_TRACKER_FILE" 2>/dev/null || echo 'missing tracker')"
fi

if grep -q 'Docs cleanup backlog for Repair parser contract | AC-1 | 4 |' "$GOAL_TRACKER_FILE"; then
    pass "deferred tracker projection preserves the original defer round"
else
    fail "deferred tracker projection preserves the original defer round" "deferred row with Deferred Since = 4" "$(cat "$GOAL_TRACKER_FILE" 2>/dev/null || echo 'missing tracker')"
fi

# ========================================
# Test 12b: Linked watchlist findings still project into grouped deferred backlog
# ========================================

setup_matrix_test_dir
setup_manual_loop_repo "$TEST_DIR/repo-linked-watchlist-finding" 2 false true
LOOP_DIR="$TEST_DIR/repo-linked-watchlist-finding/.humanize/rlcr/2024-03-01_12-00-00"
MATRIX_FILE="$LOOP_DIR/scenario-matrix.json"
GOAL_TRACKER_FILE="$LOOP_DIR/goal-tracker.md"

cat >> "$GOAL_TRACKER_FILE" << 'EOF'

### Completed and Verified
| AC | Task | Completed Round | Verified Round | Evidence |
|----|------|-----------------|----------------|----------|

### Explicitly Deferred
| Task | Original AC | Deferred Since | Justification | When to Reconsider |
|------|-------------|----------------|---------------|-------------------|
EOF

scenario_matrix_ingest_review_findings "$MATRIX_FILE" 4 "review" "[P3] task2 wording nit should stay deferred."
scenario_matrix_sync_goal_tracker "$MATRIX_FILE" "$GOAL_TRACKER_FILE"

if jq -e '
    (.tasks | length) == 2
    and ([.raw_findings[] | select(.link_task_id == "task2" and .admission_status == "watchlist" and .state == "deferred")] | length) == 1
    and ([.finding_groups[] | select(.state == "deferred" and .related_task_ids == ["task2"] and .surface_key == "docs-cleanup")] | length) == 1
    and ([.feedback.review[] | select(.task_id == "task2" and .kind == "watchlist_finding")] | length) == 1
    and (
        .tasks[]
        | select(.id == "task2")
        | .state == "pending"
        and .risk_bucket == "planned"
        and .metadata.last_review_finding_key == "task2-wording-nit-should-stay-deferred"
    )
' "$MATRIX_FILE" >/dev/null 2>&1; then
    pass "linked watchlist findings stay non-authoritative while still projecting into grouped deferred backlog"
else
    fail "linked watchlist findings stay non-authoritative while still projecting into grouped deferred backlog" "one linked watchlist raw finding plus one deferred finding group for task2" "$(cat "$MATRIX_FILE" 2>/dev/null || echo 'missing matrix')"
fi

if grep -q 'Docs cleanup backlog for Update downstream validator' "$GOAL_TRACKER_FILE"; then
    pass "linked watchlist grouped backlog is visible in the goal tracker deferred section"
else
    fail "linked watchlist grouped backlog is visible in the goal tracker deferred section" "goal tracker deferred row for linked watchlist backlog" "$(cat "$GOAL_TRACKER_FILE" 2>/dev/null || echo 'missing tracker')"
fi

# ========================================
# Test 13: Ambiguous dependency findings stay as standalone bounded work
# ========================================

setup_matrix_test_dir
setup_manual_loop_repo "$TEST_DIR/repo-finding-ambiguous" 2 false true
MATRIX_FILE="$TEST_DIR/repo-finding-ambiguous/.humanize/rlcr/2024-03-01_12-00-00/scenario-matrix.json"

jq '
    .metadata.seed_task_count = 3
    | .tasks += [{
        id: "task3",
        title: "Refresh downstream serializer",
        lane: "supporting",
        routing: "coding",
        owner: null,
        scope: {
          summary: "",
          paths: [],
          constraints: []
        },
        cluster_id: null,
        repair_wave: null,
        risk_bucket: "planned",
        admission: {
          status: "active",
          reason: "fixture"
        },
        authority: {
          write_mode: "manager_only",
          authoritative_source: "manager"
        },
        target_ac: ["AC-1"],
        depends_on: ["task1"],
        state: "pending",
        assumptions: [],
        strategy: {
          current: "refresh-serializer",
          attempt_count: 0,
          repeated_failure_count: 0,
          method_switch_required: false
        },
        health: {
          stuck_score: 0,
          last_progress_round: 0
        },
        metadata: {
          seed_source: "fixture"
        }
    }]
' "$MATRIX_FILE" > "$MATRIX_FILE.tmp" && mv "$MATRIX_FILE.tmp" "$MATRIX_FILE"

scenario_matrix_ingest_review_findings "$MATRIX_FILE" 4 "review" "[P1] Downstream dependency mismatch still breaks review."

if jq -e '
    (.tasks | length) == 3
    and ([.tasks[] | select(.id == "task2" or .id == "task3") | select((.metadata.last_review_finding_key // null) == null)] | length) == 2
    and (.raw_findings | length) == 1
    and (
        .raw_findings[0]
        | .finding_key == "downstream-dependency-mismatch-still-breaks-review"
        and .related_task_id == null
        and .link_task_id == null
        and .state == "blocked"
        and .depends_on == ["task1"]
    )
    and ([.finding_groups[] | select(.state == "blocked" and .related_task_ids == [])] | length) == 1
    and ([.feedback.review[] | select(.task_id == null and .kind == "structured_finding")] | length) == 1
' "$MATRIX_FILE" >/dev/null 2>&1; then
    pass "ambiguous dependency findings stay in grouped backlog instead of mutating an arbitrary dependent"
else
    fail "ambiguous dependency findings stay in grouped backlog instead of mutating an arbitrary dependent" "unchanged task2/task3 plus one blocked raw finding group" "$(cat "$MATRIX_FILE" 2>/dev/null || echo 'missing matrix')"
fi

# ========================================
# Test 13b: Explicit descriptive task ids link findings back to existing tasks
# ========================================

setup_matrix_test_dir
setup_manual_loop_repo "$TEST_DIR/repo-finding-explicit-id" 2 false true
MATRIX_FILE="$TEST_DIR/repo-finding-explicit-id/.humanize/rlcr/2024-03-01_12-00-00/scenario-matrix.json"

jq '
    .manager.current_primary_task_id = "parser-fix"
    | .runtime.checkpoint.primary_task_id = "parser-fix"
    | .tasks[0].id = "parser-fix"
    | .tasks[1].id = "validator-sync"
    | .tasks[1].depends_on = ["parser-fix"]
' "$MATRIX_FILE" > "$MATRIX_FILE.tmp" && mv "$MATRIX_FILE.tmp" "$MATRIX_FILE"

scenario_matrix_ingest_review_findings "$MATRIX_FILE" 4 "review" "[P1] parser-fix still breaks review."

if jq -e '
    (.tasks | length) == 2
    and (
        .tasks[]
        | select(.id == "parser-fix")
        | .lane == "mainline"
        and .state == "blocked"
        and .risk_bucket == "high"
        and .metadata.last_review_finding_key == "parser-fix-still-breaks-review"
    )
    and ([.events[] | select(.task_id == "parser-fix" and .type == "review_finding")] | length) == 1
    and ([.raw_findings[] | select(.link_task_id == "parser-fix" and .finding_key == "parser-fix-still-breaks-review")] | length) == 1
    and (.finding_groups | length) == 0
    and ([.feedback.review[] | select(.task_id == "parser-fix" and .kind == "structured_finding")] | length) == 1
' "$MATRIX_FILE" >/dev/null 2>&1; then
    pass "explicit descriptive task ids annotate the referenced existing task without creating grouped backlog work"
else
    fail "explicit descriptive task ids annotate the referenced existing task without creating grouped backlog work" "parser-fix updated in place with one linked raw finding and no finding group" "$(cat "$MATRIX_FILE" 2>/dev/null || echo 'missing matrix')"
fi

# ========================================
# Test 13c: Legitimate task ids that start with finding-r are not migrated away
# ========================================

setup_matrix_test_dir
setup_manual_loop_repo "$TEST_DIR/repo-finding-prefix-plan-task" 2 false true
MATRIX_FILE="$TEST_DIR/repo-finding-prefix-plan-task/.humanize/rlcr/2024-03-01_12-00-00/scenario-matrix.json"

jq '
    .manager.current_primary_task_id = "finding-rules"
    | .runtime.checkpoint.primary_task_id = "finding-rules"
    | .tasks[0].id = "finding-rules"
    | .tasks[0].title = "Define finding rules"
    | .tasks[0].metadata.seed_source = "plan_task"
    | .tasks[0].source = "plan"
' "$MATRIX_FILE" > "$MATRIX_FILE.tmp" && mv "$MATRIX_FILE.tmp" "$MATRIX_FILE"

scenario_matrix_ingest_review_findings "$MATRIX_FILE" 4 "review" "[P1] task2 dependency mismatch still breaks review."

if jq -e '
    (.tasks | length) == 2
    and ([.tasks[] | select(.id == "finding-rules" and .title == "Define finding rules")] | length) == 1
    and ([.tasks[] | select(.id == "task2" and .state == "blocked")] | length) == 1
    and ([.raw_findings[] | select(.link_task_id == "task2" and .finding_key == "task2-dependency-mismatch-still-breaks-review")] | length) == 1
' "$MATRIX_FILE" >/dev/null 2>&1; then
    pass "plan tasks with finding-r prefixes stay in the executable task graph during review ingestion"
else
    fail "plan tasks with finding-r prefixes stay in the executable task graph during review ingestion" "finding-rules still present as a plan task plus one linked raw finding for task2" "$(cat "$MATRIX_FILE" 2>/dev/null || echo 'missing matrix')"
fi

# ========================================
# Test 13d: Supporting-window tasks do not also appear as queued out-of-scope work
# ========================================

setup_matrix_test_dir
setup_manual_loop_repo "$TEST_DIR/repo-contract-supporting-window" 2 false true
MATRIX_FILE="$TEST_DIR/repo-contract-supporting-window/.humanize/rlcr/2024-03-01_12-00-00/scenario-matrix.json"

jq '
    .tasks[0].repair_wave = "wave-r2-parser-contract"
    | .tasks[1].repair_wave = "wave-r2-parser-contract"
    | .tasks[1].state = "ready"
    | .tasks[1].lane = "queued"
' "$MATRIX_FILE" > "$MATRIX_FILE.tmp" && mv "$MATRIX_FILE.tmp" "$MATRIX_FILE"

scenario_matrix_reconcile_manager_state "$MATRIX_FILE" 2 "supporting_window_projection"
CONTRACT_OUTPUT=$(scenario_matrix_render_round_contract "$MATRIX_FILE" 2 "implementation")

if echo "$CONTRACT_OUTPUT" | grep -q 'Supporting Window In Scope: task2: Update downstream validator' && \
   ! echo "$CONTRACT_OUTPUT" | grep -q 'Queued Side Issues Out of Scope: .*task2: Update downstream validator'; then
    pass "round contract excludes supporting-window tasks from queued out-of-scope projection"
else
    fail "round contract excludes supporting-window tasks from queued out-of-scope projection" "task2 only listed in Supporting Window In Scope" "$CONTRACT_OUTPUT"
fi

# ========================================
# Test 14: Monitor helper reports matrix and legacy status safely
# ========================================

VALID_SESSION_DIR=$(find "$REPO_VALID_DIR/.humanize/rlcr" -mindepth 1 -maxdepth 1 -type d | head -1)
VALID_STATE_FILE="$VALID_SESSION_DIR/state.md"
VALID_MONITOR_OUTPUT=$(SESSION_DIR="$VALID_SESSION_DIR" STATE_FILE="$VALID_STATE_FILE" HUMANIZE_SCRIPT="$HUMANIZE_SCRIPT" bash -lc 'source "$HUMANIZE_SCRIPT"; humanize_parse_scenario_matrix "$SESSION_DIR" "$STATE_FILE"')

if echo "$VALID_MONITOR_OUTPUT" | grep -q '^ready|2|task1 - Implement parser \[state=ready, routing=coding\]|idle|none|checkpoint-1|continue|advance_checkpoint|none$'; then
    pass "monitor helper reports ready matrix state, checkpoint, and convergence for new loops"
else
    fail "monitor helper reports ready matrix state, checkpoint, and convergence for new loops" "ready matrix snapshot with checkpoint and convergence fields" "$VALID_MONITOR_OUTPUT"
fi

setup_matrix_test_dir
setup_manual_loop_repo "$TEST_DIR/repo-monitor-legacy" 2 false false
LEGACY_SESSION_DIR="$TEST_DIR/repo-monitor-legacy/.humanize/rlcr/2024-03-01_12-00-00"
LEGACY_STATE_FILE="$LEGACY_SESSION_DIR/state.md"
grep -v '^scenario_matrix_' "$LEGACY_STATE_FILE" > "$LEGACY_STATE_FILE.tmp" && mv "$LEGACY_STATE_FILE.tmp" "$LEGACY_STATE_FILE"
rm -f "$LEGACY_SESSION_DIR/scenario-matrix.json"
LEGACY_MONITOR_OUTPUT=$(SESSION_DIR="$LEGACY_SESSION_DIR" STATE_FILE="$LEGACY_STATE_FILE" HUMANIZE_SCRIPT="$HUMANIZE_SCRIPT" bash -lc 'source "$HUMANIZE_SCRIPT"; humanize_parse_scenario_matrix "$SESSION_DIR" "$STATE_FILE"')

if echo "$LEGACY_MONITOR_OUTPUT" | grep -q '^legacy|0|Legacy loop without scenario matrix\.|idle|none|n/a|legacy|n/a|none$'; then
    pass "monitor helper treats pre-matrix loops as legacy instead of missing"
else
    fail "monitor helper treats pre-matrix loops as legacy instead of missing" "legacy matrix snapshot" "$LEGACY_MONITOR_OUTPUT"
fi


print_test_summary "Scenario Matrix Foundation Tests"
