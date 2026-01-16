#!/bin/bash
#
# Tests for cancel-rlcr-loop signal file mechanism
#
# Tests:
# - POSITIVE: mv state.md to cancel-state.md allowed when signal file exists
# - NEGATIVE: mv state.md to cancel-state.md blocked without signal file
# - NEGATIVE: Other state.md modifications blocked even with signal file
# - NEGATIVE: Signal file in wrong directory does not authorize cancel
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Test helpers
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'
TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo -e "${GREEN}PASS${NC}: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}FAIL${NC}: $1"; echo "  Expected: $2"; echo "  Got: $3"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# Setup test environment
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

# Source the common library
source "$PROJECT_ROOT/hooks/lib/loop-common.sh"

echo "=== Test: Cancel Signal File Mechanism ==="
echo ""

# ========================================
# Setup: Create test loop directory with state.md
# ========================================

setup_test_loop() {
    local test_name="$1"
    rm -rf "$TEST_DIR/.humanize" 2>/dev/null || true
    LOOP_DIR="$TEST_DIR/.humanize/rlcr/2024-01-01_12-00-00"
    mkdir -p "$LOOP_DIR"
    cat > "$LOOP_DIR/state.md" << 'EOF'
---
current_round: 3
max_iterations: 10
plan_file: plan.md
plan_tracked: false
start_branch: main
---
EOF
    export CLAUDE_PROJECT_DIR="$TEST_DIR"
}

# Helper to simulate hook validation
# Uses jq to properly encode the command string (handles special chars like ${})
run_bash_validator() {
    local command="$1"
    local hook_input
    hook_input=$(jq -n --arg cmd "$command" '{
        "tool_name": "Bash",
        "tool_input": {
            "command": $cmd
        }
    }')
    echo "$hook_input" | "$PROJECT_ROOT/hooks/loop-bash-validator.sh" 2>&1
    return ${PIPESTATUS[1]}
}

# ========================================
# POSITIVE TEST 1: mv allowed with signal file
# ========================================

echo "POSITIVE TEST 1: mv state.md to cancel-state.md allowed when signal file exists"
setup_test_loop "positive-1"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="mv ${LOOP_DIR}/state.md ${LOOP_DIR}/cancel-state.md"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "mv state.md to cancel-state.md allowed with signal file"
else
    fail "mv allowed with signal" "exit 0" "exit $EXIT_CODE: $OUTPUT"
fi

# ========================================
# POSITIVE TEST 2: mv allowed with different path format
# ========================================

echo "POSITIVE TEST 2: mv allowed with relative-style path"
setup_test_loop "positive-2"
touch "$LOOP_DIR/.cancel-requested"
# Use a command with ./ prefix to test slightly different path format
COMMAND="mv ${LOOP_DIR}/./state.md ${LOOP_DIR}/cancel-state.md"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "mv state.md allowed with ./ path format"
else
    fail "mv allowed with ./ path" "exit 0" "exit $EXIT_CODE: $OUTPUT"
fi

# ========================================
# NEGATIVE TEST 1: mv blocked without signal file
# ========================================

echo "NEGATIVE TEST 1: mv state.md to cancel-state.md blocked without signal file"
setup_test_loop "negative-1"
# Do NOT create signal file
COMMAND="mv ${LOOP_DIR}/state.md ${LOOP_DIR}/cancel-state.md"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "mv state.md blocked without signal file"
else
    fail "mv blocked without signal" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 2: Other state.md modifications blocked even with signal
# ========================================

echo "NEGATIVE TEST 2: echo > state.md blocked even with signal file"
setup_test_loop "negative-2"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="echo 'hack' > ${LOOP_DIR}/state.md"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "echo > state.md blocked even with signal file"
else
    fail "echo blocked with signal" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 3: sed -i blocked even with signal
# ========================================

echo "NEGATIVE TEST 3: sed -i state.md blocked even with signal file"
setup_test_loop "negative-3"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="sed -i 's/round: 3/round: 99/' ${LOOP_DIR}/state.md"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "sed -i state.md blocked even with signal file"
else
    fail "sed blocked with signal" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 4: mv to wrong destination blocked
# ========================================

echo "NEGATIVE TEST 4: mv state.md to wrong destination blocked even with signal"
setup_test_loop "negative-4"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="mv ${LOOP_DIR}/state.md ${LOOP_DIR}/hacked-state.md"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "mv state.md to wrong destination blocked"
else
    fail "mv to wrong dest blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 5: Signal file in wrong directory
