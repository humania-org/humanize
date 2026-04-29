#!/usr/bin/env bash
#
# Tests for validate-explore-idea-io.sh — explore-idea input validation.
#
# Covers:
#   - Exit codes 1-9 for all error conditions
#   - Success: emits VALIDATION_SUCCESS + structured key-value output
#   - Direction selection: default, --directions by id, --directions by source_index
#   - Cap enforcement: concurrency, iterations, timeouts
#   - Dirty checkout hard-fail
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

VALIDATE_SCRIPT="$PROJECT_ROOT/scripts/validate-explore-idea-io.sh"
VALID_FIXTURE="$SCRIPT_DIR/fixtures/directions/valid.directions.json"

echo "=========================================="
echo "validate-explore-idea-io.sh Tests"
echo "=========================================="
echo ""

if ! command -v jq &>/dev/null; then
    skip "jq not available — skipping all tests"
    print_test_summary "validate-explore-idea-io.sh Test Summary"
    exit 0
fi

setup_test_dir

# Create a mock git repo (clean state)
MOCK_REPO="$TEST_DIR/repo"
init_test_git_repo "$MOCK_REPO"

# Copy valid fixture into the mock repo and commit it
cp "$VALID_FIXTURE" "$MOCK_REPO/valid.directions.json"
(cd "$MOCK_REPO" && git add valid.directions.json && git commit -q -m "add directions")

# Create a draft .md alongside the companion
(cd "$MOCK_REPO" && echo "draft content" > draft.md && cp valid.directions.json draft.directions.json && git add draft.md draft.directions.json && git commit -q -m "add draft")

# Set up plugin root with required templates
PLUGIN_ROOT="$TEST_DIR/plugin"
mkdir -p "$PLUGIN_ROOT/scripts"
mkdir -p "$PLUGIN_ROOT/prompt-template/explore"
cp "$PROJECT_ROOT/scripts/validate-directions-json.sh" "$PLUGIN_ROOT/scripts/"
touch "$PLUGIN_ROOT/prompt-template/explore/worker-prompt.md"
touch "$PLUGIN_ROOT/prompt-template/explore/report-template.md"

# Helper: run validation inside the mock repo (clean state)
run_validate() {
    (cd "$MOCK_REPO" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$VALIDATE_SCRIPT" "$@")
}

# ----------------------------------------
# Negative Tests: error exit codes
# ----------------------------------------

echo "--- Negative Tests: error exit codes ---"
echo ""

# Exit 1: missing input
EXIT_CODE=0
run_validate 2>/dev/null || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 1 ]]; then
    pass "exit 1 when no input path provided"
else
    fail "exit 1 when no input path provided" "exit 1" "exit=$EXIT_CODE"
fi

# Exit 2: file not found (.directions.json)
EXIT_CODE=0
run_validate "$MOCK_REPO/nonexistent.directions.json" 2>/dev/null || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 2 ]]; then
    pass "exit 2 when .directions.json not found"
else
    fail "exit 2 when .directions.json not found" "exit 2" "exit=$EXIT_CODE"
fi

# Exit 2: draft .md not found
EXIT_CODE=0
run_validate "$MOCK_REPO/missing.md" 2>/dev/null || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 2 ]]; then
    pass "exit 2 when draft .md not found"
else
    fail "exit 2 when draft .md not found" "exit 2" "exit=$EXIT_CODE"
fi

# Exit 3: .md exists but companion .directions.json missing
ORPHAN_MD="$MOCK_REPO/orphan.md"
echo "no companion" > "$ORPHAN_MD"
(cd "$MOCK_REPO" && git add orphan.md && git commit -q -m "add orphan")
EXIT_CODE=0
run_validate "$ORPHAN_MD" 2>/dev/null || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 3 ]]; then
    pass "exit 3 when companion .directions.json missing for .md"
else
    fail "exit 3 when companion .directions.json missing" "exit 3" "exit=$EXIT_CODE"
fi

# Exit 4: unsupported extension
JUNK_FILE="$MOCK_REPO/idea.txt"
echo "txt" > "$JUNK_FILE"
(cd "$MOCK_REPO" && git add idea.txt && git commit -q -m "add txt")
EXIT_CODE=0
run_validate "$JUNK_FILE" 2>/dev/null || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 4 ]]; then
    pass "exit 4 for unsupported file extension"
