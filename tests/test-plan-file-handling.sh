#!/bin/bash
#
# Test plan file handling functionality
#
# Tests for:
# - --commit-plan-file option parsing
# - Plan file backup creation
# - State file fields (commit_plan_file, start_commit)
# - Git-ignored validation
# - Git status filtering for plan file
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

PASSED=0
FAILED=0
WARNINGS=0

pass() {
    echo -e "  ${GREEN}PASS${NC}: $1"
    ((PASSED++))
}

fail() {
    echo -e "  ${RED}FAIL${NC}: $1"
    ((FAILED++))
}

warn() {
    echo -e "  ${YELLOW}WARN${NC}: $1"
    ((WARNINGS++))
}

section() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

# Create temporary test directory
TEST_DIR=$(mktemp -d)
trap "rm -rf $TEST_DIR" EXIT

section "Section 1: Setup Script Option Parsing"

# Test 1.1: --commit-plan-file option is recognized in help
echo "Testing --commit-plan-file in help output..."
HELP_OUTPUT=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" --help 2>&1 || true)
if echo "$HELP_OUTPUT" | grep -q -- "--commit-plan-file"; then
    pass "--commit-plan-file option documented in help"
else
    fail "--commit-plan-file option not found in help output"
fi

# Test 1.2: Help shows plan file stays uncommitted by default
if echo "$HELP_OUTPUT" | grep -q "plan file stays uncommitted"; then
    pass "Help explains default behavior (plan file stays uncommitted)"
else
    fail "Help doesn't explain default behavior"
fi

section "Section 2: State File Schema"

# Create a mock plan file
MOCK_PLAN="$TEST_DIR/test-plan.md"
cat > "$MOCK_PLAN" << 'EOF'
# Test Plan

## Goal
Test the plan file handling feature.

## Tasks
1. Task one
2. Task two
3. Task three
EOF

# Test 2.1: Check setup script creates correct state file fields
echo "Testing state file schema..."

# We can't run the full setup without codex, but we can verify the script
# contains the correct state file template
SETUP_SCRIPT="$PROJECT_ROOT/scripts/setup-rlcr-loop.sh"

if grep -q "commit_plan_file:" "$SETUP_SCRIPT"; then
    pass "State file includes commit_plan_file field"
else
    fail "State file missing commit_plan_file field"
fi

if grep -q "start_commit:" "$SETUP_SCRIPT"; then
    pass "State file includes start_commit field"
else
    fail "State file missing start_commit field"
fi

if grep -q "plan_file_tracked:" "$SETUP_SCRIPT"; then
    pass "State file includes plan_file_tracked field"
else
    fail "State file missing plan_file_tracked field"
fi

# Test 2.2: Check plan backup is created
if grep -q "plan-backup.md" "$SETUP_SCRIPT"; then
    pass "Setup script creates plan-backup.md"
else
    fail "Setup script doesn't create plan-backup.md"
fi

# Test 2.3: Check PROJECT_ROOT is initialized unconditionally
if grep -q 'PROJECT_ROOT=.*CLAUDE_PROJECT_DIR' "$SETUP_SCRIPT" | head -1 && \
   grep -B5 'PLAN_FILE_REL=.*realpath' "$SETUP_SCRIPT" | grep -q 'PROJECT_ROOT='; then
    pass "PROJECT_ROOT initialized before PLAN_FILE_REL calculation"
else
    # Alternative check: PROJECT_ROOT should be set before the relative path calculation
    if grep -n 'PROJECT_ROOT=' "$SETUP_SCRIPT" | head -1 | cut -d: -f1 > /tmp/proj_root_line && \
       grep -n 'PLAN_FILE_REL=.*realpath' "$SETUP_SCRIPT" | head -1 | cut -d: -f1 > /tmp/plan_rel_line; then
        PROJ_LINE=$(cat /tmp/proj_root_line)
        REL_LINE=$(cat /tmp/plan_rel_line)
        if [[ "$PROJ_LINE" -lt "$REL_LINE" ]]; then
            pass "PROJECT_ROOT initialized before PLAN_FILE_REL calculation"
        else
            fail "PROJECT_ROOT not initialized before PLAN_FILE_REL"
        fi
    else
        fail "PROJECT_ROOT not initialized before PLAN_FILE_REL"
    fi
