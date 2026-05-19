#!/usr/bin/env bash
#
# Tests for validate-directions-json.sh — schema version 1 contract enforcement.
#
# Covers all AC-3 positive and negative cases.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

VALIDATE_SCRIPT="$PROJECT_ROOT/scripts/validate-directions-json.sh"
VALID_FIXTURE="$SCRIPT_DIR/fixtures/directions/valid.directions.json"

echo "=========================================="
echo "validate-directions-json.sh Tests"
echo "=========================================="
echo ""

if ! command -v jq &>/dev/null; then
    echo "SKIP: jq not available — skipping all tests"
    exit 0
fi

setup_test_dir

# Helper: create a mutated fixture from valid.directions.json
make_fixture() {
    local name="$1"
    local jq_expr="$2"
    local outfile="$TEST_DIR/${name}.directions.json"
    jq "$jq_expr" "$VALID_FIXTURE" > "$outfile"
    echo "$outfile"
}

# Helper: run the validator on a fixture file
run_validate() {
    bash "$VALIDATE_SCRIPT" "$1"
}

echo "--- Positive Tests ---"
echo ""

# PT-1: Valid fixture passes
EXIT_CODE=0
run_validate "$VALID_FIXTURE" > /dev/null 2>&1 || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "valid fixture: exits 0"
else
    fail "valid fixture: exits 0" "exit 0" "exit=$EXIT_CODE"
fi

echo ""
echo "--- Negative Tests ---"
echo ""

# NT-1: Missing schema_version
F=$(make_fixture "no-schema-version" 'del(.schema_version)')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "missing schema_version: exits non-zero" \
    || fail "missing schema_version: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-2: 11 directions (exceeds max)
