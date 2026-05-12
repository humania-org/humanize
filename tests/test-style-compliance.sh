#!/usr/bin/env bash
#
# AC-10 style-compliance test (added in Round 5 as task T15;
# expanded in Rounds 6 and 7 to cover the full plan-required scope).
#
# AC-10 forbids the literal substrings "AC-", "Milestone", "Step ",
# "Phase " from appearing in implementation code or comments. Those
# tokens are reserved for plan documentation; using them in code
# makes the codebase carry workflow markers that have no domain
# meaning at runtime.
#
# Scope (post-rebase against upstream/dev):
#   - All .sh and .py files under viz/ (plan-authored code).
#   - scripts/cancel-rlcr-session.sh (new file added by this plan).
#
# The broader scripts/ directory is upstream-owned. Its files
# legitimately reference workflow terms like "AC-1", "Phase",
# "Review Phase" in regex patterns, template content, and user-
# facing strings — those predate this plan and are outside AC-10's
# remit. Same reasoning for commands/ and hooks/.
#
# Excluded:
#   - tests/ themselves (fixtures legitimately contain forbidden
#     literals as expected input).
#   - scripts/* except the plan-authored cancel-rlcr-session.sh.
#   - commands/ and hooks/ (upstream-owned workflow).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "========================================"
echo "AC-10 style compliance (T15 full scope)"
echo "========================================"

PASS_COUNT=0
FAIL_COUNT=0

_pass() { printf '\033[0;32mPASS\033[0m: %s\n' "$1"; PASS_COUNT=$((PASS_COUNT+1)); }
_fail() { printf '\033[0;31mFAIL\033[0m: %s\n' "$1"; FAIL_COUNT=$((FAIL_COUNT+1)); }

# Step 1: every .sh and .py under viz/.
mapfile -t CORE_FILES < <(
    find "$PLUGIN_ROOT/viz" \
        -type f \( -name '*.sh' -o -name '*.py' \) \
        -not -path "*/__pycache__/*" \
        2>/dev/null | sort
)

# Step 2: plan-authored files under scripts/.
PLAN_AUTHORED_SCRIPTS=(
    "$PLUGIN_ROOT/scripts/cancel-rlcr-session.sh"
)
EXTRA_FILES=()
for f in "${PLAN_AUTHORED_SCRIPTS[@]}"; do
    [[ -f "$f" ]] && EXTRA_FILES+=("$f")
done

FILES=("${CORE_FILES[@]}" "${EXTRA_FILES[@]}")

if [[ ${#FILES[@]} -eq 0 ]]; then
    _fail "no plan-scope files found to scan"
    exit 1
fi

n_core=${#CORE_FILES[@]}
n_extra=${#EXTRA_FILES[@]}
echo "Scanning ${#FILES[@]} files (${n_core} under viz/, ${n_extra} plan-authored under scripts/)."

# Per-file findings keyed by pattern, so we report a single PASS or
# FAIL line per pattern with the offending file list.
for pattern in 'AC-' 'Milestone' 'Step ' 'Phase '; do
    label="$pattern"
    found_files=()
    for f in "${FILES[@]}"; do
        if grep -nF "$pattern" "$f" >/dev/null 2>&1; then
            found_files+=("${f#$PLUGIN_ROOT/}")
        fi
    done
    if [[ ${#found_files[@]} -eq 0 ]]; then
        _pass "no '$label' literal across the plan's full AC-10 scope"
    else
        _fail "literal '$label' appears in: ${found_files[*]}"
        for f in "${found_files[@]}"; do
            echo "    --- matches in $f ---"
            grep -nF "$pattern" "$PLUGIN_ROOT/$f" | sed 's/^/      /'
        done
    fi
done

echo
echo "========================================"
printf 'Passed: \033[0;32m%d\033[0m\n' "$PASS_COUNT"
printf 'Failed: \033[0;31m%d\033[0m\n' "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
fi

printf '\033[0;32mAC-10 compliance check passed!\033[0m\n'