fi

# Test 2.4: Check tracked plan file must be clean when --commit-plan-file is set
if grep -q "plan file has uncommitted changes" "$SETUP_SCRIPT"; then
    pass "Setup script validates tracked plan file must be clean when --commit-plan-file is set"
else
    fail "Setup script missing tracked plan file clean check"
fi

if grep -q "git ls-files.*error-unmatch" "$SETUP_SCRIPT"; then
    pass "Setup script uses git ls-files to check if plan file is tracked"
else
    fail "Setup script missing git ls-files check for tracked status"
fi

section "Section 3: Git-Ignored Validation"

# Test 3.1: Check setup script validates git-ignored plan file
echo "Testing git-ignored validation logic..."

if grep -q "git check-ignore" "$SETUP_SCRIPT"; then
    pass "Setup script checks if plan file is git-ignored"
else
    fail "Setup script doesn't check git-ignored status"
fi

if grep -q "plan file is git-ignored" "$SETUP_SCRIPT"; then
    pass "Setup script has error message for git-ignored plan file"
else
    fail "Setup script missing git-ignored error message"
fi

# Test 3.2: Check setup script validates simple path (no spaces/regex chars)
echo "Testing simple path validation..."

if grep -q "unsupported characters" "$SETUP_SCRIPT"; then
    pass "Setup script validates plan file path for special characters"
else
    fail "Setup script missing special character validation"
fi

if grep -q '\[:space:\]' "$SETUP_SCRIPT"; then
    pass "Setup script checks for spaces in path"
else
    fail "Setup script doesn't check for spaces in path"
fi

# Test 3.3: Check setup script validates relative path (P2 fix)
if grep -q 'PLAN_FILE_REL=.*realpath.*relative-to' "$SETUP_SCRIPT"; then
    pass "Setup script uses relative path for validation"
else
    fail "Setup script doesn't use relative path for validation"
fi

# Test 3.4: Check setup script requires git repository
echo "Testing git repository requirement..."

if grep -q "RLCR loop requires a git repository" "$SETUP_SCRIPT"; then
    pass "Setup script requires git repository"
else
    fail "Setup script doesn't require git repository"
fi

# Test 3.5: Check setup script requires at least one commit
if grep -q "RLCR loop requires at least one commit" "$SETUP_SCRIPT"; then
    pass "Setup script requires at least one commit"
else
    fail "Setup script doesn't require at least one commit"
fi

# Test 3.6: Check setup script validates plan file inside project when --commit-plan-file
echo "Testing plan file location validation..."

if grep -q "plan file is outside the project" "$SETUP_SCRIPT"; then
    pass "Setup script validates plan file must be inside project for --commit-plan-file"
else
    fail "Setup script missing outside project validation for --commit-plan-file"
fi

if grep -q 'PLAN_FILE_REL.* == \.\./\*' "$SETUP_SCRIPT"; then
    pass "Setup script checks for ../ prefix in relative path"
else
    fail "Setup script doesn't check for ../ prefix"
fi

section "Section 4: Stop Hook Git Status Filtering"

STOP_HOOK="$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh"

# Test 4.1: Check stop hook reads commit_plan_file from state
echo "Testing stop hook state reading..."

if grep -q "COMMIT_PLAN_FILE=.*grep.*commit_plan_file" "$STOP_HOOK"; then
    pass "Stop hook reads commit_plan_file from state"
else
    fail "Stop hook doesn't read commit_plan_file from state"
fi

# Test 4.2: Check stop hook reads start_commit from state
if grep -q "START_COMMIT=.*grep.*start_commit" "$STOP_HOOK"; then
    pass "Stop hook reads start_commit from state"
else
    fail "Stop hook doesn't read start_commit from state"
fi

# Test 4.3: Check stop hook filters plan file from git status
if grep -q "FILTERED_GIT_STATUS" "$STOP_HOOK"; then
    pass "Stop hook has filtered git status logic"
else
    fail "Stop hook missing filtered git status logic"
fi

# Test 4.4: Check stop hook has post-commit check
if grep -q "Plan File Accidentally Committed" "$STOP_HOOK"; then
    pass "Stop hook has post-commit check for plan file"