F=$(make_fixture "too-many-directions" '
  . as $base |
  .directions = [range(11) | $base.directions[0] | .source_index = .] |
  .directions |= to_entries | .directions |= map(.value.direction_id = ("dir-" + (.key|tostring) + "-x") | .value.dir_slug = ("slug-" + (.key|tostring)) | .value.source_index = .key | .value) |
  .metadata.n_returned = 11
')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "11 directions: exits non-zero" \
    || fail "11 directions: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-3: Two entries with is_primary: true
F=$(make_fixture "two-primary" '.directions |= map(.is_primary = true)')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "two is_primary: exits non-zero" \
    || fail "two is_primary: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-4: Zero entries with is_primary: true
F=$(make_fixture "zero-primary" '.directions |= map(.is_primary = false)')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "zero is_primary: exits non-zero" \
    || fail "zero is_primary: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-5: Duplicate direction_id
F=$(make_fixture "dup-direction-id" '.directions[1].direction_id = .directions[0].direction_id')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "duplicate direction_id: exits non-zero" \
    || fail "duplicate direction_id: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-6: Empty direction_id
F=$(make_fixture "empty-direction-id" '.directions[0].direction_id = ""')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "empty direction_id: exits non-zero" \
    || fail "empty direction_id: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-7: Whitespace-only direction_id
F=$(make_fixture "whitespace-direction-id" '.directions[0].direction_id = "   "')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "whitespace-only direction_id: exits non-zero" \
    || fail "whitespace-only direction_id: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-8: direction_id contains spaces
F=$(make_fixture "spaced-direction-id" '.directions[0].direction_id = "dir 00 command history"')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "direction_id with spaces: exits non-zero" \
    || fail "direction_id with spaces: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-9: Duplicate dir_slug
F=$(make_fixture "dup-dir-slug" '.directions[1].dir_slug = .directions[0].dir_slug')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "duplicate dir_slug: exits non-zero" \
    || fail "duplicate dir_slug: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-10: Duplicate source_index
F=$(make_fixture "dup-source-index" '.directions[1].source_index = .directions[0].source_index')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "duplicate source_index: exits non-zero" \
    || fail "duplicate source_index: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-11: display_order is a string (not integer)
F=$(make_fixture "display-order-string" '.directions[0].display_order = "zero"')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "display_order string: exits non-zero" \
    || fail "display_order string: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-12: dir_slug contains uppercase
F=$(make_fixture "dir-slug-uppercase" '.directions[0].dir_slug = "CommandHistory"')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "dir_slug uppercase: exits non-zero" \
    || fail "dir_slug uppercase: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-13: dir_slug contains spaces
F=$(make_fixture "dir-slug-space" '.directions[0].dir_slug = "command history"')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "dir_slug with spaces: exits non-zero" \
    || fail "dir_slug with spaces: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-14: Missing required per-direction field (name)
F=$(make_fixture "missing-name" '.directions[0] |= del(.name)')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "missing direction.name: exits non-zero" \
    || fail "missing direction.name: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-15: objective_evidence is not an array
F=$(make_fixture "evidence-not-array" '.directions[0].objective_evidence = "single string"')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "objective_evidence not array: exits non-zero" \
    || fail "objective_evidence not array: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-16: known_risks is not an array
F=$(make_fixture "risks-not-array" '.directions[0].known_risks = "single string"')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "known_risks not array: exits non-zero" \
    || fail "known_risks not array: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-17: Invalid confidence value
F=$(make_fixture "bad-confidence" '.directions[0].confidence = "maybe"')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "invalid confidence: exits non-zero" \
    || fail "invalid confidence: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-18: metadata.n_returned mismatch
F=$(make_fixture "n-returned-mismatch" '.metadata.n_returned = 99')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "n_returned mismatch: exits non-zero" \
    || fail "n_returned mismatch: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-19: Missing required top-level key (directions)
F=$(make_fixture "missing-directions-key" 'del(.directions)')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "missing .directions key: exits non-zero" \
    || fail "missing .directions key: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-20: Missing required top-level key (title)
F=$(make_fixture "missing-title-key" 'del(.title)')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "missing .title key: exits non-zero" \
    || fail "missing .title key: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-21: Missing required top-level key (original_idea)
F=$(make_fixture "missing-original-idea" 'del(.original_idea)')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "missing .original_idea key: exits non-zero" \
    || fail "missing .original_idea key: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-22: Missing required top-level key (metadata)
F=$(make_fixture "missing-metadata" 'del(.metadata)')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "missing .metadata key: exits non-zero" \
    || fail "missing .metadata key: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-23: Missing direction_id (per-direction required field)
F=$(make_fixture "missing-direction-id" '.directions[0] |= del(.direction_id)')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "missing direction_id: exits non-zero" \
    || fail "missing direction_id: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-24: source_index is a string (not integer)
F=$(make_fixture "source-index-string" '.directions[0].source_index = "0"')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "string source_index: exits non-zero" \
    || fail "string source_index: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-25: title is not a string (numeric type)
F=$(make_fixture "title-numeric" '.title = 123')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "numeric title: exits non-zero" \
    || fail "numeric title: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-26: objective_evidence items are not strings (numeric array)
F=$(make_fixture "evidence-items-numeric" '.directions[0].objective_evidence = [1, 2]')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "numeric objective_evidence items: exits non-zero" \
    || fail "numeric objective_evidence items: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-27: Missing metadata.n_requested
F=$(make_fixture "missing-n-requested" '.metadata |= del(.n_requested)')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "missing metadata.n_requested: exits non-zero" \
    || fail "missing metadata.n_requested: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-28: Missing metadata.timestamp
F=$(make_fixture "missing-timestamp" '.metadata |= del(.timestamp)')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "missing metadata.timestamp: exits non-zero" \
    || fail "missing metadata.timestamp: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-29: Missing metadata.draft_path
F=$(make_fixture "missing-draft-path" '.metadata |= del(.draft_path)')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "missing metadata.draft_path: exits non-zero" \
    || fail "missing metadata.draft_path: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-30: metadata.n_requested lower than returned directions
F=$(make_fixture "n-requested-too-low" '.metadata.n_requested = 1')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "metadata.n_requested below n_returned: exits non-zero" \
    || fail "metadata.n_requested below n_returned: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-31: display_order must be sequential from 0..K
F=$(make_fixture "display-order-gap" '.directions[1].display_order = 2')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "display_order gap: exits non-zero" \
    || fail "display_order gap: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-32: is_primary must be present and boolean on every direction
F=$(make_fixture "missing-alt-is-primary" '.directions[1] |= del(.is_primary)')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "missing alternate is_primary: exits non-zero" \
    || fail "missing alternate is_primary: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-33: direction_id must be derived from source_index and dir_slug
F=$(make_fixture "mismatched-direction-id" '.directions[0].direction_id = "dir-00-wrong"')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "mismatched direction_id derivation: exits non-zero" \
    || fail "mismatched direction_id derivation: exits non-zero" "non-zero" "$EXIT_CODE"

# NT-34: source_index must be within metadata.n_requested
F=$(make_fixture "source-index-out-of-range" '.directions[1].source_index = 4 | .directions[1].direction_id = "dir-04-event-sourcing"')
EXIT_CODE=0
run_validate "$F" > /dev/null 2>&1 || EXIT_CODE=$?
[[ $EXIT_CODE -ne 0 ]] && pass "source_index outside n_requested: exits non-zero" \
    || fail "source_index outside n_requested: exits non-zero" "non-zero" "$EXIT_CODE"

echo ""
print_test_summary "validate-directions-json.sh Test Summary"