else
    fail "exit 4 for unsupported extension" "exit 4" "exit=$EXIT_CODE"
fi

# Exit 5: invalid JSON schema
BAD_JSON_FILE="$TEST_DIR/bad.directions.json"
echo '{"schema_version": 99, "directions": []}' > "$BAD_JSON_FILE"
EXIT_CODE=0
run_validate "$BAD_JSON_FILE" 2>/dev/null || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 5 ]]; then
    pass "exit 5 for invalid directions.json schema"
else
    fail "exit 5 for invalid schema" "exit 5" "exit=$EXIT_CODE"
fi

# Exit 6: --concurrency above cap
EXIT_CODE=0
run_validate "$MOCK_REPO/valid.directions.json" --concurrency 11 2>/dev/null || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 6 ]]; then
    pass "exit 6 when --concurrency exceeds cap (11 > 10)"
else
    fail "exit 6 when concurrency exceeds cap" "exit 6" "exit=$EXIT_CODE"
fi

# Exit 6: --max-worker-iterations above cap
EXIT_CODE=0
run_validate "$MOCK_REPO/valid.directions.json" --max-worker-iterations 4 2>/dev/null || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 6 ]]; then
    pass "exit 6 when --max-worker-iterations exceeds cap (4 > 3)"
else
    fail "exit 6 when max-worker-iterations exceeds cap" "exit 6" "exit=$EXIT_CODE"
fi

# Exit 6: unknown --directions selector
EXIT_CODE=0
run_validate "$MOCK_REPO/valid.directions.json" --directions "dir-99-nonexistent" 2>/dev/null || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 6 ]]; then
    pass "exit 6 for unknown --directions selector"
else
    fail "exit 6 for unknown direction selector" "exit 6" "exit=$EXIT_CODE"
fi

# Exit 6: mixed selector forms that resolve to the same direction_id (regression for post-resolution dedup)
EXIT_CODE=0
run_validate "$MOCK_REPO/valid.directions.json" --directions "1,dir-01-event-sourcing" 2>/dev/null || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 6 ]]; then
    pass "exit 6 for mixed-form selectors resolving to same direction_id"
else
    fail "exit 6 for mixed-form duplicate resolved direction_ids" "exit 6" "exit=$EXIT_CODE"
fi

# Exit 6: unknown option
EXIT_CODE=0
run_validate "$MOCK_REPO/valid.directions.json" --bad-option 2>/dev/null || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 6 ]]; then
    pass "exit 6 for unknown option"
else
    fail "exit 6 for unknown option" "exit 6" "exit=$EXIT_CODE"
fi

# Exit 7: dirty checkout
DIRTY_REPO="$TEST_DIR/dirty-repo"
init_test_git_repo "$DIRTY_REPO"
cp "$VALID_FIXTURE" "$DIRTY_REPO/valid.directions.json"
(cd "$DIRTY_REPO" && git add valid.directions.json && git commit -q -m "add")
cp "$PLUGIN_ROOT/prompt-template/explore/worker-prompt.md" "$DIRTY_REPO/dirty.txt"
# Modify a tracked file to make it dirty
echo "dirty change" >> "$DIRTY_REPO/file.txt"
EXIT_CODE=0
(cd "$DIRTY_REPO" && CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT" bash "$VALIDATE_SCRIPT" "$DIRTY_REPO/valid.directions.json" 2>/dev/null) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 7 ]]; then
    pass "exit 7 for dirty checkout with uncommitted tracked changes"
else
    fail "exit 7 for dirty checkout" "exit 7" "exit=$EXIT_CODE"
fi

# Exit 9: missing worker prompt template
NO_TMPL_PLUGIN="$TEST_DIR/plugin-no-tmpl"
mkdir -p "$NO_TMPL_PLUGIN/scripts"
mkdir -p "$NO_TMPL_PLUGIN/prompt-template/explore"
cp "$PROJECT_ROOT/scripts/validate-directions-json.sh" "$NO_TMPL_PLUGIN/scripts/"
# No worker-prompt.md or report-template.md
EXIT_CODE=0
(cd "$MOCK_REPO" && CLAUDE_PLUGIN_ROOT="$NO_TMPL_PLUGIN" bash "$VALIDATE_SCRIPT" "$MOCK_REPO/valid.directions.json" 2>/dev/null) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 9 ]]; then
    pass "exit 9 when worker prompt template missing"