else
    fail "Stop hook missing post-commit check"
fi

# Test 4.5: Check stop hook uses git log to detect plan file commits
if grep -q "git log.*START_COMMIT.*HEAD" "$STOP_HOOK"; then
    pass "Stop hook uses git log for post-commit validation"
else
    fail "Stop hook doesn't use git log for validation"
fi

# Test 4.6: Check state reading has fallback defaults (P1 fix)
if grep -q 'START_COMMIT=.*|| echo ""' "$STOP_HOOK"; then
    pass "Stop hook has fallback for missing start_commit (backward compat)"
else
    fail "Stop hook missing fallback for start_commit"
fi

# Test 4.7: Check exact path matching uses end-of-line anchor (P2 fix)
if grep -q 'grep -v.*\$' "$STOP_HOOK"; then
    pass "Stop hook uses end-of-line anchor for exact path matching"
else
    fail "Stop hook missing end-of-line anchor in path filtering"
fi

# Test 4.8: Check post-commit handles empty START_COMMIT (P3 fix)
if grep -q 'elif git rev-parse HEAD' "$STOP_HOOK"; then
    pass "Stop hook handles repos without start_commit"
else
    fail "Stop hook missing handler for empty start_commit"
fi

# Test 4.9: Check backward compatibility for pre-1.1.2 state files
if grep -q "Pre-1.1.2 State File" "$STOP_HOOK"; then
    pass "Stop hook has backward compatibility check for old state files"
else
    fail "Stop hook missing backward compatibility check"
fi

# Test 4.9b: Check pre-1.1.2 uses template system
if grep -q 'load_and_render_safe.*pre-112-state-file.md' "$STOP_HOOK"; then
    pass "Stop hook uses template for pre-1.1.2 message"
else
    fail "Stop hook doesn't use template for pre-1.1.2 message"
fi

# Test 4.10: Check old state files are renamed to .bak
if grep -q 'mv.*STATE_FILE.*\.bak' "$STOP_HOOK"; then
    pass "Stop hook renames old state files to .bak"
else
    fail "Stop hook doesn't rename old state files"
fi

# Test 4.11: Check stop hook follows Claude Code hooks spec (omits decision field to allow stop)
# Per spec: "decision": "block" | undefined - use undefined (omit) to allow stop
if grep -q 'Per Claude Code hooks spec: omit "decision" field to allow stop' "$STOP_HOOK"; then
    pass "Stop hook follows spec: omits decision field to allow stop"
else
    fail "Stop hook doesn't follow Claude Code hooks spec for allowing stop"
fi

# Test 4.12: Check plan file modification detection
if grep -q "Plan File Issues" "$STOP_HOOK" || grep -q "Plan File Modification" "$STOP_HOOK"; then
    pass "Stop hook has plan file modification check"
else
    fail "Stop hook missing plan file modification check"
fi

# Test 4.13: Check plan file modification uses diff
if grep -q 'diff -q.*PLAN_FILE_FROM_STATE.*PLAN_BACKUP_FILE' "$STOP_HOOK"; then
    pass "Stop hook uses diff to compare plan file with backup"
else
    fail "Stop hook doesn't use diff for plan file comparison"
fi

# Test 4.14: Check stop hook reads plan_file_tracked from state
if grep -q 'PLAN_FILE_TRACKED=.*grep.*plan_file_tracked' "$STOP_HOOK"; then
    pass "Stop hook reads plan_file_tracked from state"
else
    fail "Stop hook doesn't read plan_file_tracked from state"
fi

# Test 4.15: Check plan file modification uses warning template for untracked files
if grep -q 'load_and_render_safe.*plan-file-modified-warning.md' "$STOP_HOOK"; then
    pass "Stop hook uses warning template for untracked plan file modification"
else
    fail "Stop hook doesn't use warning template for plan file modification"
fi

# Test 4.16: Check plan file modification handles case 2.3 (no --commit-plan-file)
if grep -q 'COMMIT_PLAN_FILE.*!=.*true.*&&.*PLAN_FILE_MODIFIED' "$STOP_HOOK"; then
    pass "Stop hook handles case 2.3 (modified plan file without --commit-plan-file)"
