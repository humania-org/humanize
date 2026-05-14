#!/usr/bin/env bash
#
# Tests for explore-idea command structural requirements.
#
# Verifies the explore-idea command file contains:
#   - Required allowed tools
#   - All six workflow phases
#   - Hard constraints
#   - Two-tier report structure
#   - Correct validation script invocation
#   - Worker dispatch via Agent with isolation: "worktree"
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

EXPLORE_CMD="$PROJECT_ROOT/commands/explore-idea.md"
VALIDATE_IO_SCRIPT="$PROJECT_ROOT/scripts/validate-explore-idea-io.sh"
REPORT_TEMPLATE="$PROJECT_ROOT/prompt-template/explore/report-template.md"
FINAL_IDEA_TEMPLATE="$PROJECT_ROOT/prompt-template/explore/final-idea-template.md"

echo "=========================================="
echo "explore-idea Command Structure Tests"
echo "=========================================="
echo ""

echo "--- Command File Existence ---"
echo ""

if [[ -f "$EXPLORE_CMD" ]]; then
    pass "commands/explore-idea.md exists"
else
    fail "commands/explore-idea.md exists" "file found" "not found"
fi

if [[ -f "$VALIDATE_IO_SCRIPT" ]]; then
    pass "scripts/validate-explore-idea-io.sh exists"
else
    fail "scripts/validate-explore-idea-io.sh exists" "file found" "not found"
fi

echo ""
echo "--- Allowed Tools ---"
echo ""

# validate-explore-idea-io.sh in allowed-tools
if grep -q "validate-explore-idea-io.sh" "$EXPLORE_CMD"; then
    pass "validate-explore-idea-io.sh in allowed-tools"
else
    fail "validate-explore-idea-io.sh in allowed-tools"
fi

# validate-directions-json.sh in allowed-tools
if grep -q "validate-directions-json.sh" "$EXPLORE_CMD"; then
    pass "validate-directions-json.sh in allowed-tools"
else
    fail "validate-directions-json.sh in allowed-tools"
fi

# Agent tool in allowed-tools
if grep -q '"Agent"' "$EXPLORE_CMD"; then
    pass "Agent tool in allowed-tools"
else
    fail "Agent tool in allowed-tools"
fi

# Write tool in allowed-tools (for manifest and report)
if grep -q '"Write"' "$EXPLORE_CMD"; then
    pass "Write tool in allowed-tools"
else
    fail "Write tool in allowed-tools"
fi

# Read tool in allowed-tools
if grep -q '"Read"' "$EXPLORE_CMD"; then
    pass "Read tool in allowed-tools"
else
    fail "Read tool in allowed-tools"
fi

# jq in allowed-tools (Phase 5 coordinator JSON parsing)
if grep -q '"Bash(jq \*)"\|Bash(jq' "$EXPLORE_CMD"; then
    pass "jq in allowed-tools"
else
    fail "jq in allowed-tools"
fi

# AskUserQuestion in allowed-tools (Phase 2 confirmation)
if grep -q '"AskUserQuestion"' "$EXPLORE_CMD"; then
    pass "AskUserQuestion in allowed-tools"
else
    fail "AskUserQuestion in allowed-tools"
fi

echo ""
echo "--- Workflow Phases ---"
echo ""

# All 6 workflow phases present
PHASES=(
    "Phase 1"
    "Phase 2"
    "Phase 3"
    "Phase 4"
    "Phase 5"
    "Phase 6"
)
for phase in "${PHASES[@]}"; do
    if grep -q "$phase" "$EXPLORE_CMD"; then
        pass "workflow contains $phase"
    else
        fail "workflow contains $phase" "$phase in command" "not found"
    fi
done

echo ""
echo "--- Hard Constraints ---"
echo ""

# Hard constraints section exists
if grep -q "Hard Constraints" "$EXPLORE_CMD"; then
    pass "Hard Constraints section present"
else
    fail "Hard Constraints section present"
fi

# No remote push constraint
if grep -q "MUST NOT push" "$EXPLORE_CMD" || grep -q "push.*remote" "$EXPLORE_CMD"; then
    pass "constraint: no remote push"
else
    fail "constraint: no remote push"
fi

# Manifest written before dispatch
if grep -q "MUST write.*manifest" "$EXPLORE_CMD" || grep -q "BEFORE.*dispatch\|manifest.*BEFORE" "$EXPLORE_CMD"; then
    pass "constraint: manifest written before dispatch"
else
    fail "constraint: manifest written before dispatch"
fi

# No nested skills
if grep -q "nested Skills\|nested.*skill" "$EXPLORE_CMD"; then
    pass "constraint: no nested skills"
else
    fail "constraint: no nested skills"
fi

