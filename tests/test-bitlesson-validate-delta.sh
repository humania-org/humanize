#!/usr/bin/env bash
#
# Tests for bitlesson-validate-delta.sh validation rules
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

VALIDATOR="$PROJECT_ROOT/scripts/bitlesson-validate-delta.sh"
TEMPLATE_DIR="$PROJECT_ROOT/prompt-template"
TEST_LESSON_ID="BL-20260313-notes-validation"

echo "========================================"
echo "BitLesson Delta Validator Tests"
echo "========================================"
echo ""

make_bitlesson_file() {
    local path="$1"

    mkdir -p "$(dirname "$path")"
    cat > "$path" <<EOF
# BitLesson

Lesson ID: $TEST_LESSON_ID
Title: Validate Notes field
When to apply: When BitLesson Delta validation runs.
Guidance:
- Require a rationale for add/update actions.
EOF
}

make_summary_file() {
    local path="$1"
    local action="$2"
    local notes="$3"

    cat > "$path" <<EOF
# Round Summary

## BitLesson Delta
- Action: $action
- Lesson ID(s): $TEST_LESSON_ID
- Notes: $notes
EOF
}

run_validator() {
    local summary_file="$1"
    local bitlesson_file="$2"

    bash "$VALIDATOR" \
        --summary-file "$summary_file" \
        --bitlesson-file "$bitlesson_file" \
        --bitlesson-relpath ".humanize/bitlesson.md" \
        --allow-empty-none false \
        --template-dir "$TEMPLATE_DIR" \
        --current-round 1
}

assert_blocked() {
    local name="$1"
    local output="$2"

    if echo "$output" | jq -e '.decision == "block"' >/dev/null 2>&1; then
        pass "$name"
    else
        fail "$name" "block decision" "$output"
    fi
}

assert_blocked_with_notes_error() {
    local name="$1"
    local output="$2"

    if echo "$output" | jq -e '.decision == "block"' >/dev/null 2>&1 && echo "$output" | grep -q "Notes"; then
        pass "$name"
    else
        fail "$name" "block decision mentioning Notes" "$output"
    fi
}

assert_passes() {
    local name="$1"
    local output="$2"

    if [[ -z "$output" ]]; then
        pass "$name"
    else
        fail "$name" "no block output" "$output"
    fi
}

setup_test_dir
BITLESSON_FILE="$TEST_DIR/.humanize/bitlesson.md"
make_bitlesson_file "$BITLESSON_FILE"

SUMMARY_FILE="$TEST_DIR/add-empty-notes.md"
make_summary_file "$SUMMARY_FILE" "add" "   "
RESULT=$(run_validator "$SUMMARY_FILE" "$BITLESSON_FILE")
assert_blocked_with_notes_error "add action blocks when Notes is whitespace-only" "$RESULT"

SUMMARY_FILE="$TEST_DIR/update-placeholder-notes.md"
make_summary_file "$SUMMARY_FILE" "update" "[what changed and why]"
RESULT=$(run_validator "$SUMMARY_FILE" "$BITLESSON_FILE")
assert_blocked_with_notes_error "update action blocks when Notes uses placeholder text" "$RESULT"

SUMMARY_FILE="$TEST_DIR/update-angle-placeholder-notes.md"
make_summary_file "$SUMMARY_FILE" "update" "<what changed and why>"
RESULT=$(run_validator "$SUMMARY_FILE" "$BITLESSON_FILE")
assert_blocked_with_notes_error "update action blocks when Notes uses angle-bracket placeholder text" "$RESULT"

SUMMARY_FILE="$TEST_DIR/delta-inside-fence.md"
cat > "$SUMMARY_FILE" <<EOF
# Round Summary

\`\`\`markdown
## BitLesson Delta
- Action: add
- Lesson ID(s): $TEST_LESSON_ID
- Notes: Quoted template text inside a fenced block.
\`\`\`
EOF
RESULT=$(run_validator "$SUMMARY_FILE" "$BITLESSON_FILE")
assert_blocked "BitLesson Delta inside a fenced code block fails validation" "$RESULT"

SUMMARY_FILE="$TEST_DIR/delta-inside-html-comment.md"
cat > "$SUMMARY_FILE" <<EOF
# Round Summary

<!--
## BitLesson Delta
- Action: add
- Lesson ID(s): $TEST_LESSON_ID
- Notes: Quoted template text inside an HTML comment.
-->
EOF
RESULT=$(run_validator "$SUMMARY_FILE" "$BITLESSON_FILE")
assert_blocked "BitLesson Delta inside an HTML comment fails validation" "$RESULT"

SUMMARY_FILE="$TEST_DIR/add-valid-notes.md"
make_summary_file "$SUMMARY_FILE" "add" "Recorded the validator gap and added a regression test."
RESULT=$(run_validator "$SUMMARY_FILE" "$BITLESSON_FILE")
assert_passes "add action passes when Notes explains the change" "$RESULT"

SUMMARY_FILE="$TEST_DIR/delta-normal-text.md"
make_summary_file "$SUMMARY_FILE" "update" "Normal text flow still exposes the BitLesson Delta section."
RESULT=$(run_validator "$SUMMARY_FILE" "$BITLESSON_FILE")
assert_passes "BitLesson Delta in normal text still passes validation" "$RESULT"

print_test_summary "BitLesson Delta Validator Test Summary"