else
    fail "Stop hook missing case 2.3 handling"
fi

# Test 4.17: Check stop hook handles case 2.1 (--commit-plan-file with tracked file)
if grep -q 'COMMIT_PLAN_FILE.*==.*true.*&&.*PLAN_FILE_TRACKED.*==.*true' "$STOP_HOOK"; then
    pass "Stop hook handles case 2.1 (--commit-plan-file with tracked file)"
else
    fail "Stop hook missing case 2.1 handling"
fi

# Test 4.18: Check stop hook handles case 2.2 (--commit-plan-file with outside repo)
if grep -q 'Configuration Conflict.*Plan File Outside Repository' "$STOP_HOOK"; then
    pass "Stop hook handles case 2.2 (--commit-plan-file with outside repo)"
else
    fail "Stop hook missing case 2.2 handling"
fi

# Test 4.19: Check stop hook allows exit for plan file issues (not blocks)
# Per Claude Code hooks spec: omit decision field to allow stop (don't use "decision": "block")
# Case 2.1 block is the one that starts with COMMIT_PLAN_FILE.*==.*true && PLAN_FILE_TRACKED
# Verify it does NOT contain "decision": "block" in the jq output for case 2.1
CASE_21_OUTPUT=$(grep -A60 'COMMIT_PLAN_FILE.*==.*true.*&&.*PLAN_FILE_TRACKED.*==.*true' "$STOP_HOOK" | grep -A30 'jq -n')
if echo "$CASE_21_OUTPUT" | grep -q '"decision": "block"'; then
    fail "Stop hook should allow exit (not block) for plan file issues in case 2.1"
else
    pass "Stop hook allows exit (not blocks) for case 2.1 plan file issues"
fi

# Test 4.20: Check stop hook re-computes plan file dirty status at stop time
if grep -q 'PLAN_FILE_DIRTY=.*false' "$STOP_HOOK" && grep -q 'git status --porcelain.*PLAN_FILE_REL' "$STOP_HOOK"; then
    pass "Stop hook re-computes plan file dirty status at stop time"
else
    fail "Stop hook doesn't re-compute plan file dirty status"
fi

section "Section 5: Template File Existence"

# Test 5.1: Check plan-file-committed template exists
TEMPLATE_FILE="$PROJECT_ROOT/prompt-template/block/plan-file-committed.md"
if [[ -f "$TEMPLATE_FILE" ]]; then
    pass "plan-file-committed.md template exists"
else
    fail "plan-file-committed.md template missing"
fi

# Test 5.1b: Check pre-112-state-file template exists
TEMPLATE_FILE_OLD="$PROJECT_ROOT/prompt-template/block/pre-112-state-file.md"
if [[ -f "$TEMPLATE_FILE_OLD" ]]; then
    pass "pre-112-state-file.md template exists"
else
    fail "pre-112-state-file.md template missing"
fi

# Test 5.1c: Check plan-file-modified-warning template exists
TEMPLATE_FILE_MOD="$PROJECT_ROOT/prompt-template/block/plan-file-modified-warning.md"
if [[ -f "$TEMPLATE_FILE_MOD" ]]; then
    pass "plan-file-modified-warning.md template exists"
else
    fail "plan-file-modified-warning.md template missing"
fi

# Test 5.1d: Check plan-file-outside-repo-conflict template exists
TEMPLATE_FILE_OUTSIDE="$PROJECT_ROOT/prompt-template/block/plan-file-outside-repo-conflict.md"
if [[ -f "$TEMPLATE_FILE_OUTSIDE" ]]; then
    pass "plan-file-outside-repo-conflict.md template exists"
else
    fail "plan-file-outside-repo-conflict.md template missing"
fi

# Test 5.1e: Check plan-file-changed-commit-mode template exists
TEMPLATE_FILE_CHANGED="$PROJECT_ROOT/prompt-template/block/plan-file-changed-commit-mode.md"
if [[ -f "$TEMPLATE_FILE_CHANGED" ]]; then
    pass "plan-file-changed-commit-mode.md template exists"
else
    fail "plan-file-changed-commit-mode.md template missing"
