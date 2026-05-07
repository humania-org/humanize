#!/usr/bin/env bash
#
# Test that setup-rlcr-loop.sh detects inherited-delta sessions and generates
# a session-lineage.md when the most recent prior session's base_commit
# differs from the current session's base_commit.
#
# Positive Test Cases:
# - T-POS-1: inherited_delta field is added to state.md
# - T-POS-2: detection logic uses prior session base_commit comparison
# - T-POS-3: session-lineage.md generation is gated on INHERITED_DELTA == true
# - T-POS-4: lineage file contains commit-range git log between prior + current base
# - T-POS-5: lineage file contains stub for "why a new session is needed"
#
# Negative Test Cases:
# - T-NEG-1: detection block is positioned after BASE_COMMIT capture
# - T-NEG-2: state.md still contains all the existing fields
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo -e "${GREEN}PASS${NC}: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "${RED}FAIL${NC}: $1"; echo "  $2"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

SETUP="$PROJECT_ROOT/scripts/setup-rlcr-loop.sh"

# T-POS-1: state.md template includes inherited_delta field
if grep -qE "^inherited_delta: \\\$INHERITED_DELTA" "$SETUP"; then
    pass "T-POS-1: inherited_delta field is added to state.md template"
else
    fail "T-POS-1: inherited_delta field missing from state.md template" "expected line 'inherited_delta: \$INHERITED_DELTA' inside the heredoc"
fi

# T-POS-2: detection compares prior session base_commit
if grep -qE 'PRIOR_BASE_COMMIT.*!=.*BASE_COMMIT' "$SETUP" && grep -qF 'INHERITED_DELTA="true"' "$SETUP"; then
    pass "T-POS-2: detection compares prior + current base_commit"
else
    fail "T-POS-2: prior-vs-current base_commit comparison missing" "expected explicit comparison setting INHERITED_DELTA=true"
fi

# T-POS-3: lineage file generation is gated on inherited-delta
if grep -qE 'if \[\[ "\$INHERITED_DELTA" == "true" \]\]; then' "$SETUP" \
   && grep -qF 'session-lineage.md' "$SETUP"; then
    pass "T-POS-3: session-lineage.md generation gated on INHERITED_DELTA == true"
else
    fail "T-POS-3: lineage gate or filename missing" "expected gate + literal session-lineage.md filename"
fi

# T-POS-4: lineage file embeds git log of inherited commit range
if grep -qE 'git -C .* log --oneline "\$\{PRIOR_BASE_COMMIT\}\.\.\$\{BASE_COMMIT\}"' "$SETUP" \
   || grep -qE 'log --oneline "\$\{PRIOR_BASE_COMMIT\}\.\.\$\{BASE_COMMIT\}"' "$SETUP"; then
    pass "T-POS-4: lineage embeds git log for prior_base..current_base range"
else
    fail "T-POS-4: lineage commit-range git log missing" "expected git log --oneline \\\${PRIOR_BASE_COMMIT}..\\\${BASE_COMMIT}"
fi

# T-POS-5: lineage stub for "why a new session is needed"
if grep -qiE "why a new session is needed" "$SETUP"; then
    pass "T-POS-5: lineage stub asks why a new session is needed"
else
    fail "T-POS-5: lineage stub for new-session reason missing" "expected literal 'why a new session is needed' prompt in template"
fi

# T-NEG-1: detection block runs after BASE_COMMIT capture
base_commit_line=$(grep -nE 'BASE_COMMIT=\$\(run_with_timeout' "$SETUP" | head -1 | cut -d: -f1)
detection_line=$(grep -n 'Detect inherited-delta session' "$SETUP" | head -1 | cut -d: -f1)
if [[ -n "$base_commit_line" ]] && [[ -n "$detection_line" ]] && [[ "$detection_line" -gt "$base_commit_line" ]]; then
    pass "T-NEG-1: detection block ($detection_line) runs after BASE_COMMIT capture ($base_commit_line)"
else
    fail "T-NEG-1: detection block positioning wrong" "BASE_COMMIT capture: line $base_commit_line; detection: line $detection_line"
fi

# T-NEG-2: state.md template still has the original fields
for field in "current_round:" "max_iterations:" "plan_file:" "base_commit:" "base_branch:" "started_at:"; do
    if grep -qE "^${field}" "$SETUP"; then
        pass "T-NEG-2: state.md still contains $field"
    else
        fail "T-NEG-2: state.md regressed $field" "expected line starting with $field in state.md heredoc"
    fi
done

# Syntax check
if bash -n "$SETUP" 2>/dev/null; then
    pass "T-NEG-3: setup-rlcr-loop.sh passes bash syntax check"
else
    fail "T-NEG-3: setup-rlcr-loop.sh syntax error" "bash -n returned non-zero"
fi

echo ""
echo "Total: $TESTS_PASSED passed, $TESTS_FAILED failed"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
