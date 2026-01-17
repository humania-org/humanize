#!/bin/bash
#
# Test script for humanize-escape fixes
#
# Tests:
# 1. Zsh safety for empty/dotfile directory scenarios
# 2. git_adds_humanize path variant detection (./.humanize, quoted paths)
#
# These tests verify the fixes for:
# - AC-1.2: No zsh/bash "no matches found" errors
# - AC-2.1: Block git add .humanize (including path variants)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_ROOT/hooks/lib/loop-common.sh"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

TESTS_PASSED=0
TESTS_FAILED=0

# Test helper functions
pass() {
    echo -e "${GREEN}PASS${NC}: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "${RED}FAIL${NC}: $1"
    echo "  Details: $2"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# ========================================
# Test Group 1: git_adds_humanize Path Variants
# ========================================

# Assert that a git add command SHOULD be blocked
assert_blocks() {
    local command="$1"
    local description="$2"
    local command_lower
    command_lower=$(to_lower "$command")

    if git_adds_humanize "$command_lower"; then
        pass "$description"
    else
        fail "$description" "Command should be blocked: $command"
    fi
}

# Assert that a git add command should NOT be blocked
assert_allows() {
    local command="$1"
    local description="$2"
    local command_lower
    command_lower=$(to_lower "$command")

    if git_adds_humanize "$command_lower"; then
        fail "$description" "Command should be allowed: $command"
    else
        pass "$description"
    fi
}

echo "========================================"
echo "Testing humanize-escape Fixes"
echo "========================================"
echo ""

# ========================================
# Test Group 1: ./.humanize Path Variants
# ========================================
echo "Test Group 1: ./.humanize Path Variants (AC-2.1)"
echo ""

assert_blocks "git add ./.humanize" "Block: ./.humanize prefix"
assert_blocks "git add ./.humanize/" "Block: ./.humanize/ with trailing slash"
assert_blocks "git add ./.humanize/file.md" "Block: ./.humanize/file.md"
assert_blocks "git add path/to/.humanize" "Block: path/to/.humanize"
assert_blocks "git add ../project/.humanize" "Block: ../project/.humanize"

# ========================================
# Test Group 2: Quoted Path Variants
# ========================================
echo ""
echo "Test Group 2: Quoted Path Variants (AC-2.1)"
echo ""

assert_blocks 'git add ".humanize"' "Block: double-quoted .humanize"
assert_blocks "git add '.humanize'" "Block: single-quoted .humanize"
assert_blocks 'git add "./.humanize"' "Block: double-quoted ./.humanize"
assert_blocks "git add './.humanize'" "Block: single-quoted ./.humanize"
assert_blocks 'git add "path/to/.humanize"' "Block: double-quoted path/to/.humanize"

# ========================================
# Test Group 3: Combined Force and Path Variants
# ========================================
echo ""
echo "Test Group 3: Combined Force and Path Variants (AC-2.2)"
echo ""

assert_blocks "git add -f ./.humanize" "Block: -f with ./.humanize"
assert_blocks "git add --force ./.humanize" "Block: --force with ./.humanize"
assert_blocks 'git add -f ".humanize"' "Block: -f with quoted .humanize"

# AC-2.2: Force flag with broad scope (blocks gitignore bypass)
assert_blocks "git add -f ." "Block: -f . (force with current dir)"
assert_blocks "git add --force ." "Block: --force . (force with current dir)"
assert_blocks "git add -f *" "Block: -f * (force with wildcard)"
assert_blocks "git add --force *" "Block: --force * (force with wildcard)"
assert_blocks "git add -fA" "Block: -fA (combined force and all)"
assert_blocks "git add -Af" "Block: -Af (combined all and force)"

# ========================================
# Test Group 3b: git add -A / --all (AC-2.3)
# ========================================
echo ""
echo "Test Group 3b: git add -A / --all (AC-2.3)"
echo ""

# These tests require .humanize directory to exist for blocking to trigger
# (git_adds_humanize only blocks -A/--all when .humanize exists)
TEST_HUMANIZE_DIR="/tmp/test-humanize-git-add-$$"
mkdir -p "$TEST_HUMANIZE_DIR/.humanize"
ORIGINAL_DIR="$(pwd)"
cd "$TEST_HUMANIZE_DIR"

assert_blocks "git add -A" "Block: -A (adds all including .humanize)"
assert_blocks "git add --all" "Block: --all (adds all including .humanize)"
assert_blocks "git add -A ." "Block: -A . (all in current dir)"
assert_blocks "git add --all ." "Block: --all . (all in current dir)"
assert_blocks "git add -A src/" "Block: -A src/ (all flag present)"
assert_blocks "git add --all src/" "Block: --all src/ (all flag present)"

# Return to original directory and clean up
cd "$ORIGINAL_DIR"
rm -rf "$TEST_HUMANIZE_DIR"

# ========================================
# Test Group 4: Chained Commands with Path Variants
# ========================================
echo ""
echo "Test Group 4: Chained Commands with Path Variants"
echo ""

assert_blocks "cd repo && git add ./.humanize" "Block: cd && git add ./.humanize"
assert_blocks "true; git add ./.humanize" "Block: true; git add ./.humanize"
assert_blocks 'echo test && git add ".humanize"' "Block: echo && git add quoted"

# ========================================
# Test Group 5: git -C with Path Variants
# ========================================
echo ""
echo "Test Group 5: git -C with Path Variants"
echo ""

assert_blocks "git -C /path add ./.humanize" "Block: git -C with ./.humanize"
assert_blocks 'git -C /path add ".humanize"' "Block: git -C with quoted .humanize"
assert_blocks "git --git-dir=/repo add ./.humanize" "Block: --git-dir with ./.humanize"

# ========================================
# Test Group 6: Allowed Commands (should NOT block)
# ========================================
echo ""
echo "Test Group 6: Allowed Commands (should NOT block)"
echo ""

assert_allows "git add src/file.js" "Allow: specific file"
assert_allows "git add ./src/file.js" "Allow: ./src/file.js"
assert_allows "git add src/.gitkeep" "Allow: .gitkeep (not .humanize)"
assert_allows "git add .gitignore" "Allow: .gitignore"
assert_allows "git add ./src/" "Allow: ./src/ directory"
assert_allows "git status .humanize" "Allow: git status (not add)"
assert_allows "git diff .humanize" "Allow: git diff (not add)"
assert_allows "git log -- .humanize" "Allow: git log (not add)"

# Patch mode is safe (interactive)
assert_allows "git add -p" "Allow: -p (patch mode, interactive)"
assert_allows "git add --patch" "Allow: --patch (patch mode)"
assert_allows "git add -p src/" "Allow: -p src/ (patch mode with path)"

# Files that start with .humanize but are NOT the .humanize directory
assert_allows "git add .humanizeconfig" "Allow: .humanizeconfig (different file)"
assert_allows "git add .humanize-backup" "Allow: .humanize-backup (different file)"
assert_allows "git add src/.humanizerc" "Allow: src/.humanizerc (different file)"

# ========================================
# Test Group 7: Zsh Empty Directory Safety
# ========================================
echo ""
echo "Test Group 7: Zsh Empty Directory Safety (AC-1.2)"
echo ""

# Test find-based iteration in zsh with empty directories
# These tests verify that the find-based iteration works correctly

test_empty_dir() {
    local test_dir="/tmp/test-humanize-empty-$$"
    mkdir -p "$test_dir"

    # Simulate the find-based iteration pattern used in humanize.sh
    local found_count=0
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        found_count=$((found_count + 1))
    done < <(find "$test_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

    rm -rf "$test_dir"

    if [[ "$found_count" -eq 0 ]]; then
        pass "Empty directory iteration returns 0 items (no error)"
    else
        fail "Empty directory iteration" "Expected 0 items, got $found_count"
    fi
}
test_empty_dir

test_dotfiles_only_dir() {
    local test_dir="/tmp/test-humanize-dotfiles-$$"
    mkdir -p "$test_dir"
    touch "$test_dir/.cancel-requested"
    touch "$test_dir/.hidden-file"

    # find -type d should find no directories (only dotfiles which are files)
    local found_count=0
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        found_count=$((found_count + 1))
    done < <(find "$test_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

    rm -rf "$test_dir"

    if [[ "$found_count" -eq 0 ]]; then
        pass "Dotfiles-only directory iteration returns 0 dirs (no error)"
    else
        fail "Dotfiles-only directory iteration" "Expected 0 dirs, got $found_count"
    fi
}
test_dotfiles_only_dir

test_no_state_md_files() {
    local test_dir="/tmp/test-humanize-nostate-$$"
    mkdir -p "$test_dir"
    touch "$test_dir/other.txt"
    touch "$test_dir/readme.md"

    # Simulate finding *-state.md files
    local found_count=0
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        found_count=$((found_count + 1))
    done < <(find "$test_dir" -maxdepth 1 -name '*-state.md' -type f 2>/dev/null)

    rm -rf "$test_dir"

    if [[ "$found_count" -eq 0 ]]; then
        pass "No *-state.md files iteration returns 0 items (no error)"
    else
        fail "No *-state.md files iteration" "Expected 0 items, got $found_count"
    fi
}
test_no_state_md_files

test_state_md_detection() {
    local test_dir="/tmp/test-humanize-state-$$"
    mkdir -p "$test_dir"
    touch "$test_dir/completed-state.md"
    touch "$test_dir/other.md"

    # Simulate finding *-state.md files
    local found_count=0
    local found_file=""
    while IFS= read -r item; do
        [[ -z "$item" ]] && continue
        found_count=$((found_count + 1))
        found_file="$item"
    done < <(find "$test_dir" -maxdepth 1 -name '*-state.md' -type f 2>/dev/null)

    rm -rf "$test_dir"

    if [[ "$found_count" -eq 1 ]] && [[ "$found_file" == *"completed-state.md" ]]; then
        pass "*-state.md detection finds completed-state.md"
    else
        fail "*-state.md detection" "Expected 1 item (completed-state.md), got $found_count: $found_file"
    fi
}
test_state_md_detection

# ========================================
# Test Group 8: Session Directory Detection
# ========================================
echo ""
echo "Test Group 8: Session Directory Detection"
echo ""

test_session_dir_detection() {
    local test_dir="/tmp/test-humanize-sessions-$$"
    mkdir -p "$test_dir"
    mkdir -p "$test_dir/2026-01-16_10-30-00"
    mkdir -p "$test_dir/2026-01-16_11-00-00"
    touch "$test_dir/.cancel-requested"  # Should be ignored (not a dir)

    local found_count=0
    local latest=""
    while IFS= read -r session_dir; do
        [[ -z "$session_dir" ]] && continue
        [[ ! -d "$session_dir" ]] && continue
        local session_name=$(basename "$session_dir")
        if [[ "$session_name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
            found_count=$((found_count + 1))
            if [[ -z "$latest" ]] || [[ "$session_name" > "$(basename "$latest")" ]]; then
                latest="$session_dir"
            fi
        fi
    done < <(find "$test_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

    rm -rf "$test_dir"

    if [[ "$found_count" -eq 2 ]] && [[ "$(basename "$latest")" == "2026-01-16_11-00-00" ]]; then
        pass "Session directory detection finds 2 sessions, latest is 11-00-00"
    else
        fail "Session directory detection" "Expected 2 sessions with latest 11-00-00, got $found_count with latest $(basename "$latest")"
    fi
}
test_session_dir_detection

# ========================================
# Summary
# ========================================
echo ""
echo "========================================"
echo "Test Summary"
echo "========================================"
echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed: ${RED}$TESTS_FAILED${NC}"

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo ""
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo ""
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi
