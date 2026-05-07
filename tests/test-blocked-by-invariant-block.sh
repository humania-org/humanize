#!/usr/bin/env bash
#
# Test that the implementer prompt documents the optional
# Blocked By Methodology Invariant block, and the reviewer prompt
# documents how to recognise + route it.
#
# Positive Test Cases:
# - T-POS-1: next-round prompt documents the optional block + format
# - T-POS-2: next-round prompt lists the four required block fields
# - T-POS-3: next-round prompt warns against using block for ordinary follow-up
# - T-POS-4: regular-review prompt instructs reviewer to recognise the block
# - T-POS-5: regular-review prompt instructs reviewer to verify-then-route
# - T-POS-6: regular-review prompt instructs reviewer to push back on misuse
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

NEXT_ROUND="$PROJECT_ROOT/prompt-template/claude/next-round-prompt.md"
REGULAR="$PROJECT_ROOT/prompt-template/codex/regular-review.md"

# T-POS-1: next-round prompt documents the optional block
if grep -qF "## Blocked By Methodology Invariant" "$NEXT_ROUND"; then
    pass "T-POS-1: next-round prompt names the optional block"
else
    fail "T-POS-1: next-round prompt missing block name" "expected literal '## Blocked By Methodology Invariant' heading"
fi

# T-POS-2: four required block fields
for field in "Invariant:" "Findings blocked:" "Canonical resolution:" "Why I cannot act in-loop:"; do
    if grep -qF "$field" "$NEXT_ROUND"; then
        pass "T-POS-2: block field documented: $field"
    else
        fail "T-POS-2: block field missing: $field" "expected literal '$field' in template"
    fi
done

# T-POS-3: misuse warning
if grep -qiE "use this block conservatively|NOT a way to defer|conservatively" "$NEXT_ROUND"; then
    pass "T-POS-3: next-round warns against block misuse"
else
    fail "T-POS-3: misuse warning missing" "expected language warning the implementer not to abuse the block"
fi

# T-POS-4: reviewer recognises the block
if grep -qF "## Blocked By Methodology Invariant" "$REGULAR"; then
    pass "T-POS-4: regular-review references the block"
else
    fail "T-POS-4: regular-review missing block reference" "expected '## Blocked By Methodology Invariant' in template"
fi

# T-POS-5: reviewer verify-then-route language
if grep -qiE "verify the implementer.s claim|confirm the listed findings" "$REGULAR"; then
    pass "T-POS-5: reviewer instructed to verify-then-route"
else
    fail "T-POS-5: verify-then-route guidance missing" "expected verification step in reviewer prompt"
fi

# T-POS-6: push back on misuse
if grep -qiE "push back|wrongly classified|leave them in" "$REGULAR"; then
    pass "T-POS-6: reviewer instructed to push back on misuse"
else
    fail "T-POS-6: push-back guidance missing" "expected explicit push-back language for false-blocked findings"
fi

echo ""
echo "Total: $TESTS_PASSED passed, $TESTS_FAILED failed"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
