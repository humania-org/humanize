#!/bin/bash
#
# Robustness tests for cancel operation security (AC-10)
#
# Tests cancel authorization and path bypass prevention:
# - Signal file validation
# - Path bypass attempts
# - Quote handling
# - Escape sequences
# - Symlink rejection
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/hooks/lib/loop-common.sh"
source "$SCRIPT_DIR/../test-helpers.sh"

setup_test_dir

echo "========================================"
echo "Cancel Security Robustness Tests (AC-10)"
echo "========================================"
echo ""

# Create a mock active loop directory
LOOP_DIR="$TEST_DIR/loop"
mkdir -p "$LOOP_DIR"
touch "$LOOP_DIR/state.md"

# ========================================
# Positive Tests - Valid Cancel Operations
# ========================================

echo "--- Positive Tests: Valid Cancel Operations ---"
echo ""

# Test 1: Valid cancel authorization with signal file
echo "Test 1: Valid cancel authorization with signal file"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="mv \"$LOOP_DIR/state.md\" \"$LOOP_DIR/cancel-state.md\""
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    pass "Accepts valid cancel command with signal file"
else
    fail "Valid cancel" "authorized" "rejected"
fi
rm -f "$LOOP_DIR/.cancel-requested"

# Test 2: Cancel with finalize-state.md source
echo ""
echo "Test 2: Cancel with finalize-state.md source"
touch "$LOOP_DIR/.cancel-requested"
touch "$LOOP_DIR/finalize-state.md"
COMMAND="mv \"$LOOP_DIR/finalize-state.md\" \"$LOOP_DIR/cancel-state.md\""
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    pass "Accepts cancel from finalize-state.md"
else
    fail "Finalize cancel" "authorized" "rejected"
fi
rm -f "$LOOP_DIR/.cancel-requested" "$LOOP_DIR/finalize-state.md"

# Test 3: Cancel with single quotes
echo ""
echo "Test 3: Cancel with single quotes"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="mv '$LOOP_DIR/state.md' '$LOOP_DIR/cancel-state.md'"
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    pass "Accepts cancel with single quotes"
else
    fail "Single quotes" "authorized" "rejected"
fi
rm -f "$LOOP_DIR/.cancel-requested"

# Test 4: Cancel with unquoted paths
echo ""
echo "Test 4: Cancel with unquoted paths"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="mv $LOOP_DIR/state.md $LOOP_DIR/cancel-state.md"
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    pass "Accepts cancel with unquoted paths"
else
    fail "Unquoted paths" "authorized" "rejected"
fi
rm -f "$LOOP_DIR/.cancel-requested"

# ========================================
# Negative Tests - Bypass Attempts
# ========================================

echo ""
echo "--- Negative Tests: Bypass Attempts ---"
echo ""

# Test 5: Missing signal file
echo "Test 5: Reject cancel without signal file"
COMMAND="mv \"$LOOP_DIR/state.md\" \"$LOOP_DIR/cancel-state.md\""
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if ! is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    pass "Rejects cancel without signal file"
else
    fail "No signal file" "rejected" "authorized"
fi

# Test 6: Command substitution injection
echo ""
echo "Test 6: Reject command substitution"
touch "$LOOP_DIR/.cancel-requested"
COMMAND='mv "$(whoami)" "$LOOP_DIR/cancel-state.md"'
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if ! is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    pass "Rejects command substitution"
else
    fail "Command substitution" "rejected" "authorized"
fi
rm -f "$LOOP_DIR/.cancel-requested"

# Test 7: Backtick injection
echo ""
echo "Test 7: Reject backtick injection"
touch "$LOOP_DIR/.cancel-requested"
COMMAND='mv `cat /etc/passwd` "$LOOP_DIR/cancel-state.md"'
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if ! is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    pass "Rejects backtick injection"
else
    fail "Backtick injection" "rejected" "authorized"
fi
rm -f "$LOOP_DIR/.cancel-requested"

# Test 8: Semicolon command chaining
echo ""
echo "Test 8: Reject semicolon command chaining"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="mv \"$LOOP_DIR/state.md\" \"$LOOP_DIR/cancel-state.md\"; rm -rf /"
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if ! is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    pass "Rejects semicolon chaining"
else
    fail "Semicolon chaining" "rejected" "authorized"
fi
rm -f "$LOOP_DIR/.cancel-requested"

# Test 9: AND operator chaining
echo ""
echo "Test 9: Reject && operator chaining"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="mv \"$LOOP_DIR/state.md\" \"$LOOP_DIR/cancel-state.md\" && echo hacked"
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if ! is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    pass "Rejects && operator"
else
    fail "AND operator" "rejected" "authorized"
fi
rm -f "$LOOP_DIR/.cancel-requested"

# Test 10: Pipe operator
echo ""
echo "Test 10: Reject pipe operator"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="mv \"$LOOP_DIR/state.md\" | cat"
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if ! is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    pass "Rejects pipe operator"
else
    fail "Pipe operator" "rejected" "authorized"