else
    fail "exit 9 when templates missing" "exit 9" "exit=$EXIT_CODE"
fi

# ----------------------------------------
# Positive Tests: success output
# ----------------------------------------

echo ""
echo "--- Positive Tests: success output ---"
echo ""

# Success: VALIDATION_SUCCESS emitted
EXIT_CODE=0
OUTPUT=$(run_validate "$MOCK_REPO/valid.directions.json" 2>/dev/null) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]] && echo "$OUTPUT" | grep -q "VALIDATION_SUCCESS"; then
    pass "exits 0 with VALIDATION_SUCCESS for valid .directions.json"
else
    fail "exits 0 with VALIDATION_SUCCESS" "exit 0 + VALIDATION_SUCCESS" "exit=$EXIT_CODE"
fi

# Success: all required keys present in output
REQUIRED_KEYS=(
    "DIRECTIONS_JSON_FILE:"
    "RUN_ID:"
    "RUN_DIR:"
    "BASE_BRANCH:"
    "BASE_COMMIT:"
    "SELECTED_DIRECTION_IDS:"
    "EFFECTIVE_CONCURRENCY:"
    "MAX_WORKER_ITERATIONS:"
    "WORKER_TIMEOUT_MIN:"
    "CODEX_TIMEOUT_MIN:"
    "WORKER_PROMPT_TEMPLATE:"
    "REPORT_TEMPLATE:"
)
ALL_KEYS_PRESENT=true
for key in "${REQUIRED_KEYS[@]}"; do
    if ! echo "$OUTPUT" | grep -q "^$key"; then
        ALL_KEYS_PRESENT=false
        fail "success output contains $key"
        break
    fi
done
if [[ "$ALL_KEYS_PRESENT" == "true" ]]; then
    pass "success output contains all required key-value pairs"
fi

# Success: .md draft input resolves companion
EXIT_CODE=0
OUTPUT_MD=$(run_validate "$MOCK_REPO/draft.md" 2>/dev/null) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]] && echo "$OUTPUT_MD" | grep -q "VALIDATION_SUCCESS"; then
    pass "exits 0 for .md input with companion .directions.json"
else
    fail "exits 0 for .md input" "exit 0 + VALIDATION_SUCCESS" "exit=$EXIT_CODE"
fi

# Direction selection by direction_id
EXIT_CODE=0
OUTPUT_DIR=$(run_validate "$MOCK_REPO/valid.directions.json" --directions "dir-00-command-history" 2>/dev/null) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]] && echo "$OUTPUT_DIR" | grep -q "dir-00-command-history"; then
    pass "--directions by direction_id selects the correct direction"
else
    fail "--directions by direction_id" "dir-00-command-history in SELECTED" "exit=$EXIT_CODE"
fi

# Direction selection by source_index
EXIT_CODE=0
OUTPUT_IDX=$(run_validate "$MOCK_REPO/valid.directions.json" --directions "1" 2>/dev/null) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]] && echo "$OUTPUT_IDX" | grep -q "dir-01-event-sourcing"; then
    pass "--directions by source_index resolves to correct direction_id"
else
    fail "--directions by source_index" "dir-01-event-sourcing in SELECTED" "exit=$EXIT_CODE"
fi

# Effective concurrency capped to selected count (1 direction selected, concurrency=6 → effective=1)
EFFECTIVE=$(echo "$OUTPUT_DIR" | grep "^EFFECTIVE_CONCURRENCY:" | sed 's/EFFECTIVE_CONCURRENCY: //')
if [[ "$EFFECTIVE" == "1" ]]; then
    pass "EFFECTIVE_CONCURRENCY capped to selected direction count"
else
    fail "EFFECTIVE_CONCURRENCY capped to direction count" "1" "$EFFECTIVE"
fi

echo ""
print_test_summary "validate-explore-idea-io.sh Test Summary"
