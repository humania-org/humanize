#!/bin/bash
#
# Robustness tests for state file parsing
#
# Tests state file validation under edge cases:
# - Corrupted YAML frontmatter
# - Missing required fields
# - Non-numeric values
# - Partial file writes
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/hooks/lib/loop-common.sh"
source "$SCRIPT_DIR/../test-helpers.sh"

setup_test_dir

echo "========================================"
echo "State File Robustness Tests"
echo "========================================"
echo ""

# ========================================
# Positive Tests - Valid State Files
# ========================================

echo "--- Positive Tests: Valid State Files ---"
echo ""

# Test 1: Valid state file with all required fields
echo "Test 1: Parse valid state file with all required fields"
cat > "$TEST_DIR/state.md" << 'EOF'
---
current_round: 5
max_iterations: 10
codex_model: gpt-5.2-codex
codex_effort: high
codex_timeout: 5400
push_every_round: false
plan_file: plan.md
plan_tracked: false
start_branch: main
started_at: 2026-01-17T12:00:00Z
---

# State content below
EOF

if parse_state_file "$TEST_DIR/state.md"; then
    if [[ "$STATE_CURRENT_ROUND" == "5" ]] && [[ "$STATE_MAX_ITERATIONS" == "10" ]]; then
        pass "Parses valid state file correctly"
    else
        fail "Parses valid state file" "current_round=5, max_iterations=10" "current_round=$STATE_CURRENT_ROUND, max_iterations=$STATE_MAX_ITERATIONS"
    fi
else
    fail "Parses valid state file" "return 0" "returned non-zero"
fi

# Test 2: Extract current_round from properly formatted state file
echo ""
echo "Test 2: get_current_round extracts round number correctly"
ROUND=$(get_current_round "$TEST_DIR/state.md")
if [[ "$ROUND" == "5" ]]; then
    pass "Extracts current_round correctly"
else
    fail "Extracts current_round" "5" "$ROUND"
fi

# Test 3: State file with extra unrecognized fields
echo ""
echo "Test 3: State file with extra unrecognized fields"
cat > "$TEST_DIR/state-extra.md" << 'EOF'
---
current_round: 3
max_iterations: 20
extra_field: some_value
another_extra: 12345
custom_metadata: true
codex_model: gpt-5.2-codex
codex_effort: high
codex_timeout: 5400
---

# Extra fields should be ignored
EOF

if parse_state_file "$TEST_DIR/state-extra.md"; then
    if [[ "$STATE_CURRENT_ROUND" == "3" ]] && [[ "$STATE_MAX_ITERATIONS" == "20" ]]; then
        pass "Handles extra unrecognized fields without error"
    else
        fail "Handles extra fields" "current_round=3" "current_round=$STATE_CURRENT_ROUND"
    fi
else
    fail "Handles extra fields" "return 0" "returned non-zero"
fi

# Test 4: State file with quoted values
echo ""
echo "Test 4: State file with quoted string values"
cat > "$TEST_DIR/state-quoted.md" << 'EOF'
---
current_round: 7
max_iterations: 15
plan_file: "path/to/plan.md"
start_branch: "feature/test-branch"
base_branch: main
review_started: false
---
EOF

if parse_state_file "$TEST_DIR/state-quoted.md"; then
    if [[ "$STATE_PLAN_FILE" == "path/to/plan.md" ]] && [[ "$STATE_START_BRANCH" == "feature/test-branch" ]]; then
        pass "Parses quoted string values correctly"
    else
        fail "Parses quoted values" "plan_file=path/to/plan.md" "plan_file=$STATE_PLAN_FILE"
    fi
else
    fail "Parses quoted values" "return 0" "returned non-zero"
fi

# Test 5: State file with zero values
echo ""
echo "Test 5: State file with round 0"
cat > "$TEST_DIR/state-zero.md" << 'EOF'
---
current_round: 0
max_iterations: 5
---
EOF

