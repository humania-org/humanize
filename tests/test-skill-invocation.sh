#!/bin/bash
#
# Test script for skill invocation validation
#
# This test verifies:
# - Skill loading mechanism (SKILL.md discovery)
# - Command-to-skill delegation
# - allowed-tools constraints
# - Skill content matches command functionality
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILLS_DIR="$PROJECT_ROOT/skills"
COMMANDS_DIR="$PROJECT_ROOT/commands"
SCRIPTS_DIR="$PROJECT_ROOT/scripts"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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
    if [[ -n "${2:-}" ]]; then
        echo "  Expected: $2"
    fi
    if [[ -n "${3:-}" ]]; then
        echo "  Got: $3"
    fi
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

echo "========================================"
echo "Testing Skill Invocation and Delegation"
echo "========================================"
echo ""

# ========================================
# Skill Loading Tests
# ========================================
echo "========================================"
echo "Skill Loading Tests"
echo "========================================"

# Test 1: start-rlcr-loop skill can be discovered
echo ""
echo "Test 1: start-rlcr-loop skill discoverable"
START_SKILL="$SKILLS_DIR/start-rlcr-loop/SKILL.md"
if [[ -f "$START_SKILL" ]]; then
    # Verify it has the minimum required structure for discovery
    if grep -q "^---$" "$START_SKILL" && grep -q "^name:" "$START_SKILL" && grep -q "^description:" "$START_SKILL"; then
        pass "start-rlcr-loop skill is discoverable (has required frontmatter)"
    else
        fail "start-rlcr-loop skill discovery" "Has name and description frontmatter" "Missing required fields"
    fi
else
    fail "start-rlcr-loop skill exists" "File exists" "File not found"
fi

# Test 2: cancel-rlcr-loop skill can be discovered
echo ""
echo "Test 2: cancel-rlcr-loop skill discoverable"
CANCEL_SKILL="$SKILLS_DIR/cancel-rlcr-loop/SKILL.md"
if [[ -f "$CANCEL_SKILL" ]]; then
    if grep -q "^---$" "$CANCEL_SKILL" && grep -q "^name:" "$CANCEL_SKILL" && grep -q "^description:" "$CANCEL_SKILL"; then
        pass "cancel-rlcr-loop skill is discoverable (has required frontmatter)"
    else
        fail "cancel-rlcr-loop skill discovery" "Has name and description frontmatter" "Missing required fields"
    fi
else
    fail "cancel-rlcr-loop skill exists" "File exists" "File not found"
fi

# ========================================
# Command-to-Skill Delegation Tests
# ========================================
echo ""
echo "========================================"
echo "Command-to-Skill Delegation Tests"
echo "========================================"

# Test 3: start-rlcr-loop command references skill
echo ""
echo "Test 3: start-rlcr-loop command references skill"
START_CMD="$COMMANDS_DIR/start-rlcr-loop.md"
if [[ -f "$START_CMD" ]]; then
    # Check for delegation reference (comment or explicit reference)
    if grep -qi "skill" "$START_CMD"; then
        pass "start-rlcr-loop command references skill"
    else
        fail "start-rlcr-loop command delegation" "Reference to skill" "No skill reference found"
    fi
else
    fail "start-rlcr-loop command exists" "File exists" "File not found"
fi

# Test 4: cancel-rlcr-loop command references skill
echo ""
echo "Test 4: cancel-rlcr-loop command references skill"
CANCEL_CMD="$COMMANDS_DIR/cancel-rlcr-loop.md"
if [[ -f "$CANCEL_CMD" ]]; then
    if grep -qi "skill" "$CANCEL_CMD"; then
        pass "cancel-rlcr-loop command references skill"
    else
        fail "cancel-rlcr-loop command delegation" "Reference to skill" "No skill reference found"
    fi
else
    fail "cancel-rlcr-loop command exists" "File exists" "File not found"
fi