# ========================================

echo "NEGATIVE TEST 5: Signal file in wrong directory does not authorize"
setup_test_loop "negative-5"
# Create signal file in WRONG directory (parent)
touch "$TEST_DIR/.humanize/rlcr/.cancel-requested"
# NOT in the active loop dir
COMMAND="mv ${LOOP_DIR}/state.md ${LOOP_DIR}/cancel-state.md"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Signal file in wrong directory does not authorize"
else
    fail "wrong dir signal blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 6: rm state.md blocked even with signal
# ========================================

echo "NEGATIVE TEST 6: rm state.md blocked even with signal file"
setup_test_loop "negative-6"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="rm ${LOOP_DIR}/state.md"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "rm state.md blocked even with signal file"
else
    fail "rm blocked with signal" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 7: Command injection attempt blocked
# ========================================

echo "NEGATIVE TEST 7: Command injection via && blocked even with signal"
setup_test_loop "negative-7"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="mv ${LOOP_DIR}/state.md ${LOOP_DIR}/cancel-state.md && rm -rf /"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Command injection via && blocked"
else
    fail "injection via && blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 8: Command injection via ; blocked
# ========================================

echo "NEGATIVE TEST 8: Command injection via semicolon blocked even with signal"
setup_test_loop "negative-8"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="mv ${LOOP_DIR}/state.md ${LOOP_DIR}/cancel-state.md; echo hacked"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Command injection via semicolon blocked"
else
    fail "injection via semicolon blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 9: mv state.md to non-state.md destination blocked (BYPASS FIX)
# ========================================

echo "NEGATIVE TEST 9: mv state.md to arbitrary destination blocked (even with signal)"
setup_test_loop "negative-9"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="mv ${LOOP_DIR}/state.md /tmp/arbitrary-file.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "mv state.md to arbitrary destination blocked"
else
    fail "mv state.md bypass blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 10: Command substitution $() injection blocked
# ========================================

echo "NEGATIVE TEST 10: Command substitution via \$() blocked even with signal"
setup_test_loop "negative-10"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="mv ${LOOP_DIR}/state.md ${LOOP_DIR}/cancel-state.md\$(rm -rf /)"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Command substitution via \$() blocked"
else
    fail "injection via \$() blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 11: Backtick command substitution blocked
# ========================================

echo "NEGATIVE TEST 11: Backtick command substitution blocked even with signal"
setup_test_loop "negative-11"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="mv ${LOOP_DIR}/state.md ${LOOP_DIR}/cancel-state.md\`rm -rf /\`"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Backtick command substitution blocked"
else
    fail "injection via backticks blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 12: Newline-separated command injection blocked
# ========================================
# Note: Testing the is_cancel_authorized helper directly since JSON parsing
# of literal newlines in command strings is not straightforward

echo "NEGATIVE TEST 12: Newline-separated command injection blocked in helper"
setup_test_loop "negative-12"
touch "$LOOP_DIR/.cancel-requested"
# Command with embedded newline - test helper directly
COMMAND_WITH_NEWLINE="mv ${LOOP_DIR}/state.md ${LOOP_DIR}/cancel-state.md
rm -rf /"
COMMAND_LOWER=$(to_lower "$COMMAND_WITH_NEWLINE")

if is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    fail "injection via newline blocked" "returns 1" "returns 0"
else
    pass "Newline-separated command injection blocked"
fi

# ========================================
# POSITIVE TEST 3: mv with single-quoted paths allowed
# ========================================
# Test that paths with quotes work correctly
# Note: We use single quotes here since double quotes break JSON parsing in the test harness

echo "POSITIVE TEST 3: mv with single-quoted paths allowed with signal"
setup_test_loop "positive-3"
touch "$LOOP_DIR/.cancel-requested"
# Use single quotes around paths to test quoted path handling
COMMAND="mv '${LOOP_DIR}/state.md' '${LOOP_DIR}/cancel-state.md'"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "mv with single-quoted paths allowed with signal file"
else
    fail "mv with quoted paths" "exit 0" "exit $EXIT_CODE: $OUTPUT"
fi

# ========================================
# NEGATIVE TEST 13: mv with -- option blocked (state.md as source)
# ========================================