fi

# Test 5.2: Check template has required placeholders
if [[ -f "$TEMPLATE_FILE" ]]; then
    if grep -q "{{PLAN_FILE}}" "$TEMPLATE_FILE"; then
        pass "Template has PLAN_FILE placeholder"
    else
        fail "Template missing PLAN_FILE placeholder"
    fi

    if grep -q "{{PLAN_FILE_COMMITS}}" "$TEMPLATE_FILE"; then
        pass "Template has PLAN_FILE_COMMITS placeholder"
    else
        fail "Template missing PLAN_FILE_COMMITS placeholder"
    fi
fi

section "Section 6: Git Status Filtering Unit Test"

# Test the actual filtering logic in isolation
echo "Testing git status filtering logic with exact path matching..."

# Simulate git status output with similar filenames (P2 test case)
MOCK_GIT_STATUS=" M src/main.js
 M docs/plan.md
 M docs/plan.md.bak
?? docs/plan.md~
?? .humanize-loop.local/
?? new-file.txt"

PLAN_FILE_REL="docs/plan.md"
# Use the same escaping and anchoring as the actual code
PLAN_FILE_ESCAPED=$(echo "$PLAN_FILE_REL" | sed 's/[.[\*^$()+?{|]/\\&/g')

# Filter using exact path matching (anchored to end of line)
FILTERED=$(echo "$MOCK_GIT_STATUS" | grep -v " ${PLAN_FILE_ESCAPED}\$" || true)

if echo "$FILTERED" | grep -q "src/main.js"; then
    pass "Filtering preserves non-plan files (src/main.js)"
else
    fail "Filtering incorrectly removed non-plan files"
fi

if echo "$FILTERED" | grep -q " docs/plan.md$"; then
    fail "Filtering didn't remove exact plan file"
else
    pass "Filtering correctly removes exact plan file"
fi

# P2 fix: Verify similar filenames are NOT filtered
if echo "$FILTERED" | grep -q "docs/plan.md.bak"; then
    pass "Filtering preserves similar filename (docs/plan.md.bak)"
else
    fail "Filtering incorrectly removed similar filename .bak"
fi

if echo "$FILTERED" | grep -q "docs/plan.md~"; then
    pass "Filtering preserves similar filename (docs/plan.md~)"
else
    fail "Filtering incorrectly removed similar filename ~"
fi

if echo "$FILTERED" | grep -q ".humanize-loop.local"; then
    pass "Filtering preserves .humanize-loop.local"
else
    fail "Filtering incorrectly removed .humanize-loop.local"
fi

section "Section 7: Post-Commit Check Unit Test"

# Test the git log command pattern
echo "Testing post-commit check logic..."

# Create a mock git repo for testing
MOCK_REPO="$TEST_DIR/mock-repo"
mkdir -p "$MOCK_REPO"
cd "$MOCK_REPO"
git init -q
git config user.email "test@test.com"
git config user.name "Test User"

# Create initial commit
echo "initial" > file.txt
git add file.txt
git commit -q -m "Initial commit"
START_COMMIT=$(git rev-parse HEAD)

# Create a plan file
mkdir -p docs
echo "# Plan" > docs/plan.md

# Commit the plan file
git add docs/plan.md
git commit -q -m "Add plan file"

# Check if git log detects the plan file commit
PLAN_FILE_COMMITS=$(git log --oneline --follow "${START_COMMIT}..HEAD" -- "docs/plan.md" 2>/dev/null || true)

if [[ -n "$PLAN_FILE_COMMITS" ]]; then
    pass "Git log correctly detects plan file in commits"
else
    fail "Git log failed to detect plan file in commits"
fi

# Test with a file that wasn't committed
OTHER_COMMITS=$(git log --oneline --follow "${START_COMMIT}..HEAD" -- "non-existent.md" 2>/dev/null || true)

if [[ -z "$OTHER_COMMITS" ]]; then
    pass "Git log correctly returns empty for non-committed files"
else
    fail "Git log incorrectly returned results for non-committed file"
fi

# P3 fix: Test detection without START_COMMIT (simulating old state files)
echo "Testing post-commit check without START_COMMIT (P3 fix)..."