# Test 5: Skill and command have matching core functionality
echo ""
echo "Test 5: start-rlcr-loop skill/command functionality match"
if [[ -f "$START_SKILL" ]] && [[ -f "$START_CMD" ]]; then
    # Both should reference setup-rlcr-loop.sh
    SKILL_HAS_SCRIPT=$(grep -c "setup-rlcr-loop.sh" "$START_SKILL" || echo "0")
    CMD_HAS_SCRIPT=$(grep -c "setup-rlcr-loop.sh" "$START_CMD" || echo "0")
    if [[ $SKILL_HAS_SCRIPT -gt 0 ]] && [[ $CMD_HAS_SCRIPT -gt 0 ]]; then
        pass "Both skill and command reference setup-rlcr-loop.sh"
    else
        fail "start-rlcr-loop functionality match" "Both reference setup-rlcr-loop.sh" "skill=$SKILL_HAS_SCRIPT, cmd=$CMD_HAS_SCRIPT"
    fi
fi

# Test 6: cancel-rlcr-loop skill/command functionality match
echo ""
echo "Test 6: cancel-rlcr-loop skill/command core instructions match"
if [[ -f "$CANCEL_SKILL" ]] && [[ -f "$CANCEL_CMD" ]]; then
    # Both should have instructions about finding loop directory
    SKILL_HAS_LOOP=$(grep -c "\.humanize/rlcr" "$CANCEL_SKILL" || echo "0")
    CMD_HAS_LOOP=$(grep -c "\.humanize/rlcr" "$CANCEL_CMD" || echo "0")
    if [[ $SKILL_HAS_LOOP -gt 0 ]] && [[ $CMD_HAS_LOOP -gt 0 ]]; then
        pass "Both skill and command reference .humanize/rlcr directory"
    else
        fail "cancel-rlcr-loop functionality match" "Both reference .humanize/rlcr" "skill=$SKILL_HAS_LOOP, cmd=$CMD_HAS_LOOP"
    fi
fi

# ========================================
# Allowed-Tools Constraint Tests
# ========================================
echo ""
echo "========================================"
echo "Allowed-Tools Constraint Tests"
echo "========================================"

# Test 7: start-rlcr-loop skill has allowed-tools
echo ""
echo "Test 7: start-rlcr-loop skill has allowed-tools"
if [[ -f "$START_SKILL" ]]; then
    if grep -q "^allowed-tools:" "$START_SKILL"; then
        # Extract and verify it includes the setup script
        if grep -q "setup-rlcr-loop.sh" "$START_SKILL"; then
            pass "start-rlcr-loop skill has allowed-tools with setup script"
        else
            fail "start-rlcr-loop allowed-tools" "Includes setup-rlcr-loop.sh" "Script not in allowed-tools"
        fi
    else
        fail "start-rlcr-loop allowed-tools" "Has allowed-tools field" "Field not found"
    fi
fi

# Test 8: cancel-rlcr-loop skill has allowed-tools
echo ""
echo "Test 8: cancel-rlcr-loop skill has allowed-tools"
if [[ -f "$CANCEL_SKILL" ]]; then
    if grep -q "^allowed-tools:" "$CANCEL_SKILL"; then
        # Verify it includes Bash commands for loop management
        if grep -q "Bash" "$CANCEL_SKILL"; then
            pass "cancel-rlcr-loop skill has allowed-tools with Bash commands"
        else
            fail "cancel-rlcr-loop allowed-tools" "Includes Bash commands" "Bash not in allowed-tools"
        fi
    else
        fail "cancel-rlcr-loop allowed-tools" "Has allowed-tools field" "Field not found"
    fi
fi