echo "NEGATIVE TEST 13: mv -- state.md /tmp/foo blocked (options before source)"
setup_test_loop "negative-13"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="mv -- ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "mv -- state.md /tmp/foo blocked"
else
    fail "mv -- state.md bypass blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 14: cp -f state.md blocked (options before source)
# ========================================

echo "NEGATIVE TEST 14: cp -f state.md /backup blocked (options before source)"
setup_test_loop "negative-14"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="cp -f ${LOOP_DIR}/state.md /tmp/backup.md"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "cp -f state.md blocked"
else
    fail "cp -f state.md bypass blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 15: mv with 3 args blocked (extra argument)
# ========================================

echo "NEGATIVE TEST 15: mv state.md /tmp cancel-state.md blocked (3 args)"
setup_test_loop "negative-15"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="mv ${LOOP_DIR}/state.md /tmp ${LOOP_DIR}/cancel-state.md"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "mv with 3 args (extra argument) blocked"
else
    fail "mv 3 args blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# POSITIVE TEST 4: Literal $LOOP_DIR-style command allowed (documented format)
# ========================================
# Tests the documented cancel command format with ${LOOP_DIR} variable syntax
# The is_cancel_authorized function normalizes this to the actual path
# IMPORTANT: We pass the literal ${loop_dir} string WITHOUT pre-expansion
# to verify that normalization works correctly

echo "POSITIVE TEST 4: Literal LOOP_DIR variable syntax allowed with signal (helper)"
setup_test_loop "positive-4"
touch "$LOOP_DIR/.cancel-requested"
# Pass literal ${loop_dir} string to test normalization in is_cancel_authorized
# Note: command_lower receives the lowercased variable name
COMMAND_LOWER='mv "${loop_dir}state.md" "${loop_dir}cancel-state.md"'
# DO NOT pre-expand - the helper should normalize ${loop_dir} to actual path

if is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    pass "Literal LOOP_DIR variable syntax allowed (helper normalizes)"
else
    fail "LOOP_DIR variable syntax (helper)" "returns 0" "returns 1"
fi

# ========================================
# POSITIVE TEST 5: Literal LOOP_DIR through validator (documented format)
# ========================================
# Tests the full validator flow with literal ${LOOP_DIR} variable syntax
# This verifies the documented cancel command format works end-to-end

echo "POSITIVE TEST 5: Literal LOOP_DIR through validator with signal"
setup_test_loop "positive-5"
touch "$LOOP_DIR/.cancel-requested"
# Pass literal command with ${loop_dir} (lowercased for command_lower matching)
# Note: run_bash_validator lowercases the command, so we use lowercase var name
COMMAND='mv "${loop_dir}state.md" "${loop_dir}cancel-state.md"'

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Literal LOOP_DIR through validator allowed"
else
    fail "LOOP_DIR through validator" "exit 0" "exit $EXIT_CODE: $OUTPUT"
fi

# ========================================
# NEGATIVE TEST 16: mv -- 'state.md' blocked (quoted relative path)
# ========================================
# Uses single quotes since double quotes break JSON parsing in test harness

echo "NEGATIVE TEST 16: mv -- quoted relative state.md blocked"
setup_test_loop "negative-16"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="mv -- 'state.md' /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "mv -- quoted relative state.md blocked"
else
    fail "quoted relative state.md blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 17: Extra args before state.md blocked
# ========================================

echo "NEGATIVE TEST 17: mv /tmp/extra state.md cancel-state.md blocked (extra arg before)"
setup_test_loop "negative-17"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="mv /tmp/extra.txt ${LOOP_DIR}/state.md ${LOOP_DIR}/cancel-state.md"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Extra arg before state.md blocked"
else
    fail "extra arg before state.md blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 18: Hidden variable like ${IFS} blocked
# ========================================

echo "NEGATIVE TEST 18: Hidden variable injection blocked"
setup_test_loop "negative-18"
touch "$LOOP_DIR/.cancel-requested"
# Try to use ${IFS} to hide extra arguments
COMMAND_LOWER='mv ${LOOP_DIR}/state.md${ifs}extra ${LOOP_DIR}/cancel-state.md'
# Replace LOOP_DIR but leave ${ifs}
COMMAND_LOWER="${COMMAND_LOWER//\$\{LOOP_DIR\}/$LOOP_DIR}"
COMMAND_LOWER=$(to_lower "$COMMAND_LOWER")