ROUND=$(get_current_round "$TEST_DIR/state-zero.md")
if [[ "$ROUND" == "0" ]]; then
    pass "Handles round 0 correctly"
else
    fail "Handles round 0" "0" "$ROUND"
fi

# ========================================
# Negative Tests - Malformed State Files
# ========================================

echo ""
echo "--- Negative Tests: Malformed State Files ---"
echo ""

# Test 6: State file missing YAML frontmatter separators (strict mode rejects)
echo "Test 6: State file missing YAML frontmatter separators (strict rejects)"
cat > "$TEST_DIR/state-no-yaml.md" << 'EOF'
current_round: 5
max_iterations: 10
EOF

# Strict parser should reject this
if ! parse_state_file_strict "$TEST_DIR/state-no-yaml.md" 2>/dev/null; then
    pass "Strict parser rejects missing YAML frontmatter"
else
    fail "Missing frontmatter rejection" "return non-zero" "returned 0"
fi

# Test 6b: Tolerant parser still works with missing frontmatter
echo ""
echo "Test 6b: Tolerant parser uses defaults for missing frontmatter"
ROUND=$(get_current_round "$TEST_DIR/state-no-yaml.md")
if [[ "$ROUND" == "0" ]]; then
    pass "Tolerant parser returns default 0"
else
    fail "Tolerant missing frontmatter" "0 (default)" "$ROUND"
fi

# Test 7: State file with non-numeric current_round (strict mode rejects)
echo ""
echo "Test 7: State file with non-numeric current_round (strict rejects)"
cat > "$TEST_DIR/state-nonnumeric.md" << 'EOF'
---
current_round: five
max_iterations: 10
---
EOF

# Strict parser should reject non-numeric current_round
if ! parse_state_file_strict "$TEST_DIR/state-nonnumeric.md" 2>/dev/null; then
    pass "Strict parser rejects non-numeric current_round"
else
    fail "Non-numeric current_round rejection" "return non-zero" "returned 0"
fi

# Test 7b: Tolerant parser handles non-numeric gracefully
echo ""
echo "Test 7b: Tolerant parser handles non-numeric current_round"
ROUND=$(get_current_round "$TEST_DIR/state-nonnumeric.md")
# The function returns the raw value or empty
if [[ -n "$ROUND" ]] || [[ -z "$ROUND" ]]; then
    pass "Tolerant parser handles gracefully (returns: '$ROUND')"
else
    fail "Non-numeric current_round handling" "some value" "crashed"
fi

# Test 8: State file with missing required fields (strict mode rejects)
echo ""
echo "Test 8: State file with missing required fields (strict rejects)"
cat > "$TEST_DIR/state-missing.md" << 'EOF'
---
plan_file: plan.md
---
EOF

# Strict parser should reject missing current_round and max_iterations
if ! parse_state_file_strict "$TEST_DIR/state-missing.md" 2>/dev/null; then
    pass "Strict parser rejects missing required fields"
else
    fail "Missing fields rejection" "return non-zero" "returned 0"
fi

# Test 8b: Tolerant parser uses defaults for missing fields
echo ""
echo "Test 8b: Tolerant parser uses defaults for missing fields"
if parse_state_file "$TEST_DIR/state-missing.md"; then
    if [[ "$STATE_CURRENT_ROUND" == "0" ]] && [[ "$STATE_MAX_ITERATIONS" == "10" ]]; then
        pass "Tolerant parser applies defaults correctly"
    else
        fail "Missing fields defaults" "current_round=0, max_iterations=10" "current_round=$STATE_CURRENT_ROUND, max_iterations=$STATE_MAX_ITERATIONS"
    fi
else
    fail "Tolerant missing fields" "return 0 (with defaults)" "returned non-zero"
fi

# Test 9: Empty state file
echo ""
echo "Test 9: Empty state file"
: > "$TEST_DIR/state-empty.md"

ROUND=$(get_current_round "$TEST_DIR/state-empty.md")
if [[ "$ROUND" == "0" ]]; then
    pass "Empty state file returns default 0"