# Worker confirmation required before dispatch
if grep -q "explicit.*confirm\|Proceed.*\[y/N\]\|\[y/N\]" "$EXPLORE_CMD"; then
    pass "user confirmation required before dispatch"
else
    fail "user confirmation required before dispatch"
fi

echo ""
echo "--- Worker Dispatch Pattern ---"
echo ""

# Worker dispatch uses isolation: "worktree"
if grep -q 'isolation.*worktree\|worktree.*isolation' "$EXPLORE_CMD"; then
    pass "worker dispatch uses isolation: worktree"
else
    fail "worker dispatch uses isolation: worktree"
fi

# Single Agent-tool message (parallel dispatch)
if grep -q "single Agent-tool message\|single.*Agent.*message" "$EXPLORE_CMD"; then
    pass "parallel dispatch documented as single Agent-tool message"
else
    fail "parallel dispatch as single Agent-tool message"
fi

# Worker branch naming
if grep -q "explore/<RUN_ID>/<dir_slug>" "$EXPLORE_CMD"; then
    pass "worker branch naming format documented"
else
    fail "worker branch naming format documented" "explore/<RUN_ID>/<dir_slug>" "not found"
fi

echo ""
echo "--- Result Collection ---"
echo ""

# Sentinel-based result parsing
if grep -q "EXPLORE_RESULT_JSON_BEGIN" "$EXPLORE_CMD"; then
    pass "result collection uses EXPLORE_RESULT_JSON_BEGIN sentinel"
else
    fail "result collection uses sentinel markers"
fi

# worker-results.jsonl append
if grep -q "worker-results.jsonl" "$EXPLORE_CMD"; then
    pass "results appended to worker-results.jsonl"
else
    fail "results appended to worker-results.jsonl"
fi

echo ""
echo "--- Report Template Structure ---"
echo ""

# Two-tier report
if grep -q "Tier 1" "$EXPLORE_CMD" && grep -q "Tier 2" "$EXPLORE_CMD"; then
    pass "two-tier report structure documented in command"
else
    fail "two-tier report structure in command" "Tier 1 + Tier 2" "not found"
fi

# Report template placeholders
REPORT_PLACEHOLDERS=(
    "<RUN_ID>"
    "<BASE_BRANCH>"
    "<BASE_COMMIT>"
    "<CREATED_AT>"
    "<REPORT_PATH>"
    "<FINAL_IDEA_PATH>"
    "<SUMMARY_PARAGRAPH>"
    "<PRODUCT_DIRECTION_RANKING_ROWS>"
    "<PRODUCT_DIRECTION_RATIONALE>"
    "<IMPLEMENTATION_RANKING_ROWS>"
    "<IMPLEMENTATION_RANKING_RATIONALE>"
    "<WORKER_RESULT_ENTRIES>"
    "<WINNER_WORKTREE_PATH>"
    "<WINNER_BRANCH_NAME>"
    "<WINNER_COMMIT_SHA>"
    "<COMMIT_SHA>"
    "<CLEANUP_COMMANDS>"
    "<ALL_WORKER_DETAILS>"
    "<ALL_WORKTREE_REMOVE_COMMANDS>"
    "<ALL_BRANCH_DELETE_COMMANDS>"
)
for placeholder in "${REPORT_PLACEHOLDERS[@]}"; do
    if grep -q "$placeholder" "$REPORT_TEMPLATE"; then
        pass "report template contains placeholder $placeholder"
    else
        fail "report template contains $placeholder" "$placeholder" "not found"
    fi
done

if [[ -f "$FINAL_IDEA_TEMPLATE" ]]; then
    pass "final-idea-template.md exists"
else
    fail "final-idea-template.md exists" "file found" "not found"
fi

if [[ -f "$FINAL_IDEA_TEMPLATE" ]] \
        && grep -q "Final Recommendation" "$FINAL_IDEA_TEMPLATE" \
        && grep -q "Explore Outcomes" "$FINAL_IDEA_TEMPLATE" \
        && grep -q "Suggested Productization Flow" "$FINAL_IDEA_TEMPLATE"; then
    pass "final-idea template provides gen-plan-ready synthesis"
else
    fail "final-idea template provides gen-plan-ready synthesis" \
        "Final Recommendation + Explore Outcomes + Suggested Productization Flow" \
        "missing"
fi

FINAL_IDEA_PLACEHOLDERS=(
    "<TITLE>"
    "<RUN_ID>"
    "<DIRECTIONS_JSON_FILE>"
    "<REPORT_PATH>"
    "<FINAL_IDEA_PATH>"
    "<FINAL_RECOMMENDATION>"
    "<RATIONALE>"
    "<APPROACH_SUMMARY>"
    "<OBJECTIVE_EVIDENCE>"
    "<EXPLORE_OUTCOMES>"
    "<CONSTRAINTS>"
    "<KNOWN_RISKS>"
    "<CROSS_DIRECTION_LEARNINGS>"
)

