#!/bin/bash
#
# Robustness tests for all hook scripts
#
# Tests hooks not covered by test-hook-input-robustness.sh:
# - loop-edit-validator.sh
# - loop-plan-file-validator.sh
# - loop-codex-stop-hook.sh (state parsing)
# - pr-loop-stop-hook.sh (state parsing)
#
# Focus areas:
# - JSON input validation edge cases
# - Command injection prevention
# - State file parsing robustness
# - Race conditions with concurrent access
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/hooks/lib/loop-common.sh"
source "$PROJECT_ROOT/scripts/portable-timeout.sh"
source "$SCRIPT_DIR/../test-helpers.sh"

setup_test_dir

echo "========================================"
echo "Hook System Robustness Tests"
echo "========================================"
echo ""

# ========================================
# Edit Validator Tests
# ========================================

echo "--- Edit Validator Tests ---"
echo ""

# Test 1: Valid Edit JSON accepted
echo "Test 1: Valid Edit JSON accepted"
JSON='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/test.txt","old_string":"foo","new_string":"bar"}}'
set +e
RESULT=$(echo "$JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/hooks/loop-edit-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Edit hook passes valid JSON"
else
    fail "Edit valid JSON" "exit 0" "exit $EXIT_CODE: $RESULT"
fi

# Test 2: Edit to state.md blocked
echo ""
echo "Test 2: Edit to state.md blocked"
# Create loop state directory with proper state file
mkdir -p "$TEST_DIR/.humanize/rlcr/2026-01-19_00-00-00"
cat > "$TEST_DIR/.humanize/rlcr/2026-01-19_00-00-00/state.md" << 'EOF'
---
current_round: 1
max_iterations: 42
plan_file: plan.md
start_branch: main
base_branch: main
---
EOF

JSON='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_DIR"'/.humanize/rlcr/2026-01-19_00-00-00/state.md","old_string":"1","new_string":"2"}}'
set +e
RESULT=$(echo "$JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/hooks/loop-edit-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
# Should be blocked - exit code non-zero is sufficient
if [[ $EXIT_CODE -ne 0 ]]; then
    pass "Edit to state.md blocked (exit $EXIT_CODE)"
else
    fail "Edit state.md block" "non-zero exit" "exit $EXIT_CODE"
fi

# Test 3: Edit with malformed JSON gracefully handled
echo ""
echo "Test 3: Edit with malformed JSON handled"
INVALID_JSON='{"tool_name":"Edit","tool_input":{"file_path":/broken}}'
set +e
RESULT=$(echo "$INVALID_JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/hooks/loop-edit-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -ne 0 ]] && [[ $EXIT_CODE -lt 128 ]]; then
    pass "Edit hook handles malformed JSON (exit $EXIT_CODE)"
else
    fail "Malformed JSON handling" "non-zero exit" "exit $EXIT_CODE"
fi

# Test 4: Edit with missing file_path field
echo ""
echo "Test 4: Edit with missing file_path field"
JSON='{"tool_name":"Edit","tool_input":{"old_string":"foo","new_string":"bar"}}'
set +e
RESULT=$(echo "$JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/hooks/loop-edit-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
# Should either pass (validator doesn't check this) or fail gracefully
if [[ $EXIT_CODE -lt 128 ]]; then
    pass "Edit handles missing file_path (exit $EXIT_CODE)"
else
    fail "Missing file_path handling" "exit < 128" "exit $EXIT_CODE"
fi

# Test 5: Edit with path traversal - paths outside .humanize are allowed (delegated to Claude sandbox)
echo ""
echo "Test 5: Edit allows paths outside .humanize (sandbox delegates security)"
JSON='{"tool_name":"Edit","tool_input":{"file_path":"../../../etc/passwd","old_string":"foo","new_string":"bar"}}'
set +e
RESULT=$(echo "$JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/hooks/loop-edit-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
# Paths outside .humanize/rlcr are allowed through - sandbox handles security
if [[ $EXIT_CODE -eq 0 ]] && ! echo "$RESULT" | grep -q '"decision".*:.*"block"'; then
    pass "Edit allows paths outside .humanize (exit 0, no block)"
else
    fail "Path outside .humanize" "allowed through" "exit $EXIT_CODE, result: $RESULT"
fi

# Test 5b: Path traversal inside .humanize to state.md is blocked
echo ""
echo "Test 5b: Path traversal to state.md inside .humanize is blocked"
# Create a valid RLCR state for the test
mkdir -p "$TEST_DIR/.humanize/rlcr/2026-01-19_12-00-00"
cat > "$TEST_DIR/.humanize/rlcr/2026-01-19_12-00-00/state.md" << 'EOF'
---
current_round: 1
max_iterations: 42
plan_file: plan.md
start_branch: main
base_branch: main
push_every_round: false
codex_model: o3-mini
codex_effort: medium
codex_timeout: 1200
review_started: false
plan_tracked: false
---
EOF
# Try to access state.md via path traversal (still within .humanize structure)
JSON='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_DIR"'/.humanize/rlcr/2026-01-19_12-00-00/../2026-01-19_12-00-00/state.md","old_string":"current_round: 1","new_string":"current_round: 999"}}'
set +e
RESULT=$(echo "$JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/hooks/loop-edit-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
# state.md edits are blocked with exit 2
if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Path traversal to state.md blocked (exit 2)"
else
    fail "Path traversal to state.md" "exit 2 (blocked)" "exit $EXIT_CODE, result: $RESULT"
fi

# ========================================
# Plan File Validator Tests
# ========================================

echo ""
echo "--- Plan File Validator Tests ---"
echo ""

# Test 6: Valid plan file edit allowed
echo "Test 6: Valid plan file edit allowed"
# Create separate test directory with proper git repo
mkdir -p "$TEST_DIR/plan-test"
cd "$TEST_DIR/plan-test"
git init -q
git config user.email "test@test.com"
git config user.name "Test User"
git config commit.gpgsign false
git checkout -q -b main 2>/dev/null || git checkout -q main
echo "initial" > file.txt
git add file.txt
git commit -q -m "Initial commit"
cd - > /dev/null

echo "# Plan" > "$TEST_DIR/plan-test/plan.md"
# Create loop state with all required fields (including review_started and plan_tracked)
mkdir -p "$TEST_DIR/plan-test/.humanize/rlcr/2026-01-19_12-00-00"
cat > "$TEST_DIR/plan-test/.humanize/rlcr/2026-01-19_12-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 42
plan_file: plan.md
start_branch: main
base_branch: main
push_every_round: false
codex_model: o3-mini
codex_effort: medium
codex_timeout: 1200
review_started: false
plan_tracked: false
---
EOF

JSON='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_DIR/plan-test"'/plan.md","old_string":"# Plan","new_string":"# Updated Plan"}}'
set +e
RESULT=$(echo "$JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR/plan-test" bash "$PROJECT_ROOT/hooks/loop-plan-file-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
# Plan file validator outputs JSON with decision: allow/block
# Check both exit code and JSON output for decision
if [[ $EXIT_CODE -eq 0 ]]; then
    # Check if JSON contains "decision": "block" - if so, it's blocked despite exit 0
    if echo "$RESULT" | grep -q '"decision".*:.*"block"'; then
        fail "Plan file edit" "allowed (no block decision)" "got decision: block"
    else
        pass "Plan file edit allowed (exit 0, no block decision)"
    fi
else
    fail "Plan file edit" "exit 0" "exit $EXIT_CODE: $RESULT"
fi

# Test 7: Non-plan file passes through
echo ""
echo "Test 7: Non-plan file passes through"
JSON='{"tool_name":"Edit","tool_input":{"file_path":"'"$TEST_DIR/plan-test"'/other.txt","old_string":"a","new_string":"b"}}'
set +e
RESULT=$(echo "$JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR/plan-test" bash "$PROJECT_ROOT/hooks/loop-plan-file-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
# Non-plan file should pass through without block decision
if [[ $EXIT_CODE -eq 0 ]] && ! echo "$RESULT" | grep -q '"decision".*:.*"block"'; then
    pass "Non-plan file passes through (no block decision)"
else
    fail "Non-plan file" "pass through" "exit $EXIT_CODE, result: $RESULT"
fi

# Test 8: Plan file validator with empty JSON
echo ""
echo "Test 8: Plan file validator with empty JSON"
set +e
RESULT=$(echo '{}' | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/hooks/loop-plan-file-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -lt 128 ]]; then
    pass "Plan file validator handles empty JSON (exit $EXIT_CODE)"
else
    fail "Empty JSON handling" "exit < 128" "exit $EXIT_CODE"
fi

# ========================================
# State File Parsing Robustness
# ========================================

echo ""
echo "--- State File Parsing Tests ---"
echo ""

# Test 9: State file with extra whitespace
echo "Test 9: State file with extra whitespace parsed"
mkdir -p "$TEST_DIR/ws-state/.humanize/rlcr/2026-01-19_00-00-00"
cat > "$TEST_DIR/ws-state/.humanize/rlcr/2026-01-19_00-00-00/state.md" << 'EOF'
---
current_round:    5
max_iterations:   42
plan_file:  plan.md
---
EOF

ROUND=$(get_current_round "$TEST_DIR/ws-state/.humanize/rlcr/2026-01-19_00-00-00/state.md")
if [[ "$ROUND" == "5" ]]; then
    pass "State with whitespace parsed correctly"
else
    fail "Whitespace parsing" "5" "$ROUND"
fi

# Test 10: State file with Unicode in path field
echo ""
echo "Test 10: State file with special characters in values"
mkdir -p "$TEST_DIR/special-state/.humanize/rlcr/2026-01-19_00-00-00"
cat > "$TEST_DIR/special-state/.humanize/rlcr/2026-01-19_00-00-00/state.md" << 'EOF'
---
current_round: 3
max_iterations: 42
plan_file: "path/to/plan-v2.md"
---
EOF

ROUND=$(get_current_round "$TEST_DIR/special-state/.humanize/rlcr/2026-01-19_00-00-00/state.md")
if [[ "$ROUND" == "3" ]]; then
    pass "State with special path parsed correctly"
else
    fail "Special path parsing" "3" "$ROUND"
fi

# Test 11: State file with missing closing delimiter
echo ""
echo "Test 11: State file with missing closing delimiter"
mkdir -p "$TEST_DIR/bad-state/.humanize/rlcr/2026-01-19_00-00-00"
cat > "$TEST_DIR/bad-state/.humanize/rlcr/2026-01-19_00-00-00/state.md" << 'EOF'
---
current_round: 7
max_iterations: 42
This is content without closing ---
EOF

ROUND=$(get_current_round "$TEST_DIR/bad-state/.humanize/rlcr/2026-01-19_00-00-00/state.md")
# Should return default 0 or parse what it can
if [[ "$ROUND" == "0" ]] || [[ "$ROUND" == "7" ]]; then
    pass "Malformed state handled gracefully (round: $ROUND)"
else
    fail "Malformed state" "0 or 7" "$ROUND"
fi

# ========================================
# Command Injection Prevention Tests
# ========================================

echo ""
echo "--- Command Injection Prevention Tests ---"
echo ""

# Test 12: Bash validator blocks state.md modification attempts
echo "Test 12: Bash validator blocks state.md modification"
# Create RLCR state for the test
mkdir -p "$TEST_DIR/.humanize/rlcr/2026-01-19_12-00-00"
cat > "$TEST_DIR/.humanize/rlcr/2026-01-19_12-00-00/state.md" << 'EOF'
---
current_round: 1
max_iterations: 42
plan_file: plan.md
start_branch: main
base_branch: main
push_every_round: false
codex_model: o3-mini
codex_effort: medium
codex_timeout: 1200
review_started: false
plan_tracked: false
---
EOF
# Try to modify state.md - this SHOULD be blocked
JSON='{"tool_name":"Bash","tool_input":{"command":"echo hacked >> '"$TEST_DIR"'/.humanize/rlcr/2026-01-19_12-00-00/state.md"}}'
set +e
RESULT=$(echo "$JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/hooks/loop-bash-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
# State.md modifications should be blocked with exit 2 and JSON decision: block
if [[ $EXIT_CODE -eq 2 ]]; then
    if echo "$RESULT" | grep -q '"decision".*:.*"block"'; then
        pass "Bash blocks state.md modification (exit 2, decision: block)"
    else
        pass "Bash blocks state.md modification (exit 2)"
    fi
else
    fail "State.md modification" "exit 2 (blocked)" "exit $EXIT_CODE, result: $RESULT"
fi

# Test 12b: Bash validator blocks goal-tracker.md modification after round 0
echo ""
echo "Test 12b: Bash validator blocks goal-tracker.md modification after round 0"
# Try to modify goal-tracker.md when current_round > 0
JSON='{"tool_name":"Bash","tool_input":{"command":"echo modified >> '"$TEST_DIR"'/.humanize/rlcr/2026-01-19_12-00-00/goal-tracker.md"}}'
set +e
RESULT=$(echo "$JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/hooks/loop-bash-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
# Goal tracker modifications after round 0 should be blocked
if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Bash blocks goal-tracker.md modification after round 0 (exit 2)"
else
    fail "Goal-tracker.md modification" "exit 2 (blocked)" "exit $EXIT_CODE, result: $RESULT"
fi

# Test 12c: Unrelated dangerous commands are allowed through (sandbox handles security)
echo ""
echo "Test 12c: Unrelated dangerous commands allowed through (sandbox responsibility)"
JSON='{"tool_name":"Bash","tool_input":{"command":"cat /tmp/test; rm -rf /"}}'
set +e
RESULT=$(echo "$JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/hooks/loop-bash-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
# Unrelated commands pass through - Claude's sandbox handles security
if [[ $EXIT_CODE -eq 0 ]] && ! echo "$RESULT" | grep -q '"decision".*:.*"block"'; then
    pass "Unrelated commands pass through (sandbox responsibility)"
else
    fail "Unrelated command" "allowed through" "exit $EXIT_CODE, result: $RESULT"
fi

# Test 13: Edit validator handles newlines in strings
echo ""
echo "Test 13: Edit validator handles newlines in strings"
# JSON with embedded newlines (valid JSON)
JSON='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/test.txt","old_string":"line1\\nline2","new_string":"line1\\nline3"}}'
set +e
RESULT=$(echo "$JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/hooks/loop-edit-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -lt 128 ]]; then
    pass "Edit handles newlines in strings (exit $EXIT_CODE)"
else
    fail "Newline handling" "exit < 128" "exit $EXIT_CODE"
fi

# Test 14: Write validator handles binary-looking content
echo ""
echo "Test 14: Write validator handles binary-looking content"
JSON='{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.bin","content":"\\x00\\x01\\x02\\x03"}}'
set +e
RESULT=$(echo "$JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/hooks/loop-write-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -lt 128 ]]; then
    pass "Write handles binary-looking content (exit $EXIT_CODE)"
else
    fail "Binary content handling" "exit < 128" "exit $EXIT_CODE"
fi

# ========================================
# Concurrent Access Tests
# ========================================

echo ""
echo "--- Concurrent Access Tests ---"
echo ""

# Test 15: Multiple hook invocations don't corrupt state
echo "Test 15: Multiple concurrent hook invocations"
mkdir -p "$TEST_DIR/concurrent-hooks/.humanize/rlcr/2026-01-19_00-00-00"
cat > "$TEST_DIR/concurrent-hooks/.humanize/rlcr/2026-01-19_00-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 42
plan_file: plan.md
---
EOF

# Spawn multiple hook invocations
for i in $(seq 1 10); do
    JSON='{"tool_name":"Read","tool_input":{"file_path":"/tmp/test'$i'.txt"}}'
    (
        echo "$JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR/concurrent-hooks" bash "$PROJECT_ROOT/hooks/loop-read-validator.sh" >/dev/null 2>&1
    ) &
done
wait

# Check state file wasn't corrupted
if [[ -f "$TEST_DIR/concurrent-hooks/.humanize/rlcr/2026-01-19_00-00-00/state.md" ]]; then
    ROUND=$(get_current_round "$TEST_DIR/concurrent-hooks/.humanize/rlcr/2026-01-19_00-00-00/state.md")
    if [[ "$ROUND" == "0" ]]; then
        pass "Concurrent hook invocations preserve state"
    else
        fail "Concurrent state" "round 0" "round $ROUND"
    fi
else
    fail "State preservation" "file exists" "file missing"
fi

# ========================================
# Stop Hook State Parsing Tests
# ========================================

echo ""
echo "--- Stop Hook State Parsing Tests ---"
echo ""

# Test 16: Stop hook handles missing state gracefully (allows exit)
echo "Test 16: Stop hook allows exit when no state directory"
mkdir -p "$TEST_DIR/no-state"
# No .humanize directory - should allow exit (no block decision)

set +e
OUTPUT=$(CLAUDE_PROJECT_DIR="$TEST_DIR/no-state" bash "$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh" 2>&1)
EXIT_CODE=$?
set -e
# Should exit 0 (pass through) when no loop is active, with no block decision
if [[ $EXIT_CODE -eq 0 ]] && ! echo "$OUTPUT" | grep -q '"decision".*:.*"block"'; then
    pass "Stop hook allows exit when no state (no block decision)"
else
    fail "Missing state handling" "exit 0, no block decision" "exit=$EXIT_CODE, output=$OUTPUT"
fi

# Test 17: PR stop hook handles missing state gracefully (allows exit)
echo ""
echo "Test 17: PR stop hook allows exit when no state directory"
mkdir -p "$TEST_DIR/no-pr-state"

set +e
OUTPUT=$(CLAUDE_PROJECT_DIR="$TEST_DIR/no-pr-state" bash "$PROJECT_ROOT/hooks/pr-loop-stop-hook.sh" 2>&1)
EXIT_CODE=$?
set -e
# Should exit 0, no block decision
if [[ $EXIT_CODE -eq 0 ]] && ! echo "$OUTPUT" | grep -q '"decision".*:.*"block"'; then
    pass "PR stop hook allows exit when no state (no block decision)"
else
    fail "PR missing state" "exit 0, no block decision" "exit=$EXIT_CODE"
fi

# Test 18: Stop hook with corrupted state file outputs block decision
echo ""
echo "Test 18: Stop hook with corrupted state outputs decision"
mkdir -p "$TEST_DIR/corrupt-state/.humanize/rlcr/2026-01-19_00-00-00"
echo "not yaml at all [[[" > "$TEST_DIR/corrupt-state/.humanize/rlcr/2026-01-19_00-00-00/state.md"

set +e
OUTPUT=$(CLAUDE_PROJECT_DIR="$TEST_DIR/corrupt-state" bash "$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh" 2>&1)
EXIT_CODE=$?
set -e
# Should handle gracefully - either block with reason or allow (exit 0 without block)
# The key is it doesn't crash (exit < 128)
if [[ $EXIT_CODE -eq 0 ]]; then
    # Check if it outputs a decision
    if echo "$OUTPUT" | grep -q '"decision"'; then
        pass "Stop hook outputs decision for corrupted state"
    else
        pass "Stop hook allows exit for corrupted state (no active loop detected)"
    fi
else
    fail "Corrupted state handling" "exit 0 with decision" "exit=$EXIT_CODE"
fi

# Test 18b: Stop hook ends loop when state missing required fields (current_round/max_iterations)
echo ""
echo "Test 18b: Stop hook ends loop when missing critical required fields"
mkdir -p "$TEST_DIR/incomplete-state/.humanize/rlcr/2026-01-19_00-00-00"
# State file missing current_round field (required)
cat > "$TEST_DIR/incomplete-state/.humanize/rlcr/2026-01-19_00-00-00/state.md" << 'EOF'
---
max_iterations: 42
plan_file: plan.md
start_branch: main
base_branch: main
push_every_round: false
codex_model: o3-mini
codex_effort: medium
codex_timeout: 1200
review_started: false
plan_tracked: false
---
EOF

set +e
OUTPUT=$(CLAUDE_PROJECT_DIR="$TEST_DIR/incomplete-state" bash "$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh" 2>&1)
EXIT_CODE=$?
set -e
# Missing critical fields causes loop to end as "unexpected" (exit 0, no block)
# Loop ends gracefully rather than blocking
if [[ $EXIT_CODE -eq 0 ]]; then
    # Verify it mentions missing required field
    if echo "$OUTPUT" | grep -qi "missing required field\|current_round"; then
        # Verify state file was renamed to unexpected-state.md
        if [[ -f "$TEST_DIR/incomplete-state/.humanize/rlcr/2026-01-19_00-00-00/unexpected-state.md" ]]; then
            pass "Stop hook ends loop (unexpected) when missing required fields"
        else
            pass "Stop hook allows exit with error when missing required fields"
        fi
    else
        # No error message but still exits 0 - acceptable
        pass "Stop hook allows exit when missing required fields (exit 0)"
    fi
else
    fail "Missing required fields handling" "exit 0 (end loop)" "exit=$EXIT_CODE"
fi

# Test 18c: Stop hook blocks exit when state has all required fields (normal operation)
echo ""
echo "Test 18c: Stop hook blocks exit during active loop (normal operation)"
mkdir -p "$TEST_DIR/active-loop/.humanize/rlcr/2026-01-19_00-00-00"
# Complete valid state file with all required fields
cat > "$TEST_DIR/active-loop/.humanize/rlcr/2026-01-19_00-00-00/state.md" << 'EOF'
---
current_round: 1
max_iterations: 42
plan_file: plan.md
start_branch: main
base_branch: main
push_every_round: false
codex_model: o3-mini
codex_effort: medium
codex_timeout: 1200
review_started: false
plan_tracked: true
---
EOF
# Create plan file so it doesn't fail on missing plan
echo "# Plan" > "$TEST_DIR/active-loop/plan.md"
# Initialize git repo for branch checks
cd "$TEST_DIR/active-loop"
git init -q
git config user.email "test@test.com"
git config user.name "Test User"
git config commit.gpgsign false
echo "init" > init.txt
git add init.txt
git commit -q -m "initial"
cd - > /dev/null

# Create mock codex to avoid real API calls (review_started: false triggers codex exec)
mkdir -p "$TEST_DIR/mock-bin"
cat > "$TEST_DIR/mock-bin/codex" << 'MOCKEOF'
#!/bin/bash
# Mock codex that returns review output indicating work continues
echo "Review: Code looks good but more testing needed."
echo "No COMPLETE or STOP markers - work should continue."
exit 0
MOCKEOF
chmod +x "$TEST_DIR/mock-bin/codex"

set +e
OUTPUT=$(PATH="$TEST_DIR/mock-bin:$PATH" CLAUDE_PROJECT_DIR="$TEST_DIR/active-loop" bash "$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh" 2>&1)
EXIT_CODE=$?
set -e
# Active loop with valid state MUST block exit with decision: block
# This is the expected behavior - no fallback accepted
if [[ $EXIT_CODE -eq 0 ]] && echo "$OUTPUT" | grep -q '"decision".*:.*"block"'; then
    pass "Stop hook blocks exit during active loop (exit 0, decision: block)"
else
    fail "Active loop blocking" "exit 0 with decision:block" "exit=$EXIT_CODE, output: $OUTPUT"
fi

# ========================================
# JSON Edge Cases
# ========================================

echo ""
echo "--- JSON Edge Cases ---"
echo ""

# Test 19: Very large JSON payload
echo "Test 19: Large JSON payload handled"
LARGE_CONTENT=$(head -c 100000 /dev/zero | tr '\0' 'a')
JSON='{"tool_name":"Write","tool_input":{"file_path":"/tmp/large.txt","content":"'"$LARGE_CONTENT"'"}}'
set +e
RESULT=$(echo "$JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR" run_with_timeout 5 bash "$PROJECT_ROOT/hooks/loop-write-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -lt 128 ]]; then
    pass "Large JSON handled (exit $EXIT_CODE)"
else
    fail "Large JSON handling" "exit < 128" "exit $EXIT_CODE"
fi

# Test 20: JSON with null bytes (should be rejected or handled)
echo ""
echo "Test 20: JSON with escaped null handled"
JSON='{"tool_name":"Read","tool_input":{"file_path":"/tmp/test\\u0000.txt"}}'
set +e
RESULT=$(echo "$JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/hooks/loop-read-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -lt 128 ]]; then
    pass "Null byte in JSON handled (exit $EXIT_CODE)"
else
    fail "Null byte handling" "exit < 128" "exit $EXIT_CODE"
fi

# Test 21: Deeply nested JSON
echo ""
echo "Test 21: Deeply nested JSON handled"
# Create nested JSON (10 levels deep)
NESTED_JSON='{"a":{"a":{"a":{"a":{"a":{"a":{"a":{"a":{"a":{"a":"deep"}}}}}}}}}}'
JSON='{"tool_name":"Read","tool_input":{"file_path":"/tmp/test.txt","extra":'"$NESTED_JSON"'}}'
set +e
RESULT=$(echo "$JSON" | CLAUDE_PROJECT_DIR="$TEST_DIR" bash "$PROJECT_ROOT/hooks/loop-read-validator.sh" 2>&1)
EXIT_CODE=$?
set -e
if [[ $EXIT_CODE -lt 128 ]]; then
    pass "Nested JSON handled (exit $EXIT_CODE)"
else
    fail "Nested JSON handling" "exit < 128" "exit $EXIT_CODE"
fi

# ========================================
# Summary
# ========================================

print_test_summary "Hook System Robustness Test Summary"
exit $?