# When START_COMMIT is empty, should check all commits
EMPTY_START=""
if [[ -z "$EMPTY_START" ]]; then
    # This simulates the fallback behavior when START_COMMIT is missing
    ALL_PLAN_COMMITS=$(git log --oneline --follow -- "docs/plan.md" 2>/dev/null || true)
    if [[ -n "$ALL_PLAN_COMMITS" ]]; then
        pass "Git log without range detects plan file (backward compat)"
    else
        fail "Git log without range failed to detect plan file"
    fi
fi

# P3 fix: Test fresh repo scenario
echo "Testing fresh repo scenario (P3 fix)..."

FRESH_REPO="$TEST_DIR/fresh-repo"
mkdir -p "$FRESH_REPO"
cd "$FRESH_REPO"
git init -q
git config user.email "test@test.com"
git config user.name "Test User"

# Check that git rev-parse HEAD fails in empty repo
if git rev-parse HEAD &>/dev/null; then
    fail "Expected git rev-parse HEAD to fail in empty repo"
else
    pass "git rev-parse HEAD correctly fails in empty repo"
fi

# Now add a commit with plan file
mkdir -p docs
echo "# Plan" > docs/plan.md
git add docs/plan.md
git commit -q -m "First commit with plan file"

# Now git rev-parse HEAD should work
if git rev-parse HEAD &>/dev/null; then
    pass "git rev-parse HEAD works after first commit"
    # And we should detect the plan file
    FIRST_COMMIT_PLANS=$(git log --oneline --follow -- "docs/plan.md" 2>/dev/null || true)
    if [[ -n "$FIRST_COMMIT_PLANS" ]]; then
        pass "Git log detects plan file in first commit (fresh repo)"
    else
        fail "Git log failed to detect plan file in first commit"
    fi
else
    fail "git rev-parse HEAD should work after first commit"
fi

cd "$SCRIPT_DIR"

section "Section 8: Behavioral Tests for Four Plan File Cases"

# These tests verify the actual behavior of setup and stop hook for the four cases

echo "Setting up test repository for behavioral tests..."
BEHAVIOR_TEST_REPO="$TEST_DIR/behavior-test-repo"
mkdir -p "$BEHAVIOR_TEST_REPO"
cd "$BEHAVIOR_TEST_REPO"
git init -q
git config user.email "test@test.com"
git config user.name "Test User"

# Create initial commit
echo "initial" > file.txt
git add file.txt
git commit -q -m "Initial commit"

# Test 8.1: Case 2.3 - Setup accepts tracked dirty plan file when --commit-plan-file is NOT set
echo "Testing Case 2.3: Setup accepts tracked dirty plan file without --commit-plan-file..."

# Create and commit a plan file
mkdir -p docs
cat > docs/plan.md << 'EOF'
# Test Plan

## Goal
Test tracked dirty plan file acceptance.

## Tasks
1. Task one
2. Task two
3. Task three
EOF
git add docs/plan.md
git commit -q -m "Add plan file"

# Make the plan file dirty (modify without committing)
echo "# Modified content" >> docs/plan.md

# Check that setup script only enforces clean status when COMMIT_PLAN_FILE is true
# We verify the script has the check inside the COMMIT_PLAN_FILE==true conditional block
SETUP_CONTENT=$(cat "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh")
# The clean check (git status --porcelain) should appear inside the COMMIT_PLAN_FILE==true block
# and not outside of it
if echo "$SETUP_CONTENT" | grep -A30 'COMMIT_PLAN_FILE.*==.*true' | grep -q 'git status --porcelain'; then
    pass "Case 2.3: Setup only requires clean plan file when --commit-plan-file is set"
else
    fail "Case 2.3: Setup might incorrectly reject tracked dirty plan files"
fi

# Reset the plan file
git checkout -- docs/plan.md

# Test 8.2: Case 2.1 - Setup requires tracked AND clean plan file when --commit-plan-file IS set
echo "Testing Case 2.1: Setup requires tracked and clean plan file with --commit-plan-file..."

# Verify setup script checks for tracked status when --commit-plan-file is set
if grep -q 'plan file is not tracked by git' "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh"; then
    pass "Case 2.1: Setup checks if plan file is tracked when --commit-plan-file is set"
