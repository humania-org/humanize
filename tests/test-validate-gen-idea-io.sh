#!/usr/bin/env bash
#
# Tests for validate-gen-idea-io.sh — companion JSON derivation and collision detection.
#
# Covers:
#   - .md suffix enforcement on --output
#   - DIRECTIONS_JSON_FILE derivation in stdout on success
#   - Companion collision rejection (exit 8)
#   - Existing output file rejection still works (exit 4)
#   - Subdir companion path derivation
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

VALIDATE_SCRIPT="$PROJECT_ROOT/scripts/validate-gen-idea-io.sh"

echo "=========================================="
echo "validate-gen-idea-io.sh Tests"
echo "=========================================="
echo ""

setup_test_dir

# Create a mock git repo so the script can call git rev-parse
MOCK_REPO="$TEST_DIR/repo"
init_test_git_repo "$MOCK_REPO"

# Create a valid template tree so exit code 7 does not fire
PLUGIN_ROOT="$TEST_DIR/plugin"
mkdir -p "$PLUGIN_ROOT/prompt-template/idea"
touch "$PLUGIN_ROOT/prompt-template/idea/gen-idea-template.md"
export CLAUDE_PLUGIN_ROOT="$PLUGIN_ROOT"

# Helper: run the validation script inside the mock repo
run_validate() {
    (cd "$MOCK_REPO" && bash "$VALIDATE_SCRIPT" "$@")
}

# ----------------------------------------
# PT-1: Success with .md output emits DIRECTIONS_JSON_FILE
# ----------------------------------------
echo "--- Positive Tests ---"
echo ""

EXIT_CODE=0
OUTPUT_DIR="$TEST_DIR/out1"
mkdir -p "$OUTPUT_DIR"
OUTPUT=$(run_validate "test idea text" --output "$OUTPUT_DIR/foo.md" 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]] \
   && echo "$OUTPUT" | grep -q "VALIDATION_SUCCESS" \
   && echo "$OUTPUT" | grep -q "DIRECTIONS_JSON_FILE: "; then
    DJSON=$(echo "$OUTPUT" | grep "DIRECTIONS_JSON_FILE:" | sed 's/DIRECTIONS_JSON_FILE: //')
    if [[ "$DJSON" == *"foo.directions.json" ]]; then
        pass "success: DIRECTIONS_JSON_FILE emitted with .directions.json path"
    else
        fail "success: DIRECTIONS_JSON_FILE path ends in .directions.json" "*.directions.json" "$DJSON"
    fi
else
    fail "success: DIRECTIONS_JSON_FILE emitted on valid .md output" "exit 0 + DIRECTIONS_JSON_FILE" "exit=$EXIT_CODE"
fi

# PT-2: Subdir companion path derived correctly
EXIT_CODE=0
OUTPUT_DIR="$TEST_DIR/out2"
mkdir -p "$OUTPUT_DIR/subdir"
OUTPUT=$(run_validate "test idea text" --output "$OUTPUT_DIR/subdir/bar.md" 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then
    DJSON=$(echo "$OUTPUT" | grep "DIRECTIONS_JSON_FILE:" | sed 's/DIRECTIONS_JSON_FILE: //')
    if [[ "$DJSON" == *"subdir/bar.directions.json" ]]; then
        pass "subdir: companion path derived as subdir/bar.directions.json"
    else
        fail "subdir: companion path includes subdir" "*subdir/bar.directions.json" "$DJSON"
    fi
else
    fail "subdir: exits 0 for valid subdir output path" "exit 0" "exit=$EXIT_CODE"
fi

echo ""
echo "--- Negative Tests ---"
echo ""

# NT-1: No .md suffix — exit 6
EXIT_CODE=0
OUTPUT=$(run_validate "test idea text" --output "$TEST_DIR/foo" 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 6 ]] && echo "$OUTPUT" | grep -qi "md"; then
    pass "no .md suffix: exits 6 with .md error"
else
    fail "no .md suffix: exits 6" "exit 6 + md message" "exit=$EXIT_CODE"
fi

# NT-2: .txt suffix — exit 6
EXIT_CODE=0
OUTPUT=$(run_validate "test idea text" --output "$TEST_DIR/foo.txt" 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 6 ]]; then
    pass ".txt suffix: exits 6"
else
    fail ".txt suffix: exits 6" "exit 6" "exit=$EXIT_CODE"
fi

# NT-3: Companion JSON already exists — exit 8
EXIT_CODE=0
OUTPUT_DIR="$TEST_DIR/out3"
mkdir -p "$OUTPUT_DIR"
touch "$OUTPUT_DIR/foo.directions.json"
OUTPUT=$(run_validate "test idea text" --output "$OUTPUT_DIR/foo.md" 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 8 ]] && echo "$OUTPUT" | grep -qi "companion"; then
    pass "companion exists: exits 8 with companion error"
else
    fail "companion exists: exits 8" "exit 8 + companion message" "exit=$EXIT_CODE"
fi

# NT-4: Output draft already exists — exit 4 (existing behavior preserved)
EXIT_CODE=0
OUTPUT_DIR="$TEST_DIR/out4"
mkdir -p "$OUTPUT_DIR"
touch "$OUTPUT_DIR/bar.md"
OUTPUT=$(run_validate "test idea text" --output "$OUTPUT_DIR/bar.md" 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 4 ]]; then
    pass "output exists: exits 4 (existing behavior)"
else
    fail "output exists: exits 4" "exit 4" "exit=$EXIT_CODE"
fi

# NT-5: Missing idea — exit 1
EXIT_CODE=0
OUTPUT=$(run_validate 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 1 ]]; then
    pass "missing idea: exits 1"
else
    fail "missing idea: exits 1" "exit 1" "exit=$EXIT_CODE"
fi

# NT-6: Slash-containing idea treated as inline, not a missing file path
# Regression for: whitespace-free input containing "/" was misclassified as a
# file path and failed with INPUT_NOT_FOUND (exit 2).
EXIT_CODE=0
OUTPUT_DIR="$TEST_DIR/out5"
mkdir -p "$OUTPUT_DIR"
OUTPUT=$(run_validate "undo/redo" --output "$OUTPUT_DIR/undo-redo.md" 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]] && echo "$OUTPUT" | grep -q "VALIDATION_SUCCESS"; then
    pass "slash idea (undo/redo): treated as inline text, exits 0"
else
    fail "slash idea (undo/redo): treated as inline text" "exit 0 + VALIDATION_SUCCESS" "exit=$EXIT_CODE"
fi

# NT-7: Another slash idea — CI/CD
EXIT_CODE=0
OUTPUT_DIR="$TEST_DIR/out6"
mkdir -p "$OUTPUT_DIR"
OUTPUT=$(run_validate "CI/CD" --output "$OUTPUT_DIR/cicd.md" 2>&1) || EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]] && echo "$OUTPUT" | grep -q "VALIDATION_SUCCESS"; then
    pass "slash idea (CI/CD): treated as inline text, exits 0"
else
    fail "slash idea (CI/CD): treated as inline text" "exit 0 + VALIDATION_SUCCESS" "exit=$EXIT_CODE"
fi

echo ""
print_test_summary "validate-gen-idea-io.sh Test Summary"