if is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    fail "hidden variable blocked" "returns 1" "returns 0"
else
    pass "Hidden variable injection blocked"
fi

# ========================================
# NEGATIVE TEST 19: sudo mv state.md blocked (prefix bypass attempt)
# ========================================

echo "NEGATIVE TEST 19: sudo mv state.md blocked (prefix bypass)"
setup_test_loop "negative-19"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="sudo mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "sudo mv state.md blocked"
else
    fail "sudo mv bypass blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 20: Leading whitespace mv state.md blocked
# ========================================

echo "NEGATIVE TEST 20: Leading whitespace mv state.md blocked"
setup_test_loop "negative-20"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="  mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Leading whitespace mv state.md blocked"
else
    fail "whitespace mv bypass blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 21: env prefix mv state.md blocked
# ========================================

echo "NEGATIVE TEST 21: env prefix mv state.md blocked"
setup_test_loop "negative-21"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="env PATH=/bin mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "env prefix mv state.md blocked"
else
    fail "env mv bypass blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 22: sudo -u root mv state.md blocked (prefix with options)
# ========================================

echo "NEGATIVE TEST 22: sudo -u root mv state.md blocked (prefix with options)"
setup_test_loop "negative-22"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="sudo -u root mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "sudo -u root mv state.md blocked"
else
    fail "sudo -u root mv bypass blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 23: command -- mv state.md blocked (prefix with options)
# ========================================

echo "NEGATIVE TEST 23: command -- mv state.md blocked (prefix with options)"
setup_test_loop "negative-23"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="command -- mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "command -- mv state.md blocked"
else
    fail "command -- mv bypass blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 24: Chained command via semicolon blocked
# ========================================

echo "NEGATIVE TEST 24: true; mv state.md blocked (chained via semicolon)"
setup_test_loop "negative-24"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="true; mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Chained command via semicolon blocked"
else
    fail "chained via semicolon blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 25: Chained command via && blocked
# ========================================

echo "NEGATIVE TEST 25: true && mv state.md blocked (chained via &&)"
setup_test_loop "negative-25"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="true && mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Chained command via && blocked"
else
    fail "chained via && blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 26: Chained command via || blocked
# ========================================

echo "NEGATIVE TEST 26: false || mv state.md blocked (chained via ||)"
setup_test_loop "negative-26"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="false || mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Chained command via || blocked"
else
    fail "chained via || blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 27: Chained command via pipe blocked
# ========================================

echo "NEGATIVE TEST 27: echo foo | mv state.md blocked (chained via pipe)"
setup_test_loop "negative-27"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="echo foo | mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Chained command via pipe blocked"
else
    fail "chained via pipe blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 28: Background operator & bypass blocked
# ========================================

echo "NEGATIVE TEST 28: true & mv state.md blocked (background operator)"
setup_test_loop "negative-28"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="true & mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Background operator & bypass blocked"
else
    fail "background & bypass blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 29: Background & without trailing space (true& mv)
# ========================================

echo "NEGATIVE TEST 29: true& mv state.md blocked (no trailing space after &)"
setup_test_loop "negative-29"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="true& mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Background & without trailing space blocked"
else
    fail "true& mv bypass blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 30: Background & without leading space (true &mv)
# ========================================

echo "NEGATIVE TEST 30: true &mv state.md blocked (no leading space before &)"
setup_test_loop "negative-30"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="true &mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Background & without leading space blocked"
else
    fail "true &mv bypass blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 31: Pipe+stderr |& bypass blocked
# ========================================

echo "NEGATIVE TEST 31: echo foo |& mv state.md blocked (pipe+stderr)"
setup_test_loop "negative-31"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="echo foo |& mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Pipe+stderr |& bypass blocked"
else
    fail "pipe+stderr |& bypass blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 32: sh -c wrapper bypass blocked
# ========================================

echo "NEGATIVE TEST 32: sh -c wrapper bypass blocked"
setup_test_loop "negative-32"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="sh -c 'mv ${LOOP_DIR}/state.md /tmp/foo.txt'"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "sh -c wrapper bypass blocked"
else
    fail "sh -c wrapper blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 33: bash -c wrapper bypass blocked
# ========================================