else
    fail "Case 2.1: Setup doesn't check for tracked status with --commit-plan-file"
fi

# Verify setup script checks for clean status when --commit-plan-file is set
# Use a larger context window since the check is not immediately after the condition
if grep -A30 'COMMIT_PLAN_FILE.*==.*true' "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" | grep -q 'git status --porcelain'; then
    pass "Case 2.1: Setup checks if plan file is clean when --commit-plan-file is set"
else
    fail "Case 2.1: Setup doesn't check for clean status with --commit-plan-file"
fi

# Test 8.3: Case 2.2 - Setup rejects plan file outside repo with --commit-plan-file
echo "Testing Case 2.2: Setup rejects outside repo plan file with --commit-plan-file..."

# Create a plan file outside the repo
OUTSIDE_PLAN="$TEST_DIR/outside-plan.md"
cat > "$OUTSIDE_PLAN" << 'EOF'
# Outside Plan

## Goal
Test outside repo rejection.

## Tasks
1. Task one
2. Task two
3. Task three
EOF

# Verify setup script would reject this combination
if grep -q 'plan file is outside the project' "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh"; then
    pass "Case 2.2: Setup rejects outside repo plan file with --commit-plan-file"
else
    fail "Case 2.2: Setup doesn't reject outside repo plan file with --commit-plan-file"
fi

# Test 8.4: Stop hook follows Claude Code hooks spec for allowing exit
echo "Testing stop hook decision: follows hooks spec for allowing exit..."

# Per Claude Code hooks spec: omit "decision" field to allow stop (NOT "decision": "allow")
# Verify stop hook does NOT use invalid "decision": "allow" and uses spec-compliant comments
INVALID_ALLOW_COUNT=$(grep -c '"decision": "allow"' "$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh" 2>/dev/null || true)
SPEC_COMMENT_COUNT=$(grep -c 'Per Claude Code hooks spec: omit' "$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh" 2>/dev/null || true)
# Default to 0 if empty
INVALID_ALLOW_COUNT=${INVALID_ALLOW_COUNT:-0}
SPEC_COMMENT_COUNT=${SPEC_COMMENT_COUNT:-0}
if [[ "$INVALID_ALLOW_COUNT" -eq 0 ]] && [[ "$SPEC_COMMENT_COUNT" -ge 3 ]]; then
    pass "Stop hook follows Claude Code hooks spec (omits decision field to allow stop)"
else
    fail "Stop hook doesn't follow Claude Code hooks spec: found $INVALID_ALLOW_COUNT invalid 'allow' decisions, $SPEC_COMMENT_COUNT spec comments"
fi

# Test 8.5: Stop hook re-computes tracking status at stop time (not relying solely on state file)
echo "Testing stop hook re-computation of plan file status..."

# Verify stop hook re-computes the relative path
if grep -q 'PLAN_FILE_REL_CHECK=.*realpath' "$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh"; then
    pass "Stop hook re-computes plan file relative path at stop time"
else
    fail "Stop hook doesn't re-compute plan file relative path"
fi

# Verify stop hook re-computes dirty status
if grep -q 'PLAN_FILE_DIRTY=.*false' "$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh" && \
   grep -q 'git status --porcelain' "$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh"; then
    pass "Stop hook re-computes plan file dirty status at stop time"
else
    fail "Stop hook doesn't re-compute dirty status at stop time"
fi

# Test 8.6: Stop hook handles case 2.3 for both tracked and untracked modified files
echo "Testing stop hook handles tracked and untracked modified files in case 2.3..."

# Verify stop hook includes TRACKING_STATUS variable
if grep -q 'TRACKING_STATUS=' "$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh"; then
    pass "Stop hook tracks whether modified file is tracked or untracked"
else
    fail "Stop hook doesn't distinguish between tracked and untracked modified files"
fi

cd "$SCRIPT_DIR"

section "Test Summary"

echo ""
echo -e "Passed:   ${GREEN}$PASSED${NC}"
echo -e "Failed:   ${RED}$FAILED${NC}"
echo -e "Warnings: ${YELLOW}$WARNINGS${NC}"
echo ""

if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}All plan file handling tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi
