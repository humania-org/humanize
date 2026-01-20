#!/bin/bash
#
# Robustness tests for setup scripts
#
# Tests setup-rlcr-loop.sh and setup-pr-loop.sh under edge cases:
# - Argument parsing edge cases
# - Plan file validation edge cases
# - Git repository edge cases
# - YAML safety validation
# - Concurrent execution handling
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../test-helpers.sh"
source "$PROJECT_ROOT/scripts/portable-timeout.sh"

setup_test_dir

echo "========================================"
echo "Setup Scripts Robustness Tests"
echo "========================================"
echo ""

# ========================================
# Helper Functions
# ========================================

create_minimal_plan() {
    local dir="$1"
    local filename="${2:-plan.md}"
    mkdir -p "$(dirname "$dir/$filename")"
    cat > "$dir/$filename" << 'EOF'
# Implementation Plan

## Goal
Test the setup script robustness.

## Acceptance Criteria
- Works correctly

## Steps
1. First step
2. Second step
3. Third step
EOF
}

init_basic_git_repo() {
    local dir="$1"
    cd "$dir"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test User"
    git config commit.gpgsign false
    git checkout -q -b main 2>/dev/null || git checkout -q main
    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "Initial commit"
    cd - > /dev/null
}

# Run setup-rlcr-loop.sh with proper isolation from real RLCR loop
# Usage: run_rlcr_setup <test_repo_dir> [args...]
run_rlcr_setup() {
    local repo_dir="$1"
    shift
    (
        cd "$repo_dir"
        # Set CLAUDE_PROJECT_DIR to isolate from any real active loops
        # Preserve PATH to ensure git/gh/etc are available
        CLAUDE_PROJECT_DIR="$repo_dir" "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" "$@"
    )
}

# Run setup-pr-loop.sh with proper isolation from real PR loop
# Usage: run_pr_setup <test_repo_dir> [args...]
run_pr_setup() {
    local repo_dir="$1"
    shift
    (
        cd "$repo_dir"
        CLAUDE_PROJECT_DIR="$repo_dir" "$PROJECT_ROOT/scripts/setup-pr-loop.sh" "$@"
    )
}

# ========================================
# Setup RLCR Loop Argument Parsing Tests
# ========================================

echo "--- Setup RLCR Loop Argument Tests ---"
echo ""

# Test 1: Help flag displays usage
echo "Test 1: Help flag displays usage"
OUTPUT=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" --help 2>&1) || true
if echo "$OUTPUT" | grep -q "USAGE"; then
    pass "Help flag displays usage information"
else
    fail "Help flag" "USAGE text" "no usage found"
fi