echo "NEGATIVE TEST 33: bash -c wrapper bypass blocked"
setup_test_loop "negative-33"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="bash -c 'mv ${LOOP_DIR}/state.md /tmp/foo.txt'"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "bash -c wrapper bypass blocked"
else
    fail "bash -c wrapper blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 34: Redirection-prefixed mv state.md blocked (2>/tmp/x mv)
# ========================================

echo "NEGATIVE TEST 34: 2>/tmp/x mv state.md blocked (redirection prefix)"
setup_test_loop "negative-34"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="2>/tmp/x mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Redirection-prefixed 2>/tmp/x mv blocked"
else
    fail "redirection 2>/tmp/x mv blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 35: Redirection-prefixed mv state.md blocked (>/tmp/x mv)
# ========================================

echo "NEGATIVE TEST 35: >/tmp/x mv state.md blocked (redirection prefix)"
setup_test_loop "negative-35"
touch "$LOOP_DIR/.cancel-requested"
COMMAND=">/tmp/x mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Redirection-prefixed >/tmp/x mv blocked"
else
    fail "redirection >/tmp/x mv blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 36: Redirection-prefixed mv state.md blocked (2>&1 mv)
# ========================================

echo "NEGATIVE TEST 36: 2>&1 mv state.md blocked (fd redirection prefix)"
setup_test_loop "negative-36"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="2>&1 mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Redirection-prefixed 2>&1 mv blocked"
else
    fail "redirection 2>&1 mv blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 37: Spaced redirection-prefixed mv state.md blocked (2> /tmp/x mv)
# ========================================

echo "NEGATIVE TEST 37: 2> /tmp/x mv state.md blocked (spaced redirection)"
setup_test_loop "negative-37"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="2> /tmp/x mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Spaced redirection 2> /tmp/x mv blocked"
else
    fail "spaced redirection 2> /tmp/x mv blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 38: &> redirection-prefixed mv state.md blocked (&>/tmp/x mv)
# ========================================

echo "NEGATIVE TEST 38: &>/tmp/x mv state.md blocked (&> redirection)"
setup_test_loop "negative-38"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="&>/tmp/x mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "&> redirection &>/tmp/x mv blocked"
else
    fail "&> redirection &>/tmp/x mv blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 39: Spaced &> redirection-prefixed mv state.md blocked (&> /tmp/x mv)
# ========================================

echo "NEGATIVE TEST 39: &> /tmp/x mv state.md blocked (spaced &> redirection)"
setup_test_loop "negative-39"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="&> /tmp/x mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Spaced &> redirection &> /tmp/x mv blocked"
else
    fail "spaced &> redirection &> /tmp/x mv blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 40: Append redirection-prefixed mv state.md blocked (>>/tmp/x mv)
# ========================================

echo "NEGATIVE TEST 40: >>/tmp/x mv state.md blocked (append redirection)"
setup_test_loop "negative-40"
touch "$LOOP_DIR/.cancel-requested"
COMMAND=">>/tmp/x mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Append redirection >>/tmp/x mv blocked"
else
    fail "append redirection >>/tmp/x mv blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 41: Spaced append redirection-prefixed mv state.md blocked (>> /tmp/x mv)
# ========================================

echo "NEGATIVE TEST 41: >> /tmp/x mv state.md blocked (spaced append redirection)"
setup_test_loop "negative-41"
touch "$LOOP_DIR/.cancel-requested"
COMMAND=">> /tmp/x mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Spaced append redirection >> /tmp/x mv blocked"
else
    fail "spaced append redirection >> /tmp/x mv blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 42: Stderr append redirection-prefixed mv state.md blocked (2>> /tmp/x mv)
# ========================================

echo "NEGATIVE TEST 42: 2>> /tmp/x mv state.md blocked (stderr append redirection)"
setup_test_loop "negative-42"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="2>> /tmp/x mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Stderr append redirection 2>> /tmp/x mv blocked"
else
    fail "stderr append redirection 2>> /tmp/x mv blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 43: Double-quoted redirection target blocked (>> "/tmp/x y" mv)
# ========================================

echo "NEGATIVE TEST 43: >> \"/tmp/x y\" mv state.md blocked (double-quoted target)"
setup_test_loop "negative-43"
touch "$LOOP_DIR/.cancel-requested"
COMMAND=">> \"/tmp/x y\" mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Double-quoted redirection target >> \"/tmp/x y\" mv blocked"
else
    fail "double-quoted redirection target blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 44: Single-quoted redirection target blocked (>> '/tmp/x y' mv)
