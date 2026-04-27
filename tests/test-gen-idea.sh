#!/usr/bin/env bash
set -u

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATE_SCRIPT="$PROJECT_ROOT/scripts/validate-gen-idea-io.sh"
GEN_IDEA_CMD="$PROJECT_ROOT/commands/gen-idea.md"

PASSED=0
FAILED=0

pass() {
    echo "PASS: $1"
    PASSED=$((PASSED + 1))
}

fail() {
    echo "FAIL: $1"
    echo "  expected: $2"
    echo "  actual:   $3"
    FAILED=$((FAILED + 1))
}

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

echo "=== Test: gen-idea validation ==="

if grep -q -- '--raw-arguments "$ARGUMENTS"' "$GEN_IDEA_CMD"; then
    pass "gen-idea.md passes raw arguments through parser mode"
else
    fail "gen-idea.md passes raw arguments through parser mode" 'contains --raw-arguments "$ARGUMENTS"' "missing"
fi

OUT_DIR="$TEST_DIR/out dir"
mkdir -p "$OUT_DIR"
RAW_OUTPUT="$OUT_DIR/idea draft.md"
RAW_ARGS="--n 4 --output '$RAW_OUTPUT' \"idea with spaces\""
RAW_RESULT="$("$VALIDATE_SCRIPT" --raw-arguments "$RAW_ARGS" 2>&1)"
RAW_EXIT=$?

if [[ "$RAW_EXIT" -eq 0 ]] && \
   echo "$RAW_RESULT" | grep -q '^N: 4$' && \
   echo "$RAW_RESULT" | grep -qF "OUTPUT_FILE: $RAW_OUTPUT" && \
   echo "$RAW_RESULT" | grep -q '^idea with spaces$'; then
    pass "validate-gen-idea-io: raw argument mode preserves flags and quoted inline idea"
else
    fail "validate-gen-idea-io: raw argument mode preserves flags and quoted inline idea" "exit 0, N 4, output path, idea body" "exit $RAW_EXIT; output: $RAW_RESULT"
fi

UNQUOTED_OUTPUT="$OUT_DIR/unquoted idea.md"
UNQUOTED_RAW_ARGS="--n 4 --output '$UNQUOTED_OUTPUT' add undo/redo to editor"
UNQUOTED_RESULT="$("$VALIDATE_SCRIPT" --raw-arguments "$UNQUOTED_RAW_ARGS" 2>&1)"
UNQUOTED_EXIT=$?
if [[ "$UNQUOTED_EXIT" -eq 0 ]] && \
   echo "$UNQUOTED_RESULT" | grep -q '^N: 4$' && \
   echo "$UNQUOTED_RESULT" | grep -qF "OUTPUT_FILE: $UNQUOTED_OUTPUT" && \
   echo "$UNQUOTED_RESULT" | grep -q '^add undo/redo to editor$'; then
    pass "validate-gen-idea-io: raw argument mode preserves unquoted multi-word inline idea"
else
    fail "validate-gen-idea-io: raw argument mode preserves unquoted multi-word inline idea" "exit 0, N 4, output path, idea body" "exit $UNQUOTED_EXIT; output: $UNQUOTED_RESULT"
fi

APOSTROPHE_OUTPUT="$OUT_DIR/apostrophe idea.md"
APOSTROPHE_RAW_ARGS="--n 4 --output '$APOSTROPHE_OUTPUT' don't use global state"
APOSTROPHE_RESULT="$("$VALIDATE_SCRIPT" --raw-arguments "$APOSTROPHE_RAW_ARGS" 2>&1)"
APOSTROPHE_EXIT=$?
if [[ "$APOSTROPHE_EXIT" -eq 0 ]] && \
   echo "$APOSTROPHE_RESULT" | grep -q '^N: 4$' && \
   echo "$APOSTROPHE_RESULT" | grep -qF "OUTPUT_FILE: $APOSTROPHE_OUTPUT" && \
   echo "$APOSTROPHE_RESULT" | grep -q "^don't use global state$"; then
    pass "validate-gen-idea-io: raw argument mode treats apostrophes as idea text"
else
    fail "validate-gen-idea-io: raw argument mode treats apostrophes as idea text" "exit 0, N 4, output path, idea body" "exit $APOSTROPHE_EXIT; output: $APOSTROPHE_RESULT"
fi

POSTFIX_OUTPUT="$OUT_DIR/postfix idea.md"
POSTFIX_RAW_ARGS="add undo/redo to editor --n 5 --output '$POSTFIX_OUTPUT'"
POSTFIX_RESULT="$("$VALIDATE_SCRIPT" --raw-arguments "$POSTFIX_RAW_ARGS" 2>&1)"
POSTFIX_EXIT=$?
if [[ "$POSTFIX_EXIT" -eq 0 ]] && \
   echo "$POSTFIX_RESULT" | grep -q '^N: 5$' && \
   echo "$POSTFIX_RESULT" | grep -qF "OUTPUT_FILE: $POSTFIX_OUTPUT" && \
   echo "$POSTFIX_RESULT" | grep -q '^add undo/redo to editor$'; then
    pass "validate-gen-idea-io: raw argument mode preserves idea-first option parsing"
else
    fail "validate-gen-idea-io: raw argument mode preserves idea-first option parsing" "exit 0, N 5, output path, idea body" "exit $POSTFIX_EXIT; output: $POSTFIX_RESULT"
fi

DIRECT_OUTPUT="$TEST_DIR/direct.md"
DIRECT_RESULT="$("$VALIDATE_SCRIPT" "direct idea with spaces" --n 3 --output "$DIRECT_OUTPUT" 2>&1)"
DIRECT_EXIT=$?
if [[ "$DIRECT_EXIT" -eq 0 ]] && \
   echo "$DIRECT_RESULT" | grep -q '^N: 3$' && \
   echo "$DIRECT_RESULT" | grep -q '^direct idea with spaces$'; then
    pass "validate-gen-idea-io: direct argv mode still accepts separate arguments"
else
    fail "validate-gen-idea-io: direct argv mode still accepts separate arguments" "exit 0, N 3, idea body" "exit $DIRECT_EXIT; output: $DIRECT_RESULT"
fi

UNMATCHED_RESULT="$("$VALIDATE_SCRIPT" --raw-arguments '--n 4 "unterminated idea' 2>&1)"
UNMATCHED_EXIT=$?
if [[ "$UNMATCHED_EXIT" -eq 0 ]] && \
   echo "$UNMATCHED_RESULT" | grep -q '^N: 4$' && \
   echo "$UNMATCHED_RESULT" | grep -q '^"unterminated idea$'; then
    pass "validate-gen-idea-io: raw argument mode treats unmatched idea quote as text"
else
    fail "validate-gen-idea-io: raw argument mode treats unmatched idea quote as text" "exit 0, N 4, idea body with leading quote" "exit $UNMATCHED_EXIT; output: $UNMATCHED_RESULT"
fi

echo ""
echo "=== gen-idea Test Summary ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"

if [[ "$FAILED" -ne 0 ]]; then
    exit 1
fi

exit 0
