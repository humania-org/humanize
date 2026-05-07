#!/usr/bin/env bash
#
# Test that the finalize-phase prompt template documents the required
# Outcome classification line (no-op / cosmetic / substantive).
#
# Positive Test Cases:
# - T-POS-1: template contains "Outcome: no-op (already-minimal)" exact form
# - T-POS-2: template contains "Outcome: cosmetic (formatting only)" exact form
# - T-POS-3: template contains "Outcome: substantive (logic edits)" exact form
# - T-POS-4: template explains that no-op is NOT failure
#
# Negative Test Cases:
# - T-NEG-1: template does not regress placeholders ({{FINALIZE_SUMMARY_FILE}}, etc.)
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

TEMPLATE_FILE="$PROJECT_ROOT/prompt-template/claude/finalize-phase-prompt.md"

if [[ ! -f "$TEMPLATE_FILE" ]]; then
    fail "template file exists" "expected file at $TEMPLATE_FILE"
    echo "Total: $TESTS_PASSED passed, $TESTS_FAILED failed"
    exit 1
fi

# T-POS-1
if grep -qF "Outcome: no-op (already-minimal)" "$TEMPLATE_FILE"; then
    pass "T-POS-1: no-op classification line documented"
else
    fail "T-POS-1: no-op classification line missing" "expected 'Outcome: no-op (already-minimal)' literal in template"
fi

# T-POS-2
if grep -qF "Outcome: cosmetic (formatting only)" "$TEMPLATE_FILE"; then
    pass "T-POS-2: cosmetic classification line documented"
else
    fail "T-POS-2: cosmetic classification line missing" "expected 'Outcome: cosmetic (formatting only)' literal in template"
fi

# T-POS-3
if grep -qF "Outcome: substantive (logic edits)" "$TEMPLATE_FILE"; then
    pass "T-POS-3: substantive classification line documented"
else
    fail "T-POS-3: substantive classification line missing" "expected 'Outcome: substantive (logic edits)' literal in template"
fi

# T-POS-4: rationale clarifying no-op is NOT failure (regex tolerates backticks / bold around tokens)
if grep -qiE "no.?op[^a-z]+.*not[^a-z]+.*failure|not[^a-z]+.*failure[^a-z]+.*no.?op" "$TEMPLATE_FILE"; then
    pass "T-POS-4: no-op-is-not-failure rationale documented"
else
    fail "T-POS-4: no-op-is-not-failure rationale missing" "expected language clarifying that no-op is positive evidence, not failure"
fi

# T-NEG-1: placeholders preserved
for placeholder in "{{FINALIZE_SUMMARY_FILE}}" "{{PLAN_FILE}}" "{{GOAL_TRACKER_FILE}}" "{{BASE_BRANCH}}" "{{START_BRANCH}}"; do
    if grep -qF "$placeholder" "$TEMPLATE_FILE"; then
        pass "T-NEG-1: placeholder $placeholder preserved"
    else
        fail "T-NEG-1: placeholder $placeholder missing" "template must keep all existing placeholders"
    fi
done

echo ""
echo "Total: $TESTS_PASSED passed, $TESTS_FAILED failed"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