fi
rm -f "$LOOP_DIR/.cancel-requested"

# Test 11: Wrong destination path
echo ""
echo "Test 11: Reject wrong destination path"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="mv \"$LOOP_DIR/state.md\" \"/tmp/evil-state.md\""
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if ! is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    pass "Rejects wrong destination"
else
    fail "Wrong destination" "rejected" "authorized"
fi
rm -f "$LOOP_DIR/.cancel-requested"

# Test 12: Wrong source path
echo ""
echo "Test 12: Reject wrong source path"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="mv \"/etc/passwd\" \"$LOOP_DIR/cancel-state.md\""
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if ! is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    pass "Rejects wrong source"
else
    fail "Wrong source" "rejected" "authorized"
fi
rm -f "$LOOP_DIR/.cancel-requested"

# Test 13: Extra arguments
echo ""
echo "Test 13: Reject extra arguments"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="mv \"$LOOP_DIR/state.md\" \"$LOOP_DIR/cancel-state.md\" extra_arg"
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if ! is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    pass "Rejects extra arguments"
else
    fail "Extra arguments" "rejected" "authorized"
fi
rm -f "$LOOP_DIR/.cancel-requested"

# Test 14: Newline injection
echo ""
echo "Test 14: Reject newline injection"
touch "$LOOP_DIR/.cancel-requested"
COMMAND=$'mv "$LOOP_DIR/state.md" "$LOOP_DIR/cancel-state.md"\nrm -rf /'
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if ! is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    pass "Rejects newline injection"
else
    fail "Newline injection" "rejected" "authorized"
fi
rm -f "$LOOP_DIR/.cancel-requested"

# Test 15: Variable expansion attempt
echo ""
echo "Test 15: Reject remaining variable expansion"
touch "$LOOP_DIR/.cancel-requested"
COMMAND='mv "${HOME}/state.md" "$LOOP_DIR/cancel-state.md"'
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if ! is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    pass "Rejects variable expansion"
else
    fail "Variable expansion" "rejected" "authorized"
fi
rm -f "$LOOP_DIR/.cancel-requested"

# Test 16: Not an mv command
echo ""
echo "Test 16: Reject non-mv commands"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="cp \"$LOOP_DIR/state.md\" \"$LOOP_DIR/cancel-state.md\""
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if ! is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    pass "Rejects non-mv commands"
else
    fail "Non-mv command" "rejected" "authorized"
fi
rm -f "$LOOP_DIR/.cancel-requested"

# Test 17: OR operator
echo ""
echo "Test 17: Reject || operator"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="mv \"$LOOP_DIR/state.md\" \"$LOOP_DIR/cancel-state.md\" || echo fail"
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if ! is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    pass "Rejects || operator"
else
    fail "OR operator" "rejected" "authorized"
fi
rm -f "$LOOP_DIR/.cancel-requested"

# Test 18: Path with /./  normalization
echo ""
echo "Test 18: Accept path with /./ (normalized)"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="mv \"$LOOP_DIR/./state.md\" \"$LOOP_DIR/cancel-state.md\""
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    pass "Accepts normalized path with /./"
else
    fail "Path normalization" "authorized" "rejected"
fi
rm -f "$LOOP_DIR/.cancel-requested"

# Test 19: Mixed quote styles are rejected
echo ""
echo "Test 19: Rejects mixed quote styles"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="mv \"$LOOP_DIR/state.md\" '$LOOP_DIR/cancel-state.md'"
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if ! is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    pass "Rejects mixed quotes"
else
    fail "Mixed quotes rejection" "rejected" "authorized"
fi
rm -f "$LOOP_DIR/.cancel-requested"

# Test 20: IFS manipulation attempt
echo ""
echo "Test 20: Reject IFS manipulation"
touch "$LOOP_DIR/.cancel-requested"
COMMAND='mv ${IFS} "$LOOP_DIR/cancel-state.md"'
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if ! is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    pass "Rejects IFS manipulation"
else
    fail "IFS manipulation" "rejected" "authorized"
fi
rm -f "$LOOP_DIR/.cancel-requested"

# Test 21: Multiple trailing spaces are rejected
echo ""
echo "Test 21: Rejects multiple trailing spaces"
touch "$LOOP_DIR/.cancel-requested"
COMMAND="mv \"$LOOP_DIR/state.md\" \"$LOOP_DIR/cancel-state.md\"   "
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if ! is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    pass "Rejects multiple trailing spaces"
else
    fail "Trailing spaces rejection" "rejected" "authorized"
fi
rm -f "$LOOP_DIR/.cancel-requested"