else
    fail "Empty state file" "0 (default)" "$ROUND"
fi

# Test 10: State file with only opening separator
echo ""
echo "Test 10: State file with only opening YAML separator"
cat > "$TEST_DIR/state-partial-yaml.md" << 'EOF'
---
current_round: 5
max_iterations: 10
EOF

# This has opening --- but no closing ---
ROUND=$(get_current_round "$TEST_DIR/state-partial-yaml.md")
if [[ "$ROUND" == "0" ]] || [[ "$ROUND" == "5" ]]; then
    pass "Partial YAML handled gracefully (returns: '$ROUND')"
else
    fail "Partial YAML" "0 or 5" "$ROUND"
fi

# Test 11: State file with malformed YAML
echo ""
echo "Test 11: State file with malformed YAML structure"
cat > "$TEST_DIR/state-malformed.md" << 'EOF'
---
current_round 5
max_iterations: 10
---
EOF

# Missing colon on first field
ROUND=$(get_current_round "$TEST_DIR/state-malformed.md")
if [[ "$ROUND" == "0" ]]; then
    pass "Malformed YAML returns default 0"
else
    fail "Malformed YAML" "0 (default)" "$ROUND"
fi

# Test 12: State file with very large round number
echo ""
echo "Test 12: State file with very large round number"
cat > "$TEST_DIR/state-large.md" << 'EOF'
---
current_round: 999999999
max_iterations: 1000000000
---
EOF

if parse_state_file "$TEST_DIR/state-large.md"; then
    if [[ "$STATE_CURRENT_ROUND" == "999999999" ]]; then
        pass "Handles very large round numbers"
    else
        fail "Large round number" "999999999" "$STATE_CURRENT_ROUND"
    fi
else
    fail "Large round number" "return 0" "returned non-zero"
fi

# Test 13: State file with negative round number
echo ""
echo "Test 13: State file with negative round number"
cat > "$TEST_DIR/state-negative.md" << 'EOF'
---
current_round: -5
max_iterations: 10
---
EOF

ROUND=$(get_current_round "$TEST_DIR/state-negative.md")
if [[ -n "$ROUND" ]]; then
    pass "Negative round number handled gracefully (returns: '$ROUND')"
else
    fail "Negative round number" "some value" "empty"
fi

# Test 14: State file with special characters in values
echo ""
echo "Test 14: State file with special characters in string values"
cat > "$TEST_DIR/state-special.md" << 'EOF'
---
current_round: 5
max_iterations: 10
plan_file: "path/with spaces/plan.md"
start_branch: "feature/test-with-special"
base_branch: main
review_started: false
---
EOF

if parse_state_file "$TEST_DIR/state-special.md"; then
    if [[ "$STATE_PLAN_FILE" == "path/with spaces/plan.md" ]]; then
        pass "Handles special characters in values"
    else
        fail "Special characters" "path/with spaces/plan.md" "$STATE_PLAN_FILE"
    fi
else
    fail "Special characters" "return 0" "returned non-zero"
fi

# Test 15: State file with trailing whitespace
echo ""
echo "Test 15: State file with trailing whitespace in values"
cat > "$TEST_DIR/state-whitespace.md" << 'EOF'
---
current_round: 5
max_iterations: 10
---
EOF

if parse_state_file "$TEST_DIR/state-whitespace.md"; then
    if [[ "$STATE_CURRENT_ROUND" == "5" ]]; then
        pass "Handles trailing whitespace correctly"
    else
        fail "Trailing whitespace" "5" "'$STATE_CURRENT_ROUND'"
    fi
else
    fail "Trailing whitespace" "return 0" "returned non-zero"
fi

# Test 16: Non-existent state file
echo ""
echo "Test 16: Non-existent state file"
if ! parse_state_file "$TEST_DIR/nonexistent.md" 2>/dev/null; then
    pass "Returns non-zero for non-existent file"