ALL_FINAL_PLACEHOLDERS_DOCUMENTED=true
for placeholder in "${FINAL_IDEA_PLACEHOLDERS[@]}"; do
    if ! grep -q "$placeholder" "$FINAL_IDEA_TEMPLATE"; then
        ALL_FINAL_PLACEHOLDERS_DOCUMENTED=false
        fail "final-idea template contains placeholder $placeholder"
        break
    fi
    if ! grep -q "$placeholder" "$EXPLORE_CMD"; then
        ALL_FINAL_PLACEHOLDERS_DOCUMENTED=false
        fail "explore command documents final-idea placeholder $placeholder"
        break
    fi
done
if [[ "$ALL_FINAL_PLACEHOLDERS_DOCUMENTED" == "true" ]]; then
    pass "final-idea placeholders are present in template and documented in command"
fi

if grep -q "/humanize:gen-plan --input <FINAL_IDEA_PATH>" "$REPORT_TEMPLATE"; then
    pass "report template points gen-plan at final-idea.md"
else
    fail "report template points gen-plan at final-idea.md" \
        "/humanize:gen-plan --input <FINAL_IDEA_PATH>" \
        "missing"
fi

if grep -q "/humanize:gen-plan --input <FINAL_IDEA_PATH>" "$FINAL_IDEA_TEMPLATE" \
        && grep -q "/humanize:start-rlcr-loop <plan-path>" "$FINAL_IDEA_TEMPLATE"; then
    pass "final-idea template includes full clean productization flow"
else
    fail "final-idea template includes full clean productization flow" \
        "gen-plan plus start-rlcr-loop <plan-path>" \
        "missing"
fi

if grep -q "/humanize:gen-plan --input \\.humanize/explore/<run-id>/final-idea\\.md" "$PROJECT_ROOT/docs/usage.md" \
        && grep -q "/humanize:start-rlcr-loop docs/plan\\.md" "$PROJECT_ROOT/docs/usage.md"; then
    pass "usage docs show default post-explore productization flow"
else
    fail "usage docs show default post-explore productization flow" \
        "gen-plan final-idea.md then start-rlcr-loop docs/plan.md" \
        "missing"
fi

GEN_PLAN_LINE=$(grep -n "Generate Plan From Final Idea" "$REPORT_TEMPLATE" | head -1 | cut -d: -f1 || true)
FAST_PATH_LINE=$(grep -n "Prototype Fast Path" "$REPORT_TEMPLATE" | head -1 | cut -d: -f1 || true)
if [[ -n "$GEN_PLAN_LINE" && -n "$FAST_PATH_LINE" && "$GEN_PLAN_LINE" -lt "$FAST_PATH_LINE" ]] \
        && grep -q "/humanize:start-rlcr-loop <plan-path>" "$REPORT_TEMPLATE"; then
    pass "report template presents clean final-idea plan path before prototype fast path"
else
    fail "report template presents clean final-idea plan path before prototype fast path" \
        "Generate Plan From Final Idea before Prototype Fast Path with start-rlcr-loop <plan-path>" \
        "gen_plan_line=$GEN_PLAN_LINE fast_path_line=$FAST_PATH_LINE"
fi

if grep -q "/humanize:start-rlcr-loop --skip-impl" "$EXPLORE_CMD"; then
    pass "explore command adoption path uses skip-impl when no plan file is supplied"
else
    fail "explore command adoption path uses skip-impl when no plan file is supplied" \
        "/humanize:start-rlcr-loop --skip-impl" \
        "missing"
fi

if grep -q 'first literal `": "`' "$EXPLORE_CMD"; then
    pass "explore command documents first-colon KEY: value parsing"
else
    fail "explore command documents first-colon KEY: value parsing" \
        'first literal ": "' \
        "missing"
fi

echo ""
echo "--- Validate-explore-idea-io.sh Script Structure ---"
echo ""

# Script has all required exit codes documented
for code in 1 2 3 4 5 6 7 8 9; do
    if grep -q "exit $code" "$VALIDATE_IO_SCRIPT"; then
        pass "validate-explore-idea-io.sh has exit $code"
    else
        fail "validate-explore-idea-io.sh has exit $code"
    fi
done

# VALIDATION_SUCCESS emitted on success
if grep -q "VALIDATION_SUCCESS" "$VALIDATE_IO_SCRIPT"; then
    pass "validate-explore-idea-io.sh emits VALIDATION_SUCCESS on success"
else
    fail "validate-explore-idea-io.sh emits VALIDATION_SUCCESS"
fi

echo ""
print_test_summary "explore-idea Command Structure Test Summary"
