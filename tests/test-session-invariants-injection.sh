#!/usr/bin/env bash
#
# Test that the reviewer prompt templates contain the {{SESSION_INVARIANTS}}
# placeholder and the loop-aware out-of-loop finding classification language.
# This is the static side of the change — the dynamic injection is exercised
# via the stop-hook, which is covered by the broader hook integration tests.
#
# Positive Test Cases:
# - T-POS-1: regular-review template contains {{SESSION_INVARIANTS}} placeholder
# - T-POS-2: full-alignment-review template contains {{SESSION_INVARIANTS}} placeholder
# - T-POS-3: regular-review template documents the out-of-loop finding lane
# - T-POS-4: full-alignment-review template documents the out-of-loop finding lane
# - T-POS-5: stop-hook builds SESSION_INVARIANTS from PLAN_TRACKED + START_BRANCH
# - T-POS-6: stop-hook passes SESSION_INVARIANTS into both load_and_render_safe calls
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

REGULAR="$PROJECT_ROOT/prompt-template/codex/regular-review.md"
FULL_ALIGN="$PROJECT_ROOT/prompt-template/codex/full-alignment-review.md"
STOP_HOOK="$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh"

# T-POS-1
if grep -qF "{{SESSION_INVARIANTS}}" "$REGULAR"; then
    pass "T-POS-1: regular-review.md contains SESSION_INVARIANTS placeholder"
else
    fail "T-POS-1: regular-review.md missing SESSION_INVARIANTS placeholder" "expected literal {{SESSION_INVARIANTS}} in template"
fi

# T-POS-2
if grep -qF "{{SESSION_INVARIANTS}}" "$FULL_ALIGN"; then
    pass "T-POS-2: full-alignment-review.md contains SESSION_INVARIANTS placeholder"
else
    fail "T-POS-2: full-alignment-review.md missing SESSION_INVARIANTS placeholder" "expected literal {{SESSION_INVARIANTS}} in template"
fi

# T-POS-3
if grep -qiE "out.of.loop" "$REGULAR" && grep -qiE "tag these .out.of.loop|tag .out.of.loop" "$REGULAR"; then
    pass "T-POS-3: regular-review.md documents out-of-loop finding lane"
else
    fail "T-POS-3: regular-review.md missing out-of-loop guidance" "expected out-of-loop tagging instruction"
fi

# T-POS-4
if grep -qiE "out.of.loop" "$FULL_ALIGN"; then
    pass "T-POS-4: full-alignment-review.md documents out-of-loop finding lane"
else
    fail "T-POS-4: full-alignment-review.md missing out-of-loop guidance" "expected out-of-loop tagging instruction"
fi

# T-POS-5: stop-hook builds the invariants string from existing state vars
if grep -qF 'SESSION_INVARIANTS=""' "$STOP_HOOK" \
   && grep -qE 'PLAN_TRACKED.*==.*"true"' "$STOP_HOOK" \
   && grep -qE 'SESSION_INVARIANTS\+=.*Plan file byte-lock' "$STOP_HOOK" \
   && grep -qE 'SESSION_INVARIANTS\+=.*Working branch fixed' "$STOP_HOOK"; then
    pass "T-POS-5: stop-hook builds SESSION_INVARIANTS from state vars"
else
    fail "T-POS-5: stop-hook does not build SESSION_INVARIANTS as expected" "expected initialization + plan-tracked branch + working-branch line"
fi

# T-POS-6: SESSION_INVARIANTS passed into both render calls
session_inv_count=$(grep -cF "SESSION_INVARIANTS=\$SESSION_INVARIANTS" "$STOP_HOOK" || true)
if [[ "$session_inv_count" -ge 2 ]]; then
    pass "T-POS-6: stop-hook passes SESSION_INVARIANTS to both review-prompt renders ($session_inv_count occurrences)"
else
    fail "T-POS-6: stop-hook missing SESSION_INVARIANTS in load_and_render_safe call(s)" "expected at least 2 occurrences (full-alignment + regular), got $session_inv_count"
fi

echo ""
echo "Total: $TESTS_PASSED passed, $TESTS_FAILED failed"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