# Test 22: Symlink in cancel source path (wrong filename)
echo ""
echo "Test 22: Reject non-standard source file name"
touch "$LOOP_DIR/.cancel-requested"
ln -sf "$LOOP_DIR/state.md" "$LOOP_DIR/state-link.md" 2>/dev/null || true
COMMAND="mv \"$LOOP_DIR/state-link.md\" \"$LOOP_DIR/cancel-state.md\""
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
# Function validates only state.md or finalize-state.md as valid source names
if ! is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    pass "Rejects non-standard source file name"
else
    fail "Non-standard source name" "rejected" "accepted"
fi
rm -f "$LOOP_DIR/.cancel-requested" "$LOOP_DIR/state-link.md"

# Test 23: Filesystem symlink check
echo ""
echo "Test 23: Rejects state.md as symlink"
touch "$LOOP_DIR/.cancel-requested"
# Create a real file to point to
echo "real state" > "$LOOP_DIR/real-state.md"
# Replace state.md with a symlink
rm -f "$LOOP_DIR/state.md"
ln -s "$LOOP_DIR/real-state.md" "$LOOP_DIR/state.md"
COMMAND="mv \"$LOOP_DIR/state.md\" \"$LOOP_DIR/cancel-state.md\""
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if ! is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    pass "Rejects symlink state.md (exit: $?)"
else
    fail "Symlink state.md rejection" "rejected" "accepted"
fi
# Restore normal state.md
rm -f "$LOOP_DIR/state.md" "$LOOP_DIR/real-state.md"
touch "$LOOP_DIR/state.md"
rm -f "$LOOP_DIR/.cancel-requested"

# Test 24: Filesystem symlink check for finalize-state.md
echo ""
echo "Test 24: Rejects finalize-state.md as symlink"
touch "$LOOP_DIR/.cancel-requested"
# Create real file and symlink finalize-state.md
echo "real finalize" > "$LOOP_DIR/real-finalize.md"
ln -s "$LOOP_DIR/real-finalize.md" "$LOOP_DIR/finalize-state.md"
COMMAND="mv \"$LOOP_DIR/finalize-state.md\" \"$LOOP_DIR/cancel-state.md\""
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if ! is_cancel_authorized "$LOOP_DIR" "$COMMAND_LOWER"; then
    pass "Rejects symlink finalize-state.md"
else
    fail "Symlink finalize-state.md rejection" "rejected" "accepted"
fi
rm -f "$LOOP_DIR/finalize-state.md" "$LOOP_DIR/real-finalize.md" "$LOOP_DIR/.cancel-requested"

# Test 25: Regression test - loop dir path containing "finalize" should not bypass symlink check
echo ""
echo "Test 25: Loop dir with 'finalize' in path - state.md symlink rejected"
# Create a loop directory with "finalize" in the path
TRICKY_LOOP_DIR="$TEST_DIR/finalize-project/loop"
mkdir -p "$TRICKY_LOOP_DIR"
touch "$TRICKY_LOOP_DIR/.cancel-requested"
# Create a symlink for state.md (not finalize-state.md)
echo "real state" > "$TRICKY_LOOP_DIR/real-state.md"
ln -s "$TRICKY_LOOP_DIR/real-state.md" "$TRICKY_LOOP_DIR/state.md"
COMMAND="mv \"$TRICKY_LOOP_DIR/state.md\" \"$TRICKY_LOOP_DIR/cancel-state.md\""
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
# Bug: substring match on *finalize* could misclassify state.md as finalize-state.md
# The fix uses exact path matching instead
if ! is_cancel_authorized "$TRICKY_LOOP_DIR" "$COMMAND_LOWER"; then
    pass "Rejects state.md symlink even when path contains 'finalize'"
else
    fail "Path contains finalize regression" "rejected" "accepted (symlink bypass)"
fi
rm -rf "$TEST_DIR/finalize-project"

# Test 26: Path with "finalize" - finalize-state.md symlink also rejected
echo ""
echo "Test 26: Loop dir with 'finalize' in path - finalize-state.md symlink rejected"
TRICKY_LOOP_DIR2="$TEST_DIR/finalize-test/loop"
mkdir -p "$TRICKY_LOOP_DIR2"
touch "$TRICKY_LOOP_DIR2/.cancel-requested"
echo "real finalize" > "$TRICKY_LOOP_DIR2/real-finalize.md"
ln -s "$TRICKY_LOOP_DIR2/real-finalize.md" "$TRICKY_LOOP_DIR2/finalize-state.md"
COMMAND="mv \"$TRICKY_LOOP_DIR2/finalize-state.md\" \"$TRICKY_LOOP_DIR2/cancel-state.md\""
COMMAND_LOWER=$(echo "$COMMAND" | tr '[:upper:]' '[:lower:]')
if ! is_cancel_authorized "$TRICKY_LOOP_DIR2" "$COMMAND_LOWER"; then
    pass "Rejects finalize-state.md symlink when path contains 'finalize'"
else
    fail "Finalize path regression" "rejected" "accepted (symlink bypass)"
fi
rm -rf "$TEST_DIR/finalize-test"

# ========================================
# Summary
# ========================================

print_test_summary "Cancel Security Robustness Test Summary"
exit $?