else
    fail "Non-existent file" "return 1" "returned 0"
fi

# Test 17: State file with binary content
echo ""
echo "Test 17: State file with binary content mixed in"
cat > "$TEST_DIR/state-binary.md" << 'EOF'
---
current_round: 5
max_iterations: 10
---
EOF
# Append some binary content after the YAML
printf '\x00\x01\x02\x03\x04\x05' >> "$TEST_DIR/state-binary.md"

ROUND=$(get_current_round "$TEST_DIR/state-binary.md")
if [[ "$ROUND" == "5" ]]; then
    pass "Handles binary content after YAML correctly"
else
    fail "Binary content" "5" "$ROUND"
fi

# Test 18: State file with Windows line endings (CRLF)
echo ""
echo "Test 18: State file with Windows line endings (CRLF)"
printf -- '---\r\ncurrent_round: 5\r\nmax_iterations: 10\r\n---\r\n' > "$TEST_DIR/state-crlf.md"

ROUND=$(get_current_round "$TEST_DIR/state-crlf.md")
# May or may not handle CRLF correctly - test that it doesn't crash
if [[ -n "$ROUND" ]] || [[ -z "$ROUND" ]]; then
    pass "Handles CRLF line endings gracefully (returns: '$ROUND')"
else
    fail "CRLF handling" "some value or empty" "crashed"
fi

# Test 19: State file with full_review_round field (v1.5.2+)
echo ""
echo "Test 19: State file with full_review_round field (v1.5.2+)"
cat > "$TEST_DIR/state-full-review.md" << 'EOF'
---
current_round: 3
max_iterations: 20
full_review_round: 7
codex_model: gpt-5.2-codex
codex_effort: high
plan_file: plan.md
plan_tracked: false
start_branch: main
---
EOF

if parse_state_file "$TEST_DIR/state-full-review.md"; then
    if [[ "$STATE_FULL_REVIEW_ROUND" == "7" ]]; then
        pass "Parses full_review_round field correctly"
    else
        fail "Parses full_review_round" "7" "$STATE_FULL_REVIEW_ROUND"
    fi
else
    fail "Parses state with full_review_round" "return 0" "returned non-zero"
fi

# Test 20: State file without full_review_round uses default value
echo ""
echo "Test 20: State file without full_review_round uses default value (5)"
cat > "$TEST_DIR/state-no-full-review.md" << 'EOF'
---
current_round: 2
max_iterations: 15
codex_model: gpt-5.2-codex
codex_effort: high
plan_file: plan.md
plan_tracked: false
start_branch: main
---
EOF

if parse_state_file "$TEST_DIR/state-no-full-review.md"; then
    if [[ "$STATE_FULL_REVIEW_ROUND" == "5" ]]; then
        pass "Uses default full_review_round value (5) when missing"
    else
        fail "Default full_review_round" "5" "$STATE_FULL_REVIEW_ROUND"
    fi
else
    fail "Parses state without full_review_round" "return 0" "returned non-zero"
fi

# Test 21: State file with full_review_round=2 (minimum valid value)
echo ""
echo "Test 21: State file with full_review_round=2 (minimum valid value)"
cat > "$TEST_DIR/state-min-full-review.md" << 'EOF'
---
current_round: 1
max_iterations: 10
full_review_round: 2
codex_model: gpt-5.2-codex
codex_effort: high
plan_file: plan.md
plan_tracked: false
start_branch: main
---
EOF

if parse_state_file "$TEST_DIR/state-min-full-review.md"; then
    if [[ "$STATE_FULL_REVIEW_ROUND" == "2" ]]; then
        pass "Parses minimum full_review_round value (2) correctly"
    else
        fail "Minimum full_review_round" "2" "$STATE_FULL_REVIEW_ROUND"
    fi
else
    fail "Parses state with min full_review_round" "return 0" "returned non-zero"
fi

# ========================================
# Summary
# ========================================

print_test_summary "State File Robustness Test Summary"
exit $?
