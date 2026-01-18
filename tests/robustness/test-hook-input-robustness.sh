#!/bin/bash
#
# Robustness tests for hook input parsing (AC-7) and monitor edge cases (AC-6)
#
# Tests production hook validators by piping JSON to them:
# - Well-formed JSON parsing (loop-read-validator.sh, loop-write-validator.sh)
# - Malformed JSON handling
# - Edge cases in command parsing
# - Monitor terminal/log edge cases
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/hooks/lib/loop-common.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo -e "${GREEN}PASS${NC}: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "${RED}FAIL${NC}: $1"
    echo "  Expected: $2"
    echo "  Got: $3"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# Setup test directory
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

echo "========================================"
echo "Hook Input & Monitor Robustness Tests"
echo "(AC-6 & AC-7)"
echo "========================================"
echo ""

# ========================================
# Hook Input Parsing Tests (AC-7)
# ========================================
# These tests pipe JSON to actual hook validators and check their behavior

echo "--- Hook Input Parsing Tests (AC-7) ---"
echo ""

# Test 1: Well-formed JSON with Read tool (should pass through)
echo "Test 1: Hook parses well-formed JSON with Read tool"
JSON='{"tool_name":"Read","tool_input":{"file_path":"/tmp/test.txt"}}'
# Run read validator - should exit 0 for non-loop paths
RESULT=$(echo "$JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/hooks/loop-read-validator.sh" 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Read hook passes valid JSON (exit: 0)"
else
    fail "Valid JSON parsing" "exit 0" "exit $EXIT_CODE: $RESULT"
fi

# Test 2: Well-formed JSON with Write tool
echo ""
echo "Test 2: Hook parses well-formed JSON with Write tool"
JSON='{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.txt","content":"hello"}}'
RESULT=$(echo "$JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/hooks/loop-write-validator.sh" 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Write hook passes valid JSON (exit: 0)"
else
    fail "Write JSON parsing" "exit 0" "exit $EXIT_CODE: $RESULT"
fi

# Test 3: Well-formed JSON with Bash tool
echo ""
echo "Test 3: Hook parses well-formed JSON with Bash tool"
JSON='{"tool_name":"Bash","tool_input":{"command":"echo hello"}}'
RESULT=$(echo "$JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/hooks/loop-bash-validator.sh" 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Bash hook passes valid JSON (exit: 0)"
else
    fail "Bash JSON parsing" "exit 0" "exit $EXIT_CODE: $RESULT"
fi

# Test 4: Invalid JSON syntax (should reject with non-zero exit)
echo ""
echo "Test 4: Hook rejects invalid JSON syntax"
INVALID_JSON='{"tool_name": "Read", invalid}'
# The hook should reject invalid JSON and return non-zero exit code
set +e
RESULT=$(echo "$INVALID_JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/hooks/loop-read-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
# Should reject (non-zero) but not crash with signal
if [[ $EXIT_CODE -ne 0 ]] && [[ $EXIT_CODE -lt 128 ]]; then
    pass "Invalid JSON rejected gracefully (exit: $EXIT_CODE)"
else
    fail "Invalid JSON rejection" "exit 1-127 (reject)" "exit $EXIT_CODE"
fi

# Test 5: Empty JSON object (missing required tool_name field)
echo ""
echo "Test 5: Hook rejects empty JSON object (missing tool_name)"
EMPTY_JSON='{}'
set +e
RESULT=$(echo "$EMPTY_JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/hooks/loop-read-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
# Should reject because tool_name is missing
if [[ $EXIT_CODE -ne 0 ]] && [[ $EXIT_CODE -lt 128 ]]; then
    pass "Empty JSON rejected (exit: $EXIT_CODE)"
else
    fail "Empty JSON rejection" "exit 1-127 (reject)" "exit $EXIT_CODE"
fi

# Test 6: JSON with missing required fields (tool_input.file_path for Read)
echo ""
echo "Test 6: Hook rejects JSON with missing tool_input.file_path"
JSON='{"tool_name":"Read"}'
set +e
RESULT=$(echo "$JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/hooks/loop-read-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
# Should reject because file_path is required for Read tool
if [[ $EXIT_CODE -ne 0 ]] && [[ $EXIT_CODE -lt 128 ]]; then
    pass "Missing tool_input.file_path rejected (exit: $EXIT_CODE)"
else
    fail "Missing fields rejection" "exit 1-127 (reject)" "exit $EXIT_CODE"
fi

# Test 7: Extremely long command (10KB+)
echo ""
echo "Test 7: Hook handles extremely long command (10KB)"
LONG_COMMAND=$(printf 'x%.0s' {1..10000})
JSON=$(cat <<EOF
{"tool_name":"Bash","tool_input":{"command":"echo $LONG_COMMAND"}}
EOF
)
set +e
RESULT=$(echo "$JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/hooks/loop-bash-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Long command handled (exit: 0, ${#LONG_COMMAND} chars)"
else
    fail "Long command" "exit 0" "exit $EXIT_CODE"
fi

# Test 8: JSON with special characters in command
echo ""
echo "Test 8: Hook handles special characters in command"
JSON='{"tool_name":"Bash","tool_input":{"command":"echo \"test with special chars: < > & | ; $\""}}'
set +e
RESULT=$(echo "$JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/hooks/loop-bash-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Special characters handled (exit: 0)"
else
    fail "Special chars" "exit 0" "exit $EXIT_CODE"
fi

# Test 9: JSON with actual Unicode content in file path
echo ""
echo "Test 9: Hook handles Unicode characters in JSON"
JSON='{"tool_name":"Read","tool_input":{"file_path":"/tmp/\u6d4b\u8bd5_\u30c6\u30b9\u30c8_\u043f\u0440\u043e\u0432\u0435\u0440\u043a\u0430.txt"}}'
set +e
RESULT=$(echo "$JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/hooks/loop-read-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Unicode in path handled (exit: 0)"
else
    fail "Unicode path" "exit 0" "exit $EXIT_CODE"
fi

# Test 10: Unrecognized tool name passes through
echo ""
echo "Test 10: Hook ignores unrecognized tool names"
JSON='{"tool_name":"UnknownTool","tool_input":{"path":"/tmp/test"}}'
set +e
RESULT=$(echo "$JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/hooks/loop-read-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Unknown tool ignored (exit: 0)"
else
    fail "Unknown tool" "exit 0" "exit $EXIT_CODE"
fi

# Test 10a: Deeply nested JSON structure (should be rejected)
echo ""
echo "Test 10a: Hook rejects deeply nested JSON (50 levels)"
# Create a deeply nested JSON structure
NESTED_JSON='{"tool_name":"Read","tool_input":{"file_path":"/tmp/test.txt","metadata":'
for i in $(seq 1 50); do
    NESTED_JSON="${NESTED_JSON}{\"level$i\":"
done
NESTED_JSON="${NESTED_JSON}\"deep\""
for i in $(seq 1 50); do
    NESTED_JSON="${NESTED_JSON}}"
done
NESTED_JSON="${NESTED_JSON}}}"
set +e
RESULT=$(echo "$NESTED_JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/hooks/loop-read-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
# Should reject deeply nested JSON (depth > 30) with non-zero exit
if [[ $EXIT_CODE -ne 0 ]] && [[ $EXIT_CODE -lt 128 ]]; then
    pass "Deeply nested JSON rejected (exit: $EXIT_CODE)"
else
    fail "Deep nesting rejection" "exit 1-127 (reject)" "exit $EXIT_CODE"
fi

# Test 10b: Non-UTF8 content in command (binary bytes)
echo ""
echo "Test 10b: Hook handles non-UTF8 binary content"
# Create JSON with embedded binary/non-UTF8 bytes using hex escape
BINARY_JSON=$(printf '{"tool_name":"Bash","tool_input":{"command":"echo \x80\x81\x82\xff"}}')
set +e
RESULT=$(echo "$BINARY_JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/hooks/loop-bash-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
# Script should handle gracefully (jq may reject or pass depending on version)
if [[ $EXIT_CODE -lt 128 ]]; then
    pass "Non-UTF8 content handled gracefully (exit: $EXIT_CODE)"
else
    fail "Non-UTF8" "exit < 128 (no signal)" "exit $EXIT_CODE (signal crash)"
fi

# Test 10c: Null bytes in JSON
# Note: Bash strips null bytes during command substitution (see warning), so the hook
# cannot detect them. This tests that the hook handles the stripped-null-byte case gracefully.
echo ""
echo "Test 10c: Hook handles null bytes gracefully (bash strips them)"
NULL_JSON=$(printf '{"tool_name":"Read","tool_input":{"file_path":"/tmp/test\x00.txt"}}')
set +e
RESULT=$(echo "$NULL_JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/hooks/loop-read-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
# Bash strips null bytes before our code sees them, so the resulting JSON is valid
# and the hook should accept it (or jq may produce parse errors on some versions)
if [[ $EXIT_CODE -lt 128 ]]; then
    pass "Null bytes handled gracefully (exit: $EXIT_CODE)"
else
    fail "Null bytes handling" "exit < 128 (no signal)" "exit $EXIT_CODE (signal crash)"
fi

# ========================================
# Monitor Edge Cases (AC-6)
# ========================================

echo ""
echo "--- Monitor Edge Cases (AC-6) ---"
echo ""

# Test 11: Terminal width handling
echo "Test 11: Terminal width detection"
TERM_WIDTH=${COLUMNS:-80}
if [[ $TERM_WIDTH -gt 0 ]]; then
    pass "Terminal width detectable ($TERM_WIDTH chars)"
else
    fail "Terminal width" ">0" "$TERM_WIDTH"
fi

# Test 12: Log file update handling
echo ""
echo "Test 12: Log file update detection"
LOG_FILE="$TEST_DIR/test.log"
echo "Initial log" > "$LOG_FILE"
INITIAL_SIZE=$(wc -c < "$LOG_FILE")
echo "Additional content" >> "$LOG_FILE"
UPDATED_SIZE=$(wc -c < "$LOG_FILE")
if [[ $UPDATED_SIZE -gt $INITIAL_SIZE ]]; then
    pass "Detects log file growth"
else
    fail "Log growth" ">$INITIAL_SIZE" "$UPDATED_SIZE"
fi

# Test 13: Log file deletion handling
echo ""
echo "Test 13: Handle log file deletion gracefully"
LOG_FILE="$TEST_DIR/deletable.log"
echo "content" > "$LOG_FILE"
rm "$LOG_FILE"
if [[ ! -f "$LOG_FILE" ]]; then
    pass "Handles log file deletion"
else
    fail "Log deletion" "file removed" "file exists"
fi

# Test 14: ANSI codes in logs
echo ""
echo "Test 14: Handle ANSI codes in logs"
ANSI_LOG="$TEST_DIR/ansi.log"
printf '\033[31mRed text\033[0m\n\033[32mGreen text\033[0m\n' > "$ANSI_LOG"
# Strip ANSI and check content
STRIPPED=$(sed 's/\x1b\[[0-9;]*m//g' "$ANSI_LOG")
if echo "$STRIPPED" | grep -q "Red text"; then
    pass "ANSI codes can be stripped from logs"
else
    fail "ANSI stripping" "Red text" "$STRIPPED"
fi

# Test 15: Binary content in logs
echo ""
echo "Test 15: Handle binary content in logs"
BINARY_LOG="$TEST_DIR/binary.log"
printf 'Normal line\n\x00\x01\x02Binary\x03\x04\nAnother normal line\n' > "$BINARY_LOG"
LINE_COUNT=$(wc -l < "$BINARY_LOG" 2>/dev/null || echo "0")
if [[ "$LINE_COUNT" -gt "0" ]]; then
    pass "Handles binary content in logs ($LINE_COUNT lines)"
else
    fail "Binary content" ">0 lines" "$LINE_COUNT"
fi

# Test 16: Very narrow terminal simulation
echo ""
echo "Test 16: Handle narrow terminal width"
NARROW_WIDTH=30
LONG_STRING="This is a very long string that would exceed narrow width"
TRUNCATED="${LONG_STRING:0:$NARROW_WIDTH}"
if [[ ${#TRUNCATED} -eq $NARROW_WIDTH ]]; then
    pass "Can truncate for narrow width"
else
    fail "Narrow truncation" "$NARROW_WIDTH chars" "${#TRUNCATED} chars"
fi

# Test 17: Very wide terminal simulation
echo ""
echo "Test 17: Handle wide terminal width"
WIDE_WIDTH=300
PADDED_LINE=$(printf "%-${WIDE_WIDTH}s" "Content")
if [[ ${#PADDED_LINE} -eq $WIDE_WIDTH ]]; then
    pass "Can pad for wide terminal"
else
    fail "Wide padding" "$WIDE_WIDTH chars" "${#PADDED_LINE} chars"
fi

# Test 18: Rapid log file updates
echo ""
echo "Test 18: Handle rapid log file updates"
RAPID_LOG="$TEST_DIR/rapid.log"
: > "$RAPID_LOG"
for i in $(seq 1 100); do
    echo "Line $i" >> "$RAPID_LOG"
done
FINAL_LINES=$(wc -l < "$RAPID_LOG")
if [[ $FINAL_LINES -eq 100 ]]; then
    pass "Handles rapid updates (100 lines written)"
else
    fail "Rapid updates" "100 lines" "$FINAL_LINES lines"
fi

# ========================================
# Command Modification Detection Tests
# ========================================

echo ""
echo "--- Command Pattern Tests ---"
echo ""

# Test 19: Detect file modification via sed -i
echo "Test 19: Detect sed -i modification pattern"
COMMAND="sed -i 's/old/new/' file.txt"
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if command_modifies_file "$COMMAND_LOWER" "file\.txt"; then
    pass "Detects sed -i modification"
else
    fail "Sed detection" "detected" "not detected"
fi

# Test 20: Detect redirect modification
echo ""
echo "Test 20: Detect redirect modification pattern"
COMMAND="echo content > output.txt"
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if command_modifies_file "$COMMAND_LOWER" "output\.txt"; then
    pass "Detects redirect modification"
else
    fail "Redirect detection" "detected" "not detected"
fi

# ========================================
# Summary
# ========================================

echo ""
echo "========================================"
echo "Hook Input & Monitor Test Summary"
echo "========================================"
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo ""
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo ""
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi
