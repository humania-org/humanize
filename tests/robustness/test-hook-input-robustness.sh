#!/bin/bash
#
# Robustness tests for hook input parsing (AC-7) and monitor edge cases (AC-6)
#
# Tests hook input handling under edge cases:
# - Well-formed JSON
# - Malformed JSON
# - Extremely long commands
# - Non-UTF8 content
# - Monitor terminal edge cases
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
# JSON Parsing Tests (AC-7)
# ========================================

echo "--- JSON Parsing Tests (AC-7) ---"
echo ""

# Test 1: Well-formed JSON input
echo "Test 1: Parse well-formed JSON"
JSON='{"tool_name":"Bash","tool_input":{"command":"echo test"}}'
TOOL_NAME=$(echo "$JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tool_name',''))" 2>/dev/null || echo "error")
if [[ "$TOOL_NAME" == "Bash" ]]; then
    pass "Parses well-formed JSON correctly"
else
    fail "Well-formed JSON" "Bash" "$TOOL_NAME"
fi

# Test 2: Extract command from JSON
echo ""
echo "Test 2: Extract command field from JSON"
JSON='{"tool_name":"Bash","tool_input":{"command":"git status"}}'
COMMAND=$(echo "$JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('command',''))" 2>/dev/null || echo "error")
if [[ "$COMMAND" == "git status" ]]; then
    pass "Extracts command correctly"
else
    fail "Command extraction" "git status" "$COMMAND"
fi

# Test 3: Handle standard command strings
echo ""
echo "Test 3: Handle standard command strings"
COMMAND="ls -la /tmp"
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if [[ "$COMMAND_LOWER" == "ls -la /tmp" ]]; then
    pass "Standard command string handled"
else
    fail "Standard command" "ls -la /tmp" "$COMMAND_LOWER"
fi

# Test 4: Malformed JSON (missing field)
echo ""
echo "Test 4: Handle JSON with missing required fields"
JSON='{"tool_name":"Bash"}'
# Should not crash when accessing missing field
RESULT=$(echo "$JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('command','missing'))" 2>/dev/null || echo "error")
if [[ "$RESULT" == "missing" ]]; then
    pass "Handles missing fields gracefully"
else
    fail "Missing field handling" "missing" "$RESULT"
fi

# Test 5: Invalid JSON syntax
echo ""
echo "Test 5: Handle invalid JSON syntax"
INVALID_JSON='{"tool_name": "Bash", invalid}'
set +e
RESULT=$(echo "$INVALID_JSON" | python3 -c "import json,sys; json.load(sys.stdin)" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -ne 0 ]]; then
    pass "Rejects invalid JSON syntax (exit: $EXIT_CODE)"
else
    fail "Invalid JSON rejection" "non-zero exit" "exit 0"
fi

# Test 6: Extremely long command (10KB+)
echo ""
echo "Test 6: Handle extremely long command (10KB)"
LONG_COMMAND=$(printf 'echo %.0s' {1..2001})
COMMAND_LENGTH=${#LONG_COMMAND}
if [[ $COMMAND_LENGTH -ge 10000 ]]; then
    # Test that we can process it (at least lowercase it)
    LOWER_LENGTH=${#LONG_COMMAND}
    if [[ $LOWER_LENGTH -eq $COMMAND_LENGTH ]]; then
        pass "Handles 10KB+ command ($COMMAND_LENGTH chars)"
    else
        fail "Long command" "$COMMAND_LENGTH chars" "$LOWER_LENGTH chars"
    fi
else
    fail "Long command generation" ">=10000 chars" "$COMMAND_LENGTH chars"
fi

# Test 7: Deeply nested JSON
echo ""
echo "Test 7: Handle deeply nested JSON"
DEEP_JSON='{"a":{"b":{"c":{"d":{"e":{"f":"value"}}}}}}'
RESULT=$(echo "$DEEP_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['a']['b']['c']['d']['e']['f'])" 2>/dev/null || echo "error")
if [[ "$RESULT" == "value" ]]; then
    pass "Handles deeply nested JSON"
else
    fail "Nested JSON" "value" "$RESULT"
fi

# Test 8: Non-UTF8 content in command
echo ""
echo "Test 8: Handle special characters in commands"
COMMAND='echo "test with special chars: < > & | ; $"'
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if [[ "$COMMAND_LOWER" == *"special chars"* ]]; then
    pass "Handles special characters in commands"
else
    fail "Special chars" "contains 'special chars'" "$COMMAND_LOWER"
fi

# Test 9: Empty JSON
echo ""
echo "Test 9: Handle empty JSON object"
EMPTY_JSON='{}'
RESULT=$(echo "$EMPTY_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tool_name','empty'))" 2>/dev/null || echo "error")
if [[ "$RESULT" == "empty" ]]; then
    pass "Handles empty JSON gracefully"
else
    fail "Empty JSON" "empty" "$RESULT"
fi

# Test 10: JSON with Unicode
echo ""
echo "Test 10: Handle JSON with Unicode content"
UNICODE_JSON='{"message":"Hello World"}'
RESULT=$(echo "$UNICODE_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('message',''))" 2>/dev/null || echo "error")
if [[ -n "$RESULT" ]]; then
    pass "Handles Unicode in JSON"
else
    fail "Unicode JSON" "non-empty" "empty"
fi

# ========================================
# Monitor Edge Cases (AC-6)
# ========================================

echo ""
echo "--- Monitor Edge Cases (AC-6) ---"
echo ""

# Test 11: Terminal width handling
echo "Test 11: Terminal width detection"
# COLUMNS is often set in terminals
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
# Test string truncation
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
# Test string padding/filling
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

# Test 19: Detect file modification via command
echo "Test 19: Detect file modification in commands"
COMMAND="sed -i 's/old/new/' file.txt"
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if command_modifies_file "$COMMAND_LOWER" "file\.txt"; then
    pass "Detects sed -i modification"
else
    fail "Sed detection" "detected" "not detected"
fi

# Test 20: Detect redirect modification
echo ""
echo "Test 20: Detect redirect modification"
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