# ========================================

echo "NEGATIVE TEST 44: >> '/tmp/x y' mv state.md blocked (single-quoted target)"
setup_test_loop "negative-44"
touch "$LOOP_DIR/.cancel-requested"
COMMAND=">> '/tmp/x y' mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Single-quoted redirection target >> '/tmp/x y' mv blocked"
else
    fail "single-quoted redirection target blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 45: Double-quoted &> redirection target blocked (&> "/tmp/x y" mv)
# ========================================

echo "NEGATIVE TEST 45: &> \"/tmp/x y\" mv state.md blocked (double-quoted &> target)"
setup_test_loop "negative-45"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="&> \"/tmp/x y\" mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Double-quoted &> redirection target blocked"
else
    fail "double-quoted &> redirection target blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 46: &>> spaced target blocked (&>> /tmp/x mv)
# ========================================

echo "NEGATIVE TEST 46: &>> /tmp/x mv state.md blocked (&>> spaced target)"
setup_test_loop "negative-46"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="&>> /tmp/x mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "&>> spaced target blocked"
else
    fail "&>> spaced target blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 47: Escaped-space redirection target blocked (>> /tmp/x\ y mv)
# ========================================

echo "NEGATIVE TEST 47: >> /tmp/x\\ y mv state.md blocked (escaped-space target)"
setup_test_loop "negative-47"
touch "$LOOP_DIR/.cancel-requested"
COMMAND=">> /tmp/x\\ y mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Escaped-space redirection target blocked"
else
    fail "escaped-space redirection target blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 48: &>> with escaped-space target blocked (&>> /tmp/x\ y mv)
# ========================================

echo "NEGATIVE TEST 48: &>> /tmp/x\\ y mv state.md blocked (&>> escaped-space target)"
setup_test_loop "negative-48"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="&>> /tmp/x\\ y mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "&>> escaped-space target blocked"
else
    fail "&>> escaped-space target blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 49: ANSI-C quoting redirection target blocked (>> $'/tmp/x y' mv)
# ========================================

echo "NEGATIVE TEST 49: >> \$'/tmp/x y' mv state.md blocked (ANSI-C quoting)"
setup_test_loop "negative-49"
touch "$LOOP_DIR/.cancel-requested"
COMMAND=">> \$'/tmp/x y' mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "ANSI-C quoting redirection target blocked"
else
    fail "ANSI-C quoting redirection target blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 50: ANSI-C quoting &> redirection target blocked (&> $'/tmp/x y' mv)
# ========================================

echo "NEGATIVE TEST 50: &> \$'/tmp/x y' mv state.md blocked (ANSI-C quoting &>)"
setup_test_loop "negative-50"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="&> \$'/tmp/x y' mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "ANSI-C quoting &> redirection target blocked"
else
    fail "ANSI-C quoting &> redirection target blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 51: ANSI-C quoting &>> redirection target blocked (&>> $'/tmp/x y' mv)
# ========================================

echo "NEGATIVE TEST 51: &>> \$'/tmp/x y' mv state.md blocked (ANSI-C quoting &>>)"
setup_test_loop "negative-51"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="&>> \$'/tmp/x y' mv ${LOOP_DIR}/state.md /tmp/foo.txt"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "ANSI-C quoting &>> redirection target blocked"
else
    fail "ANSI-C quoting &>> redirection target blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 52: Unrelated state.md path blocked even with signal
# ========================================

echo "NEGATIVE TEST 52: mv /tmp/state.md /tmp/cancel-state.md blocked (wrong directory)"
setup_test_loop "negative-52"
touch "$LOOP_DIR/.cancel-requested"
# Try to move a state.md outside the active loop dir - should be blocked
COMMAND="mv /tmp/state.md /tmp/cancel-state.md"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Unrelated state.md path blocked even with signal"
else
    fail "unrelated state.md path blocked" "exit 2" "exit $EXIT_CODE"
fi

# ========================================
# NEGATIVE TEST 53: No active loop (no state.md)
# ========================================

echo "NEGATIVE TEST 53: Validator allows commands when no active loop"
rm -rf "$TEST_DIR/.humanize" 2>/dev/null || true
LOOP_DIR="$TEST_DIR/.humanize/rlcr/2024-01-01_12-00-00"
mkdir -p "$LOOP_DIR"
# No state.md created - loop is not active
COMMAND="mv ${LOOP_DIR}/state.md ${LOOP_DIR}/cancel-state.md"

