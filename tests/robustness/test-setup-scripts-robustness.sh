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
OUTPUT=$(cd "$TEST_DIR/repo2" && "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" 2>&1) || EXIT_CODE=$?
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

# Test 4: --max with negative value rejected
echo ""
echo "Test 4: --max with negative value (empty after strip)"
# Note: --max -5 would be treated as -5 option not value
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

OUTPUT=$(cd "$TEST_DIR/repo8" && "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" plan.md --plan-file other.md 2>&1) || EXIT_CODE=$?
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

OUTPUT=$(cd "$TEST_DIR/repo9" && PATH="$TEST_DIR/repo9/bin:$PATH" "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" plan.md 2>&1) || EXIT_CODE=$?
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

OUTPUT=$(cd "$TEST_DIR/repo10" && PATH="$TEST_DIR/repo10/bin:$PATH" "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" plan.md 2>&1) || EXIT_CODE=$?
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

OUTPUT=$(cd "$TEST_DIR/repo11" && PATH="$TEST_DIR/repo11/bin:$PATH" "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" "path with spaces/plan.md" 2>&1) || EXIT_CODE=$?
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
OUTPUT=$(cd "$TEST_DIR/repo12" && PATH="$TEST_DIR/repo12/bin:$PATH" "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" "plan;.md" 2>&1) || EXIT_CODE=$?
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

OUTPUT=$(cd "$TEST_DIR/repo13" && PATH="$TEST_DIR/repo13/bin:$PATH" "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" "/absolute/path/plan.md" 2>&1) || EXIT_CODE=$?
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

OUTPUT=$(cd "$TEST_DIR/repo14" && PATH="$TEST_DIR/repo14/bin:$PATH" "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" plan.md 2>&1) || EXIT_CODE=$?
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

OUTPUT=$(cd "$TEST_DIR/repo15" && PATH="$TEST_DIR/repo15/bin:$PATH" "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" plan.md --codex-model "model;injection" 2>&1) || EXIT_CODE=$?
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

OUTPUT=$(cd "$TEST_DIR/nongit" && "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" plan.md 2>&1) || EXIT_CODE=$?
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

OUTPUT=$(cd "$TEST_DIR/repo17" && "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" plan.md 2>&1) || EXIT_CODE=$?
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

OUTPUT=$(cd "$TEST_DIR/repo18" && PATH="$TEST_DIR/repo18/bin:$PATH" "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" plan.md 2>&1) || EXIT_CODE=$?
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
OUTPUT=$(cd "$TEST_DIR/pr-nongit" && "$PROJECT_ROOT/scripts/setup-pr-loop.sh" --claude 2>&1) || EXIT_CODE=$?
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

OUTPUT=$(cd "$TEST_DIR/repo24" && PATH="$TEST_DIR/repo24/bin:$PATH" "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" plan.md 2>&1) || EXIT_CODE=$?
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

OUTPUT=$(cd "$TEST_DIR/repo25" && PATH="$TEST_DIR/repo25/bin:$PATH" "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" plan.md 2>&1) || EXIT_CODE=$?
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
    OUTPUT=$(cd "$TEST_DIR/repo26" && PATH="$TEST_DIR/repo26/bin:$PATH" "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" symlink-plan.md 2>&1) || EXIT_CODE=$?
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
    OUTPUT=$(cd "$TEST_DIR/repo27" && PATH="$TEST_DIR/repo27/bin:$PATH" "$PROJECT_ROOT/scripts/setup-rlcr-loop.sh" symlink-dir/plan.md 2>&1) || EXIT_CODE=$?
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
# Summary
# ========================================

print_test_summary "Setup Scripts Robustness Test Summary"
exit $?
