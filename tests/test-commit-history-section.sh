#!/usr/bin/env bash
#
# Test script for the Integral (I) component: commit-history-section
#
# Validates:
# 1. Round 0: "(no commits yet)" and "(first round, no prior history)"
# 2. Round 2+: commit log and round file references rendered correctly
# 3. Corrupted BASE_COMMIT: graceful fallback with annotation
# 4. Template missing: fallback renders the full section including round files
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"
source "$PROJECT_ROOT/hooks/lib/template-loader.sh"

TEMPLATE_DIR="$PROJECT_ROOT/prompt-template"

echo "========================================"
echo "Testing commit-history-section (I component)"
echo "========================================"
echo ""

# ========================================
# Setup: create a temporary git repo
# ========================================
setup_test_dir
init_test_git_repo "$TEST_DIR/repo"

# ========================================
# Test 1: Round 0 - no commits since base, first round
# ========================================
echo "Test 1: Round 0 - no commits, first round"

CURRENT_ROUND=0
BASE_COMMIT=$(git -C "$TEST_DIR/repo" rev-parse HEAD)

# No commits since BASE_COMMIT..HEAD (same commit)
COMMIT_HISTORY=$(git -C "$TEST_DIR/repo" log --oneline --no-decorate --reverse "$BASE_COMMIT"..HEAD 2>/dev/null | tail -80)
[[ -z "$COMMIT_HISTORY" ]] && COMMIT_HISTORY="(no commits yet)"

RECENT_ROUND_FILES=""
LOOP_TIMESTAMP="2026-01-01_00-00-00"
for (( r = CURRENT_ROUND - 1; r >= 0 && r >= CURRENT_ROUND - 3; r-- )); do
    RECENT_ROUND_FILES+="- @.humanize/rlcr/${LOOP_TIMESTAMP}/round-${r}-summary.md
- @.humanize/rlcr/${LOOP_TIMESTAMP}/round-${r}-review-result.md
"
done
[[ -z "$RECENT_ROUND_FILES" ]] && RECENT_ROUND_FILES="(first round, no prior history)"

RESULT=$(load_and_render_safe "$TEMPLATE_DIR" "codex/commit-history-section.md" "FALLBACK" \
    "COMMIT_HISTORY=$COMMIT_HISTORY" \
    "RECENT_ROUND_FILES=$RECENT_ROUND_FILES")

if echo "$RESULT" | grep -q "(no commits yet)" && echo "$RESULT" | grep -q "(first round, no prior history)"; then
    pass "Round 0 shows correct placeholders"
else
    fail "Round 0 placeholders" "(no commits yet) and (first round, no prior history)" "$RESULT"
fi

# ========================================
# Test 2: Round 3 - with commits and round history
# ========================================
echo ""
echo "Test 2: Round 3 - commits and round file references"

# Make some commits
cd "$TEST_DIR/repo"
echo "feat1" > feat1.txt && git add feat1.txt && git commit -q -m "feat: add feature 1"
echo "feat2" > feat2.txt && git add feat2.txt && git commit -q -m "feat: add feature 2"
echo "fix1" > fix1.txt && git add fix1.txt && git commit -q -m "fix: resolve bug in feature 1"
cd - > /dev/null

CURRENT_ROUND=3
COMMIT_HISTORY=$(git -C "$TEST_DIR/repo" log --oneline --no-decorate --reverse "$BASE_COMMIT"..HEAD 2>/dev/null | tail -80)
[[ -z "$COMMIT_HISTORY" ]] && COMMIT_HISTORY="(no commits yet)"

RECENT_ROUND_FILES=""
for (( r = CURRENT_ROUND - 1; r >= 0 && r >= CURRENT_ROUND - 3; r-- )); do
    RECENT_ROUND_FILES+="- @.humanize/rlcr/${LOOP_TIMESTAMP}/round-${r}-summary.md
- @.humanize/rlcr/${LOOP_TIMESTAMP}/round-${r}-review-result.md
"
done
[[ -z "$RECENT_ROUND_FILES" ]] && RECENT_ROUND_FILES="(first round, no prior history)"

RESULT=$(load_and_render_safe "$TEMPLATE_DIR" "codex/commit-history-section.md" "FALLBACK" \
    "COMMIT_HISTORY=$COMMIT_HISTORY" \
    "RECENT_ROUND_FILES=$RECENT_ROUND_FILES")

HAS_COMMITS=true
HAS_ROUNDS=true

echo "$RESULT" | grep -q "feat: add feature 1" || HAS_COMMITS=false
echo "$RESULT" | grep -q "feat: add feature 2" || HAS_COMMITS=false
echo "$RESULT" | grep -q "fix: resolve bug in feature 1" || HAS_COMMITS=false

echo "$RESULT" | grep -q "round-2-summary.md" || HAS_ROUNDS=false
echo "$RESULT" | grep -q "round-1-summary.md" || HAS_ROUNDS=false
echo "$RESULT" | grep -q "round-0-summary.md" || HAS_ROUNDS=false
echo "$RESULT" | grep -q "round-2-review-result.md" || HAS_ROUNDS=false

if [[ "$HAS_COMMITS" == "true" ]]; then
    pass "Round 3 shows all 3 commits"
else
    fail "Round 3 commits" "3 commit messages" "$RESULT"
fi

if [[ "$HAS_ROUNDS" == "true" ]]; then
    pass "Round 3 shows round 0-2 file references"
else
    fail "Round 3 round files" "round-0/1/2 summary and review files" "$RESULT"
fi

# ========================================
# Test 3: Corrupted BASE_COMMIT - nonexistent object
# ========================================
echo ""
echo "Test 3: Corrupted BASE_COMMIT graceful fallback"

BAD_COMMIT="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"

# Simulate the exact logic from the stop hook (merge-base --is-ancestor)
if [[ -n "$BAD_COMMIT" ]] && git -C "$TEST_DIR/repo" merge-base --is-ancestor "$BAD_COMMIT" HEAD 2>/dev/null; then
    COMMIT_HISTORY=$(git -C "$TEST_DIR/repo" log --oneline --no-decorate --reverse "$BAD_COMMIT"..HEAD 2>/dev/null | tail -80)
else
    COMMIT_HISTORY=$(git -C "$TEST_DIR/repo" log --oneline --no-decorate --reverse -30 2>/dev/null)
    [[ -n "$COMMIT_HISTORY" ]] && COMMIT_HISTORY="(base commit unavailable, showing recent branch commits)
${COMMIT_HISTORY}"
fi
[[ -z "$COMMIT_HISTORY" ]] && COMMIT_HISTORY="(no commits yet)"

if echo "$COMMIT_HISTORY" | grep -q "base commit unavailable"; then
    pass "Corrupted BASE_COMMIT triggers annotation"
else
    fail "Corrupted BASE_COMMIT annotation" "base commit unavailable" "$COMMIT_HISTORY"
fi

if echo "$COMMIT_HISTORY" | grep -q "feat: add feature"; then
    pass "Corrupted BASE_COMMIT still shows recent commits"
else
    fail "Corrupted BASE_COMMIT recent commits" "recent branch commits" "$COMMIT_HISTORY"
fi

# Verify no crash (we got here = no set -e crash)
pass "Corrupted BASE_COMMIT did not crash (set -e safe)"

# ========================================
# Test 3b: Valid but unrelated commit (not ancestor of HEAD)
# ========================================
echo ""
echo "Test 3b: Valid but unrelated BASE_COMMIT (orphan branch)"

# Create an orphan branch with its own commit, then switch back
cd "$TEST_DIR/repo"
ORIG_BRANCH=$(git rev-parse --abbrev-ref HEAD)
git checkout -q --orphan orphan-test
echo "orphan" > orphan.txt && git add orphan.txt && git commit -q -m "orphan commit"
ORPHAN_COMMIT=$(git rev-parse HEAD)
git checkout -q "$ORIG_BRANCH"
cd - > /dev/null

# ORPHAN_COMMIT exists but is NOT an ancestor of HEAD
if [[ -n "$ORPHAN_COMMIT" ]] && git -C "$TEST_DIR/repo" merge-base --is-ancestor "$ORPHAN_COMMIT" HEAD 2>/dev/null; then
    COMMIT_HISTORY="should not reach here"
else
    COMMIT_HISTORY=$(git -C "$TEST_DIR/repo" log --oneline --no-decorate --reverse -30 2>/dev/null)
    [[ -n "$COMMIT_HISTORY" ]] && COMMIT_HISTORY="(base commit unavailable, showing recent branch commits)
${COMMIT_HISTORY}"
fi
[[ -z "$COMMIT_HISTORY" ]] && COMMIT_HISTORY="(no commits yet)"

if echo "$COMMIT_HISTORY" | grep -q "base commit unavailable"; then
    pass "Unrelated valid commit triggers annotation"
else
    fail "Unrelated valid commit annotation" "base commit unavailable" "$COMMIT_HISTORY"
fi