set +e
OUTPUT=$(run_bash_validator "$COMMAND")
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Commands allowed when no active loop (no state.md)"
else
    fail "no active loop allows" "exit 0" "exit $EXIT_CODE"
fi

# ========================================
# Test is_cancel_authorized helper function
# ========================================

echo ""
echo "=== Test: is_cancel_authorized Helper Function ==="
echo ""

# Test helper directly
echo "HELPER TEST 1: is_cancel_authorized returns true with signal and correct command"
setup_test_loop "helper-1"
touch "$LOOP_DIR/.cancel-requested"
COMMAND_LOWER="mv ${LOOP_DIR}/state.md ${LOOP_DIR}/cancel-state.md"
COMMAND_LOWER=$(to_lower "$COMMAND_LOWER")

if is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    pass "is_cancel_authorized returns true with signal and correct command"
else
    fail "helper true case" "returns 0" "returns 1"
fi

echo "HELPER TEST 2: is_cancel_authorized returns false without signal file"
setup_test_loop "helper-2"
# No signal file
COMMAND_LOWER="mv ${LOOP_DIR}/state.md ${LOOP_DIR}/cancel-state.md"
COMMAND_LOWER=$(to_lower "$COMMAND_LOWER")

if is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    fail "helper no signal" "returns 1" "returns 0"
else
    pass "is_cancel_authorized returns false without signal file"
fi

echo "HELPER TEST 3: is_cancel_authorized returns false with wrong command"
setup_test_loop "helper-3"
touch "$LOOP_DIR/.cancel-requested"
COMMAND_LOWER="rm ${LOOP_DIR}/state.md"
COMMAND_LOWER=$(to_lower "$COMMAND_LOWER")

if is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    fail "helper wrong cmd" "returns 1" "returns 0"
else
    pass "is_cancel_authorized returns false with wrong command"
fi

echo "HELPER TEST 4: is_cancel_authorized returns false with 3 arguments"
setup_test_loop "helper-4"
touch "$LOOP_DIR/.cancel-requested"
COMMAND_LOWER="mv ${LOOP_DIR}/state.md /tmp ${LOOP_DIR}/cancel-state.md"
COMMAND_LOWER=$(to_lower "$COMMAND_LOWER")

if is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    fail "helper 3 args" "returns 1" "returns 0"
else
    pass "is_cancel_authorized returns false with 3 arguments (extra arg)"
fi

echo "HELPER TEST 5: is_cancel_authorized allows quoted paths with signal"
setup_test_loop "helper-5"
touch "$LOOP_DIR/.cancel-requested"
COMMAND_LOWER="mv \"${LOOP_DIR}/state.md\" \"${LOOP_DIR}/cancel-state.md\""
COMMAND_LOWER=$(to_lower "$COMMAND_LOWER")

if is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    pass "is_cancel_authorized allows quoted paths"
else
    fail "helper quoted paths" "returns 0" "returns 1"
fi

echo "HELPER TEST 6: is_cancel_authorized rejects extra args before state.md"
setup_test_loop "helper-6"
touch "$LOOP_DIR/.cancel-requested"
COMMAND_LOWER="mv /tmp/extra.txt ${LOOP_DIR}/state.md ${LOOP_DIR}/cancel-state.md"
COMMAND_LOWER=$(to_lower "$COMMAND_LOWER")

if is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    fail "helper extra arg before" "returns 1" "returns 0"
else
    pass "is_cancel_authorized rejects extra args before state.md"
fi

echo "HELPER TEST 7: is_cancel_authorized rejects hidden variables"
setup_test_loop "helper-7"
touch "$LOOP_DIR/.cancel-requested"
# Command with a sneaky ${ifs} variable
COMMAND_LOWER="mv ${LOOP_DIR}/state.md\${ifs}extra ${LOOP_DIR}/cancel-state.md"
COMMAND_LOWER=$(to_lower "$COMMAND_LOWER")

if is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    fail "helper hidden var" "returns 1" "returns 0"
else
    pass "is_cancel_authorized rejects hidden variables"
fi

# ========================================
# Summary
# ========================================

echo ""
echo "========================================="
echo "Test Results"
echo "========================================="
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
echo ""

exit $TESTS_FAILED