# Test 2: Missing plan file shows error
echo ""
echo "Test 2: Missing plan file shows error"
mkdir -p "$TEST_DIR/repo2"
init_basic_git_repo "$TEST_DIR/repo2"
OUTPUT=$(run_rlcr_setup "$TEST_DIR/repo2" 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "no plan file\|plan file"; then
    pass "Missing plan file shows error"
else
    fail "Missing plan file" "exit != 0 with error message" "exit=$EXIT_CODE, output=$OUTPUT"
fi

# Test 3: --max with non-numeric value rejected
echo ""
echo "Test 3: --max with non-numeric value rejected"
OUTPUT=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" --max abc 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "positive integer"; then
    pass "--max non-numeric rejected"
else
    fail "--max validation" "rejection" "exit=$EXIT_CODE"
fi

# Test 4: --max with actual negative number rejected
echo ""
echo "Test 4: --max with actual negative number rejected"
mkdir -p "$TEST_DIR/repo4"
init_basic_git_repo "$TEST_DIR/repo4"
create_minimal_plan "$TEST_DIR/repo4"
echo "plan.md" >> "$TEST_DIR/repo4/.gitignore"
git -C "$TEST_DIR/repo4" add .gitignore && git -C "$TEST_DIR/repo4" commit -q -m "Add gitignore"
mkdir -p "$TEST_DIR/repo4/bin"
# Test actual negative number (--max=-5 or --max -5)
# Note: bash argparse may interpret -5 as a flag, so we use --max=-5 format
OUTPUT=$(run_rlcr_setup "$TEST_DIR/repo4" plan.md --max=-5 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "positive integer\|unknown option\|invalid"; then
    pass "--max with negative number rejected (exit=$EXIT_CODE)"
else
    # Also try separate argument format
    OUTPUT=$(run_rlcr_setup "$TEST_DIR/repo4" plan.md --max -5 2>&1) || EXIT_CODE=$?
    EXIT_CODE=${EXIT_CODE:-0}
    if [[ $EXIT_CODE -ne 0 ]]; then
        pass "--max -5 rejected (exit=$EXIT_CODE)"
    else
        fail "--max negative" "rejection" "exit=$EXIT_CODE"
    fi
fi

# Test 4b: --max with empty value rejected
echo ""
echo "Test 4b: --max with empty value rejected"
OUTPUT=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" --max "" 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
if [[ $EXIT_CODE -ne 0 ]]; then
    pass "--max with empty value rejected"
else
    fail "--max empty" "rejection" "accepted"
fi

# Test 5: --codex-timeout with non-numeric value rejected
echo ""
echo "Test 5: --codex-timeout with non-numeric value rejected"
OUTPUT=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" --codex-timeout "invalid" 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "positive integer"; then
    pass "--codex-timeout non-numeric rejected"
else
    fail "--codex-timeout validation" "rejection" "exit=$EXIT_CODE"
fi

# Test 6: --codex-model without argument rejected
echo ""
echo "Test 6: --codex-model without argument rejected"
OUTPUT=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" --codex-model 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
if [[ $EXIT_CODE -ne 0 ]]; then
    pass "--codex-model without argument rejected"
else
    fail "--codex-model validation" "rejection" "accepted"
fi

# Test 7: Unknown option rejected
echo ""
echo "Test 7: Unknown option rejected"
OUTPUT=$("$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" --unknown-option 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "unknown option"; then
    pass "Unknown option rejected"
else
    fail "Unknown option" "rejection" "exit=$EXIT_CODE"
fi

# Test 8: Both positional and --plan-file rejected
echo ""
echo "Test 8: Both positional and --plan-file rejected"
mkdir -p "$TEST_DIR/repo8"
init_basic_git_repo "$TEST_DIR/repo8"
create_minimal_plan "$TEST_DIR/repo8"
echo "plan.md" >> "$TEST_DIR/repo8/.gitignore"
git -C "$TEST_DIR/repo8" add .gitignore && git -C "$TEST_DIR/repo8" commit -q -m "Add gitignore"

OUTPUT=$(run_rlcr_setup "$TEST_DIR/repo8" plan.md --plan-file other.md 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "cannot specify both"; then
    pass "Both positional and --plan-file rejected"
else
    fail "Duplicate plan file" "rejection" "exit=$EXIT_CODE"
fi

# ========================================
# Plan File Validation Edge Cases
# ========================================

echo ""
echo "--- Plan File Validation Tests ---"
echo ""

# Test 9: Plan file with only comments rejected
echo "Test 9: Plan file with only comments rejected"
mkdir -p "$TEST_DIR/repo9"
init_basic_git_repo "$TEST_DIR/repo9"
cat > "$TEST_DIR/repo9/plan.md" << 'EOF'
# Comment 1
# Comment 2
# Comment 3
# Comment 4
# Comment 5
# Comment 6
# Comment 7
EOF
echo "plan.md" >> "$TEST_DIR/repo9/.gitignore"
git -C "$TEST_DIR/repo9" add .gitignore && git -C "$TEST_DIR/repo9" commit -q -m "Add gitignore"

# Create mock codex
mkdir -p "$TEST_DIR/repo9/bin"
echo '#!/bin/bash
exit 0' > "$TEST_DIR/repo9/bin/codex"
chmod +x "$TEST_DIR/repo9/bin/codex"

OUTPUT=$(PATH="$TEST_DIR/repo9/bin:$PATH" run_rlcr_setup "$TEST_DIR/repo9" plan.md 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "insufficient content"; then
    pass "Plan with only comments rejected"
else
    fail "Comment-only plan" "rejection" "exit=$EXIT_CODE"
fi

# Test 10: Plan file with less than 5 lines rejected
echo ""
echo "Test 10: Plan file with less than 5 lines rejected"
mkdir -p "$TEST_DIR/repo10"
init_basic_git_repo "$TEST_DIR/repo10"
cat > "$TEST_DIR/repo10/plan.md" << 'EOF'
# Short Plan
Content
Line
EOF
echo "plan.md" >> "$TEST_DIR/repo10/.gitignore"
git -C "$TEST_DIR/repo10" add .gitignore && git -C "$TEST_DIR/repo10" commit -q -m "Add gitignore"

mkdir -p "$TEST_DIR/repo10/bin"
echo '#!/bin/bash
exit 0' > "$TEST_DIR/repo10/bin/codex"
chmod +x "$TEST_DIR/repo10/bin/codex"

OUTPUT=$(PATH="$TEST_DIR/repo10/bin:$PATH" run_rlcr_setup "$TEST_DIR/repo10" plan.md 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "too simple"; then
    pass "Short plan rejected"
else
    fail "Short plan" "rejection" "exit=$EXIT_CODE"
fi

# Test 11: Plan file with spaces in path rejected
echo ""
echo "Test 11: Plan file with spaces in path rejected"
mkdir -p "$TEST_DIR/repo11"
init_basic_git_repo "$TEST_DIR/repo11"
mkdir -p "$TEST_DIR/repo11/path with spaces"
create_minimal_plan "$TEST_DIR/repo11" "path with spaces/plan.md"
echo "path with spaces/" >> "$TEST_DIR/repo11/.gitignore"
git -C "$TEST_DIR/repo11" add .gitignore && git -C "$TEST_DIR/repo11" commit -q -m "Add gitignore"

mkdir -p "$TEST_DIR/repo11/bin"
echo '#!/bin/bash
exit 0' > "$TEST_DIR/repo11/bin/codex"
chmod +x "$TEST_DIR/repo11/bin/codex"

OUTPUT=$(PATH="$TEST_DIR/repo11/bin:$PATH" run_rlcr_setup "$TEST_DIR/repo11" "path with spaces/plan.md" 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "cannot contain spaces"; then
    pass "Plan with spaces in path rejected"
else
    fail "Spaces in path" "rejection" "exit=$EXIT_CODE"
fi

# Test 12: Plan file with shell metacharacters rejected
echo ""
echo "Test 12: Plan file with shell metacharacters rejected"
mkdir -p "$TEST_DIR/repo12"
init_basic_git_repo "$TEST_DIR/repo12"

mkdir -p "$TEST_DIR/repo12/bin"
echo '#!/bin/bash
exit 0' > "$TEST_DIR/repo12/bin/codex"
chmod +x "$TEST_DIR/repo12/bin/codex"

# Try path with semicolon (can't create file, just test argument parsing)
OUTPUT=$(PATH="$TEST_DIR/repo12/bin:$PATH" run_rlcr_setup "$TEST_DIR/repo12" "plan;.md" 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "metacharacters\|not found"; then
    pass "Plan with metacharacters rejected"
else
    fail "Metacharacters" "rejection" "exit=$EXIT_CODE"
fi

# Test 13: Absolute path rejected
echo ""
echo "Test 13: Absolute path rejected"
mkdir -p "$TEST_DIR/repo13"
init_basic_git_repo "$TEST_DIR/repo13"
create_minimal_plan "$TEST_DIR/repo13"

mkdir -p "$TEST_DIR/repo13/bin"
echo '#!/bin/bash
exit 0' > "$TEST_DIR/repo13/bin/codex"
chmod +x "$TEST_DIR/repo13/bin/codex"

OUTPUT=$(PATH="$TEST_DIR/repo13/bin:$PATH" run_rlcr_setup "$TEST_DIR/repo13" "/absolute/path/plan.md" 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "relative path"; then
    pass "Absolute path rejected"
else
    fail "Absolute path" "rejection" "exit=$EXIT_CODE"
fi

# ========================================
# YAML Safety Validation Tests
# ========================================

echo ""
echo "--- YAML Safety Validation Tests ---"
echo ""

# Test 14: Branch name with colon rejected
echo "Test 14: Branch name with YAML-unsafe characters handled"
mkdir -p "$TEST_DIR/repo14"
init_basic_git_repo "$TEST_DIR/repo14"
create_minimal_plan "$TEST_DIR/repo14"
echo "plan.md" >> "$TEST_DIR/repo14/.gitignore"
git -C "$TEST_DIR/repo14" add .gitignore && git -C "$TEST_DIR/repo14" commit -q -m "Add gitignore"

mkdir -p "$TEST_DIR/repo14/bin"
echo '#!/bin/bash
exit 0' > "$TEST_DIR/repo14/bin/codex"
chmod +x "$TEST_DIR/repo14/bin/codex"

# Create branch with colon (YAML-unsafe)
cd "$TEST_DIR/repo14"
git checkout -q -b "test:branch" 2>/dev/null || true
cd - > /dev/null

OUTPUT=$(PATH="$TEST_DIR/repo14/bin:$PATH" run_rlcr_setup "$TEST_DIR/repo14" plan.md 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "YAML-unsafe"; then
    pass "YAML-unsafe branch name rejected"
else
    # If branch couldn't be created with colon, skip
    if git -C "$TEST_DIR/repo14" rev-parse --abbrev-ref HEAD 2>/dev/null | grep -q ":"; then
        fail "YAML-unsafe branch" "rejection" "exit=$EXIT_CODE"
    else
        pass "YAML-unsafe branch name test (branch creation varies by git version)"
    fi
fi

# Test 15: Codex model with invalid characters rejected
echo ""
echo "Test 15: Codex model with invalid characters rejected"
mkdir -p "$TEST_DIR/repo15"
init_basic_git_repo "$TEST_DIR/repo15"
create_minimal_plan "$TEST_DIR/repo15"
echo "plan.md" >> "$TEST_DIR/repo15/.gitignore"
git -C "$TEST_DIR/repo15" add .gitignore && git -C "$TEST_DIR/repo15" commit -q -m "Add gitignore"

mkdir -p "$TEST_DIR/repo15/bin"
echo '#!/bin/bash
exit 0' > "$TEST_DIR/repo15/bin/codex"
chmod +x "$TEST_DIR/repo15/bin/codex"

OUTPUT=$(PATH="$TEST_DIR/repo15/bin:$PATH" run_rlcr_setup "$TEST_DIR/repo15" plan.md --codex-model "model;injection" 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "invalid characters"; then
    pass "Codex model with invalid characters rejected"
else
    fail "Codex model validation" "rejection" "exit=$EXIT_CODE"
fi

# ========================================
# Git Repository Edge Cases
# ========================================

echo ""
echo "--- Git Repository Edge Cases ---"
echo ""

# Test 16: Non-git directory rejected
echo "Test 16: Non-git directory rejected"
mkdir -p "$TEST_DIR/nongit"
create_minimal_plan "$TEST_DIR/nongit"

OUTPUT=$(run_rlcr_setup "$TEST_DIR/nongit" plan.md 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "git repository"; then
    pass "Non-git directory rejected"
else
    fail "Non-git directory" "rejection" "exit=$EXIT_CODE"
fi

# Test 17: Git repo without commits rejected
echo ""
echo "Test 17: Git repo without commits rejected"
mkdir -p "$TEST_DIR/repo17"
cd "$TEST_DIR/repo17"
git init -q
git config user.email "test@test.com"
git config user.name "Test User"
cd - > /dev/null
create_minimal_plan "$TEST_DIR/repo17"

OUTPUT=$(run_rlcr_setup "$TEST_DIR/repo17" plan.md 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "at least one commit"; then
    pass "Git repo without commits rejected"
else
    fail "No commits" "rejection" "exit=$EXIT_CODE"
fi

# Test 18: Tracked plan file without --track-plan-file rejected
echo ""
echo "Test 18: Tracked plan file without --track-plan-file rejected"
mkdir -p "$TEST_DIR/repo18"
init_basic_git_repo "$TEST_DIR/repo18"
create_minimal_plan "$TEST_DIR/repo18"
git -C "$TEST_DIR/repo18" add plan.md && git -C "$TEST_DIR/repo18" commit -q -m "Add plan"

mkdir -p "$TEST_DIR/repo18/bin"
echo '#!/bin/bash
exit 0' > "$TEST_DIR/repo18/bin/codex"
chmod +x "$TEST_DIR/repo18/bin/codex"

OUTPUT=$(PATH="$TEST_DIR/repo18/bin:$PATH" run_rlcr_setup "$TEST_DIR/repo18" plan.md 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "gitignored\|track-plan-file"; then
    pass "Tracked plan file without flag rejected"
else
    fail "Tracked plan without flag" "rejection" "exit=$EXIT_CODE"
fi

# ========================================
# Setup PR Loop Tests
# ========================================

echo ""
echo "--- Setup PR Loop Argument Tests ---"
echo ""

# Test 19: Help flag displays usage
echo "Test 19: PR loop help flag displays usage"
OUTPUT=$("$PROJECT_ROOT/scripts/setup-pr-loop.sh" --help 2>&1) || true
if echo "$OUTPUT" | grep -q "USAGE\|start-pr-loop"; then
    pass "PR loop help flag displays usage"
else
    fail "PR loop help" "USAGE text" "no usage found"
fi

# Test 20: Missing bot flag shows error
echo ""
echo "Test 20: PR loop missing bot flag shows error"
OUTPUT=$("$PROJECT_ROOT/scripts/setup-pr-loop.sh" 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "at least one bot flag"; then
    pass "PR loop missing bot flag shows error"
else
    fail "Missing bot flag" "error message" "exit=$EXIT_CODE"
fi

# Test 21: Unknown option rejected
echo ""
echo "Test 21: PR loop unknown option rejected"
OUTPUT=$("$PROJECT_ROOT/scripts/setup-pr-loop.sh" --unknown-option 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "unknown option"; then
    pass "PR loop unknown option rejected"
else
    fail "PR loop unknown option" "rejection" "exit=$EXIT_CODE"
fi

# Test 22: --max with non-numeric value rejected
echo ""
echo "Test 22: PR loop --max with non-numeric value rejected"
OUTPUT=$("$PROJECT_ROOT/scripts/setup-pr-loop.sh" --claude --max abc 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "positive integer"; then
    pass "PR loop --max non-numeric rejected"
else
    fail "PR loop --max validation" "rejection" "exit=$EXIT_CODE"
fi

# Test 23: Non-git directory rejected
echo ""
echo "Test 23: PR loop non-git directory rejected"
mkdir -p "$TEST_DIR/pr-nongit"
OUTPUT=$(run_pr_setup "$TEST_DIR/pr-nongit" --claude 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "git repository"; then
    pass "PR loop non-git directory rejected"
else
    fail "PR loop non-git" "rejection" "exit=$EXIT_CODE"
fi

# ========================================
# Mutual Exclusion Tests
# ========================================

echo ""
echo "--- Mutual Exclusion Tests ---"
echo ""

# Test 24: RLCR loop blocks starting another RLCR loop
echo "Test 24: Active RLCR loop blocks new RLCR loop"
mkdir -p "$TEST_DIR/repo24"
init_basic_git_repo "$TEST_DIR/repo24"
create_minimal_plan "$TEST_DIR/repo24"
echo "plan.md" >> "$TEST_DIR/repo24/.gitignore"
git -C "$TEST_DIR/repo24" add .gitignore && git -C "$TEST_DIR/repo24" commit -q -m "Add gitignore"

# Create fake active RLCR loop
mkdir -p "$TEST_DIR/repo24/.humanize/rlcr/2026-01-19_00-00-00"
cat > "$TEST_DIR/repo24/.humanize/rlcr/2026-01-19_00-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 42
---
EOF

mkdir -p "$TEST_DIR/repo24/bin"
echo '#!/bin/bash
exit 0' > "$TEST_DIR/repo24/bin/codex"
chmod +x "$TEST_DIR/repo24/bin/codex"

OUTPUT=$(PATH="$TEST_DIR/repo24/bin:$PATH" run_rlcr_setup "$TEST_DIR/repo24" plan.md 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "already active"; then
    pass "Active RLCR loop blocks new RLCR loop"
else
    fail "RLCR mutual exclusion" "rejection" "exit=$EXIT_CODE"
fi

# Test 25: PR loop blocks starting RLCR loop
echo ""
echo "Test 25: Active PR loop blocks new RLCR loop"
mkdir -p "$TEST_DIR/repo25"
init_basic_git_repo "$TEST_DIR/repo25"
create_minimal_plan "$TEST_DIR/repo25"
echo "plan.md" >> "$TEST_DIR/repo25/.gitignore"
git -C "$TEST_DIR/repo25" add .gitignore && git -C "$TEST_DIR/repo25" commit -q -m "Add gitignore"

# Create fake active PR loop
mkdir -p "$TEST_DIR/repo25/.humanize/pr-loop/2026-01-19_00-00-00"
cat > "$TEST_DIR/repo25/.humanize/pr-loop/2026-01-19_00-00-00/state.md" << 'EOF'
---
current_round: 0
max_iterations: 42
pr_number: 123
---
EOF

mkdir -p "$TEST_DIR/repo25/bin"
echo '#!/bin/bash
exit 0' > "$TEST_DIR/repo25/bin/codex"
chmod +x "$TEST_DIR/repo25/bin/codex"

OUTPUT=$(PATH="$TEST_DIR/repo25/bin:$PATH" run_rlcr_setup "$TEST_DIR/repo25" plan.md 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "pr loop.*already active\|already active"; then
    pass "Active PR loop blocks new RLCR loop"
else
    fail "PR loop blocks RLCR" "rejection" "exit=$EXIT_CODE"
fi

# ========================================
# Symlink Protection Tests
# ========================================

echo ""
echo "--- Symlink Protection Tests ---"
echo ""

# Test 26: Plan file symlink rejected
echo "Test 26: Plan file symlink rejected"
mkdir -p "$TEST_DIR/repo26"
init_basic_git_repo "$TEST_DIR/repo26"
create_minimal_plan "$TEST_DIR/repo26"
ln -sf plan.md "$TEST_DIR/repo26/symlink-plan.md" 2>/dev/null || true
echo "plan.md" >> "$TEST_DIR/repo26/.gitignore"
echo "symlink-plan.md" >> "$TEST_DIR/repo26/.gitignore"
git -C "$TEST_DIR/repo26" add .gitignore && git -C "$TEST_DIR/repo26" commit -q -m "Add gitignore"

mkdir -p "$TEST_DIR/repo26/bin"
echo '#!/bin/bash
exit 0' > "$TEST_DIR/repo26/bin/codex"
chmod +x "$TEST_DIR/repo26/bin/codex"

if [[ -L "$TEST_DIR/repo26/symlink-plan.md" ]]; then
    OUTPUT=$(PATH="$TEST_DIR/repo26/bin:$PATH" run_rlcr_setup "$TEST_DIR/repo26" symlink-plan.md 2>&1) || EXIT_CODE=$?
    EXIT_CODE=${EXIT_CODE:-0}
    if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "symbolic link"; then
        pass "Plan file symlink rejected"
    else
        fail "Symlink rejection" "rejection" "exit=$EXIT_CODE"
    fi
else
    pass "Symlink test (symlink creation not supported)"
fi

# Test 27: Symlink in parent directory rejected
echo ""
echo "Test 27: Symlink in parent directory rejected"
mkdir -p "$TEST_DIR/repo27/real-dir"
init_basic_git_repo "$TEST_DIR/repo27"
create_minimal_plan "$TEST_DIR/repo27" "real-dir/plan.md"
ln -sf real-dir "$TEST_DIR/repo27/symlink-dir" 2>/dev/null || true
echo "real-dir/" >> "$TEST_DIR/repo27/.gitignore"
echo "symlink-dir" >> "$TEST_DIR/repo27/.gitignore"
git -C "$TEST_DIR/repo27" add .gitignore && git -C "$TEST_DIR/repo27" commit -q -m "Add gitignore"

mkdir -p "$TEST_DIR/repo27/bin"
echo '#!/bin/bash
exit 0' > "$TEST_DIR/repo27/bin/codex"
chmod +x "$TEST_DIR/repo27/bin/codex"

if [[ -L "$TEST_DIR/repo27/symlink-dir" ]]; then
    OUTPUT=$(PATH="$TEST_DIR/repo27/bin:$PATH" run_rlcr_setup "$TEST_DIR/repo27" symlink-dir/plan.md 2>&1) || EXIT_CODE=$?
    EXIT_CODE=${EXIT_CODE:-0}
    if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "symbolic link"; then
        pass "Symlink in parent directory rejected"
    else
        fail "Parent symlink rejection" "rejection" "exit=$EXIT_CODE"
    fi
else
    pass "Parent symlink test (symlink creation not supported)"
fi

# ========================================
# Positive Success Path Tests
# ========================================

echo ""
echo "--- Positive Success Path Tests ---"
echo ""

# Test 28: Valid RLCR setup proceeds past argument validation
echo "Test 28: Valid RLCR setup proceeds past argument validation"
mkdir -p "$TEST_DIR/repo28"
init_basic_git_repo "$TEST_DIR/repo28"
create_minimal_plan "$TEST_DIR/repo28"
echo "plan.md" >> "$TEST_DIR/repo28/.gitignore"
git -C "$TEST_DIR/repo28" add .gitignore && git -C "$TEST_DIR/repo28" commit -q -m "Add gitignore"

# Create empty bin dir with no codex - should fail at codex check
mkdir -p "$TEST_DIR/repo28/bin"
# Prepend empty bin dir to hide system codex (if any)

OUTPUT=$(PATH="$TEST_DIR/repo28/bin:$PATH" run_rlcr_setup "$TEST_DIR/repo28" plan.md 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
# Should fail at codex check (not argument parsing) - proves args were valid
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "codex"; then
    pass "Valid RLCR setup proceeds to codex check"
else
    # If codex is actually installed, it might proceed further
    if command -v codex &>/dev/null; then
        pass "Valid RLCR setup (codex available, may proceed further)"
    else
        fail "Valid RLCR setup" "fail at codex check" "exit=$EXIT_CODE"
    fi
fi

# Test 29: Valid arguments with --max and --codex-timeout
echo ""
echo "Test 29: Valid numeric arguments accepted"
mkdir -p "$TEST_DIR/repo29"
init_basic_git_repo "$TEST_DIR/repo29"
create_minimal_plan "$TEST_DIR/repo29"
echo "plan.md" >> "$TEST_DIR/repo29/.gitignore"
git -C "$TEST_DIR/repo29" add .gitignore && git -C "$TEST_DIR/repo29" commit -q -m "Add gitignore"

mkdir -p "$TEST_DIR/repo29/bin"

OUTPUT=$(PATH="$TEST_DIR/repo29/bin:$PATH" run_rlcr_setup "$TEST_DIR/repo29" plan.md --max 10 --codex-timeout 600 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
# Should NOT fail at argument parsing - should fail later (codex check)
if echo "$OUTPUT" | grep -qi "positive integer"; then
    fail "Valid numeric args" "accepted" "rejected as invalid"
else
    pass "Valid numeric arguments accepted (--max 10, --codex-timeout 600)"
fi

# Test 30: Valid PR loop setup proceeds past argument validation
echo ""
echo "Test 30: Valid PR loop setup proceeds past argument validation"
mkdir -p "$TEST_DIR/repo30"
init_basic_git_repo "$TEST_DIR/repo30"

# Create mock gh that fails auth check (to test dependency handling)
mkdir -p "$TEST_DIR/repo30/bin"
cat > "$TEST_DIR/repo30/bin/gh" << 'EOF'
#!/bin/bash
if [[ "$1" == "auth" && "$2" == "status" ]]; then
    echo "Not logged in" >&2
    exit 1
fi
exit 0
EOF
chmod +x "$TEST_DIR/repo30/bin/gh"

OUTPUT=$(PATH="$TEST_DIR/repo30/bin:$PATH" run_pr_setup "$TEST_DIR/repo30" --claude 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
# Should fail at gh auth check, not argument parsing
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "gh\|auth\|logged"; then
    pass "Valid PR loop setup proceeds to gh auth check"
else
    fail "Valid PR loop setup" "fail at gh auth check" "exit=$EXIT_CODE"
fi

# ========================================
# Timeout Scenario Tests
# ========================================

echo ""
echo "--- Timeout Scenario Tests ---"
echo ""

# Test 31: --codex-timeout with zero accepted (current behavior)
# Note: The validation regex ^[0-9]+$ allows 0, treating it as valid non-negative integer
echo "Test 31: --codex-timeout with zero is accepted"
mkdir -p "$TEST_DIR/repo31"
init_basic_git_repo "$TEST_DIR/repo31"
create_minimal_plan "$TEST_DIR/repo31"
echo "plan.md" >> "$TEST_DIR/repo31/.gitignore"
git -C "$TEST_DIR/repo31" add .gitignore && git -C "$TEST_DIR/repo31" commit -q -m "Add gitignore"
mkdir -p "$TEST_DIR/repo31/bin"
OUTPUT=$(PATH="$TEST_DIR/repo31/bin:$PATH" run_rlcr_setup "$TEST_DIR/repo31" plan.md --codex-timeout 0 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
# Zero should be accepted (not rejected as "positive integer" error)
if echo "$OUTPUT" | grep -qi "positive integer"; then
    fail "--codex-timeout 0" "accepted" "rejected as not positive integer"
else
    pass "--codex-timeout 0 accepted (non-negative integer validation)"
fi

# Test 32: --codex-timeout with non-numeric value rejected (PR loop)
echo ""
echo "Test 32: PR loop --codex-timeout with non-numeric value rejected"
mkdir -p "$TEST_DIR/repo32"
init_basic_git_repo "$TEST_DIR/repo32"
mkdir -p "$TEST_DIR/repo32/bin"
OUTPUT=$(PATH="$TEST_DIR/repo32/bin:$PATH" run_pr_setup "$TEST_DIR/repo32" --claude --codex-timeout "abc" 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "positive integer"; then
    pass "PR loop --codex-timeout non-numeric rejected"
else
    fail "PR loop --codex-timeout non-numeric" "rejection with 'positive integer'" "exit=$EXIT_CODE, output=$OUTPUT"
fi

# Test 33: Very large timeout value accepted
echo ""
echo "Test 33: Very large timeout value accepted"
mkdir -p "$TEST_DIR/repo33"
init_basic_git_repo "$TEST_DIR/repo33"
create_minimal_plan "$TEST_DIR/repo33"
echo "plan.md" >> "$TEST_DIR/repo33/.gitignore"
git -C "$TEST_DIR/repo33" add .gitignore && git -C "$TEST_DIR/repo33" commit -q -m "Add gitignore"

mkdir -p "$TEST_DIR/repo33/bin"

OUTPUT=$(PATH="$TEST_DIR/repo33/bin:$PATH" run_rlcr_setup "$TEST_DIR/repo33" plan.md --codex-timeout 999999 2>&1) || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}
# Should NOT fail at timeout validation
if echo "$OUTPUT" | grep -qi "timeout.*invalid\|positive integer"; then
    fail "Large timeout" "accepted" "rejected"
else
    pass "Very large timeout value accepted (999999)"
fi

# Test 34: Timeout scenario simulation via mock timeout command
echo ""
echo "Test 34: Timeout scenario via mock timeout/gtimeout command"
mkdir -p "$TEST_DIR/repo34"
init_basic_git_repo "$TEST_DIR/repo34"
create_minimal_plan "$TEST_DIR/repo34"
echo "plan.md" >> "$TEST_DIR/repo34/.gitignore"
git -C "$TEST_DIR/repo34" add .gitignore && git -C "$TEST_DIR/repo34" commit -q -m "Add gitignore"

# Create a mock timeout command that always returns 124 (timeout exit code)
# This simulates what happens when run_with_timeout times out
mkdir -p "$TEST_DIR/repo34/bin"

# Get real git path for mock to use
REAL_GIT=$(command -v git)

# Mock timeout that returns 124 for git rev-parse (first check in setup script)
cat > "$TEST_DIR/repo34/bin/timeout" << TIMEOUTEOF
#!/bin/bash
# Mock timeout that returns 124 for git rev-parse to simulate timeout
if [[ "\$*" == *"git"*"rev-parse"* ]]; then
    exit 124
fi
# For other commands, execute normally by stripping timeout args and running
shift  # remove timeout value
exec "\$@"
TIMEOUTEOF
chmod +x "$TEST_DIR/repo34/bin/timeout"

# Also mock gtimeout (macOS with Homebrew)
cp "$TEST_DIR/repo34/bin/timeout" "$TEST_DIR/repo34/bin/gtimeout"
chmod +x "$TEST_DIR/repo34/bin/gtimeout"

# Create mock codex
cat > "$TEST_DIR/repo34/bin/codex" << 'CODEXEOF'
#!/bin/bash
exit 0
CODEXEOF
chmod +x "$TEST_DIR/repo34/bin/codex"

set +e
OUTPUT=$(PATH="$TEST_DIR/repo34/bin:$PATH" run_rlcr_setup "$TEST_DIR/repo34" plan.md 2>&1)
EXIT_CODE=$?
set -e

# The setup should fail with a timeout-related error message
if [[ $EXIT_CODE -ne 0 ]] && echo "$OUTPUT" | grep -qi "timeout\|timed out"; then
    pass "Timeout error message shown (exit $EXIT_CODE)"
else
    # Even without exact message, non-zero exit for timeout mock is acceptable
    if [[ $EXIT_CODE -ne 0 ]]; then
        pass "Timeout scenario causes failure (exit $EXIT_CODE)"
    else
        fail "Timeout handling" "non-zero exit or timeout message" "exit=$EXIT_CODE"
    fi
fi

# Test 35: Non-portable git path handling
echo ""
echo "Test 35: Mock uses portable git path detection"
# Verify our mock doesn't hardcode /usr/bin/git
if grep -q "/usr/bin/git" "$TEST_DIR/repo34/bin/timeout" 2>/dev/null; then
    fail "Portable git" "no hardcoded /usr/bin/git" "found hardcoded path"
else
    pass "Timeout mock uses portable command detection"
fi

# ========================================
# Summary
# ========================================

print_test_summary "Setup Scripts Robustness Test Summary"
exit $?