# Test 9: Skill allowed-tools match command allowed-tools
echo ""
echo "Test 9: start-rlcr-loop skill/command allowed-tools consistency"
if [[ -f "$START_SKILL" ]] && [[ -f "$START_CMD" ]]; then
    # Extract allowed-tools from both (simplified - check for same script reference)
    SKILL_TOOLS=$(grep -A5 "^allowed-tools:" "$START_SKILL" | head -6)
    CMD_TOOLS=$(grep "allowed-tools" "$START_CMD" | head -1)

    # Both should allow the setup script
    if echo "$SKILL_TOOLS" | grep -q "setup-rlcr-loop.sh" && echo "$CMD_TOOLS" | grep -q "setup-rlcr-loop.sh"; then
        pass "start-rlcr-loop skill/command both allow setup-rlcr-loop.sh"
    else
        fail "start-rlcr-loop allowed-tools consistency" "Both allow setup script" "Mismatch detected"
    fi
fi

# ========================================
# Script Execution Validation Tests
# ========================================
echo ""
echo "========================================"
echo "Script Execution Validation Tests"
echo "========================================"

# Test 10: setup-rlcr-loop.sh exists and is executable
echo ""
echo "Test 10: setup-rlcr-loop.sh is executable"
SETUP_SCRIPT="$SCRIPTS_DIR/setup-rlcr-loop.sh"
if [[ -f "$SETUP_SCRIPT" ]]; then
    if [[ -x "$SETUP_SCRIPT" ]]; then
        pass "setup-rlcr-loop.sh exists and is executable"
    else
        fail "setup-rlcr-loop.sh executable" "Is executable" "Not executable"
    fi
else
    fail "setup-rlcr-loop.sh exists" "File exists" "File not found"
fi

# Test 11: setup-rlcr-loop.sh has valid syntax
echo ""
echo "Test 11: setup-rlcr-loop.sh has valid syntax"
if [[ -f "$SETUP_SCRIPT" ]]; then
    if bash -n "$SETUP_SCRIPT" 2>/dev/null; then
        pass "setup-rlcr-loop.sh has valid bash syntax"
    else
        fail "setup-rlcr-loop.sh syntax" "Valid bash" "Syntax error"
    fi
fi

# Test 12: setup-rlcr-loop.sh --help works
echo ""
echo "Test 12: setup-rlcr-loop.sh --help executes"
if [[ -f "$SETUP_SCRIPT" ]]; then
    set +e
    HELP_OUTPUT=$("$SETUP_SCRIPT" --help 2>&1)
    HELP_EXIT=$?
    set -e
    # --help should show usage and exit 0
    if [[ $HELP_EXIT -eq 0 ]] && echo "$HELP_OUTPUT" | grep -qi "usage\|help\|options"; then
        pass "setup-rlcr-loop.sh --help shows usage"
    else
        fail "setup-rlcr-loop.sh --help" "Shows usage, exit 0" "exit $HELP_EXIT"
    fi
fi

# ========================================
# Auto-Invocation Keyword Tests
# ========================================
echo ""
echo "========================================"
echo "Auto-Invocation Keyword Tests"
echo "========================================"

# Test 13: start-rlcr-loop skill has auto-invocation keywords
echo ""
echo "Test 13: start-rlcr-loop skill has auto-invocation keywords"
if [[ -f "$START_SKILL" ]]; then
    DESC=$(sed -n '/^---$/,/^---$/{ /^description:/{ s/^description:[[:space:]]*//p; q; } }' "$START_SKILL")
    # Check for keywords that would trigger auto-invocation
    KEYWORDS_FOUND=0
    for keyword in "iterative" "development" "loop" "Codex" "review" "RLCR" "implement" "plan"; do
        if echo "$DESC" | grep -qi "$keyword"; then
            KEYWORDS_FOUND=$((KEYWORDS_FOUND + 1))
        fi
    done
    if [[ $KEYWORDS_FOUND -ge 3 ]]; then
        pass "start-rlcr-loop skill has $KEYWORDS_FOUND auto-invocation keywords"
    else
        fail "start-rlcr-loop auto-invocation" "At least 3 keywords" "Found $KEYWORDS_FOUND"
    fi
fi

# Test 14: cancel-rlcr-loop skill has auto-invocation keywords
echo ""
echo "Test 14: cancel-rlcr-loop skill has auto-invocation keywords"
if [[ -f "$CANCEL_SKILL" ]]; then
    DESC=$(sed -n '/^---$/,/^---$/{ /^description:/{ s/^description:[[:space:]]*//p; q; } }' "$CANCEL_SKILL")
    KEYWORDS_FOUND=0
    for keyword in "cancel" "stop" "exit" "RLCR" "loop" "development"; do
        if echo "$DESC" | grep -qi "$keyword"; then
            KEYWORDS_FOUND=$((KEYWORDS_FOUND + 1))
        fi
    done
    if [[ $KEYWORDS_FOUND -ge 3 ]]; then
        pass "cancel-rlcr-loop skill has $KEYWORDS_FOUND auto-invocation keywords"
    else
        fail "cancel-rlcr-loop auto-invocation" "At least 3 keywords" "Found $KEYWORDS_FOUND"
    fi
fi

# ========================================
# Skill Content Completeness Tests
# ========================================
echo ""
echo "========================================"
echo "Skill Content Completeness Tests"
echo "========================================"

# Test 15: start-rlcr-loop skill has complete instructions
echo ""
echo "Test 15: start-rlcr-loop skill has complete instructions"
if [[ -f "$START_SKILL" ]]; then
    INSTRUCTION_ELEMENTS=0
    # Check for key instruction elements
    grep -q "setup-rlcr-loop.sh" "$START_SKILL" && INSTRUCTION_ELEMENTS=$((INSTRUCTION_ELEMENTS + 1))
    grep -q "Goal Tracker" "$START_SKILL" && INSTRUCTION_ELEMENTS=$((INSTRUCTION_ELEMENTS + 1))
    grep -q "summary" "$START_SKILL" && INSTRUCTION_ELEMENTS=$((INSTRUCTION_ELEMENTS + 1))
    grep -q "Codex" "$START_SKILL" && INSTRUCTION_ELEMENTS=$((INSTRUCTION_ELEMENTS + 1))

    if [[ $INSTRUCTION_ELEMENTS -ge 4 ]]; then
        pass "start-rlcr-loop skill has complete instructions ($INSTRUCTION_ELEMENTS elements)"
    else
        fail "start-rlcr-loop completeness" "At least 4 instruction elements" "Found $INSTRUCTION_ELEMENTS"
    fi
fi

# Test 16: cancel-rlcr-loop skill has complete instructions
echo ""
echo "Test 16: cancel-rlcr-loop skill has complete instructions"
if [[ -f "$CANCEL_SKILL" ]]; then
    INSTRUCTION_ELEMENTS=0
    # Check for key instruction elements
    grep -q "\.humanize/rlcr" "$CANCEL_SKILL" && INSTRUCTION_ELEMENTS=$((INSTRUCTION_ELEMENTS + 1))
    grep -q "state.md" "$CANCEL_SKILL" && INSTRUCTION_ELEMENTS=$((INSTRUCTION_ELEMENTS + 1))
    grep -q "cancel-state.md" "$CANCEL_SKILL" && INSTRUCTION_ELEMENTS=$((INSTRUCTION_ELEMENTS + 1))
    grep -q "AskUserQuestion" "$CANCEL_SKILL" && INSTRUCTION_ELEMENTS=$((INSTRUCTION_ELEMENTS + 1))

    if [[ $INSTRUCTION_ELEMENTS -ge 4 ]]; then
        pass "cancel-rlcr-loop skill has complete instructions ($INSTRUCTION_ELEMENTS elements)"
    else
        fail "cancel-rlcr-loop completeness" "At least 4 instruction elements" "Found $INSTRUCTION_ELEMENTS"
    fi
fi

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
    echo -e "${GREEN}All skill invocation tests passed!${NC}"
    exit 0
else
    echo ""
    echo -e "${RED}Some skill invocation tests failed!${NC}"
    exit 1
fi