# ========================================
# Test 4: Missing template - fallback renders full section
# ========================================
echo ""
echo "Test 4: Missing template fallback renders full section"

CURRENT_ROUND=2
COMMIT_HISTORY=$(git -C "$TEST_DIR/repo" log --oneline --no-decorate --reverse "$BASE_COMMIT"..HEAD 2>/dev/null | tail -80)

RECENT_ROUND_FILES=""
for (( r = CURRENT_ROUND - 1; r >= 0 && r >= CURRENT_ROUND - 3; r-- )); do
    RECENT_ROUND_FILES+="- @.humanize/rlcr/${LOOP_TIMESTAMP}/round-${r}-summary.md
- @.humanize/rlcr/${LOOP_TIMESTAMP}/round-${r}-review-result.md
"
done

# Use the exact fallback format from the stop hook
COMMIT_HISTORY_SECTION_FALLBACK="## Development History (Integral Context)
\`\`\`
${COMMIT_HISTORY}
\`\`\`
### Recent Round Files
Read these files before conducting your review to understand the trajectory of work:
${RECENT_ROUND_FILES}"

# Point to a non-existent template to force fallback
RESULT=$(load_and_render_safe "$TEMPLATE_DIR" "codex/non-existent-template.md" "$COMMIT_HISTORY_SECTION_FALLBACK" \
    "COMMIT_HISTORY=$COMMIT_HISTORY" \
    "RECENT_ROUND_FILES=$RECENT_ROUND_FILES")

FALLBACK_OK=true
echo "$RESULT" | grep -q "Development History" || FALLBACK_OK=false
echo "$RESULT" | grep -q "feat: add feature 1" || FALLBACK_OK=false
echo "$RESULT" | grep -q "Recent Round Files" || FALLBACK_OK=false
echo "$RESULT" | grep -q "round-1-summary.md" || FALLBACK_OK=false
echo "$RESULT" | grep -q "round-0-review-result.md" || FALLBACK_OK=false
echo "$RESULT" | grep -q "Read these files" || FALLBACK_OK=false

if [[ "$FALLBACK_OK" == "true" ]]; then
    pass "Fallback renders full section with commits, round files, and directive"
else
    fail "Fallback full section" "commits + round files + directive" "$RESULT"
fi

# ========================================
# Test 5: Round 1 - only 1 prior round (boundary)
# ========================================
echo ""
echo "Test 5: Round 1 - only 1 prior round"

CURRENT_ROUND=1
RECENT_ROUND_FILES=""
for (( r = CURRENT_ROUND - 1; r >= 0 && r >= CURRENT_ROUND - 3; r-- )); do
    RECENT_ROUND_FILES+="- @.humanize/rlcr/${LOOP_TIMESTAMP}/round-${r}-summary.md
- @.humanize/rlcr/${LOOP_TIMESTAMP}/round-${r}-review-result.md
"
done
[[ -z "$RECENT_ROUND_FILES" ]] && RECENT_ROUND_FILES="(first round, no prior history)"

if echo "$RECENT_ROUND_FILES" | grep -q "round-0-summary.md" && \
   ! echo "$RECENT_ROUND_FILES" | grep -q "round-1-"; then
    pass "Round 1 references only round 0"
else
    fail "Round 1 boundary" "only round-0 references" "$RECENT_ROUND_FILES"
fi

# ========================================
# Test 6: Empty BASE_COMMIT (legacy loop)
# ========================================
echo ""
echo "Test 6: Empty BASE_COMMIT fallback"

EMPTY_BASE=""
if [[ -n "$EMPTY_BASE" ]] && git -C "$TEST_DIR/repo" merge-base --is-ancestor "$EMPTY_BASE" HEAD 2>/dev/null; then
    COMMIT_HISTORY="should not reach here"
else
    COMMIT_HISTORY=$(git -C "$TEST_DIR/repo" log --oneline --no-decorate --reverse -30 2>/dev/null)
    [[ -n "$COMMIT_HISTORY" ]] && COMMIT_HISTORY="(base commit unavailable, showing recent branch commits)
${COMMIT_HISTORY}"
fi
[[ -z "$COMMIT_HISTORY" ]] && COMMIT_HISTORY="(no commits yet)"

if echo "$COMMIT_HISTORY" | grep -q "base commit unavailable"; then
    pass "Empty BASE_COMMIT triggers annotation"
else
    fail "Empty BASE_COMMIT annotation" "base commit unavailable" "$COMMIT_HISTORY"
fi

# ========================================
# Summary
# ========================================
print_test_summary "Commit History Section (I Component) Tests"
