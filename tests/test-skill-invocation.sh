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

# Test 3: start-rlcr-loop command delegates via Skill tool
echo ""
echo "Test 3: start-rlcr-loop command delegates via Skill tool"
START_CMD="$COMMANDS_DIR/start-rlcr-loop.md"
if [[ -f "$START_CMD" ]]; then
    # Check for Skill tool delegation in allowed-tools
    if grep -q "Skill(humanize:start-rlcr-loop" "$START_CMD"; then
        pass "start-rlcr-loop command uses Skill tool for delegation"
    else
        fail "start-rlcr-loop Skill tool delegation" "Skill(humanize:start-rlcr-loop" "Not found in allowed-tools"
    fi
else
    fail "start-rlcr-loop command exists" "File exists" "File not found"
fi

# Test 4: cancel-rlcr-loop command delegates via Skill tool
echo ""
echo "Test 4: cancel-rlcr-loop command delegates via Skill tool"
CANCEL_CMD="$COMMANDS_DIR/cancel-rlcr-loop.md"
if [[ -f "$CANCEL_CMD" ]]; then
    # Check for Skill tool delegation in allowed-tools
    if grep -q "Skill(humanize:cancel-rlcr-loop" "$CANCEL_CMD"; then
        pass "cancel-rlcr-loop command uses Skill tool for delegation"
    else
        fail "cancel-rlcr-loop Skill tool delegation" "Skill(humanize:cancel-rlcr-loop" "Not found in allowed-tools"
    fi
else
    fail "cancel-rlcr-loop command exists" "File exists" "File not found"
fi

# Test 5: start-rlcr-loop command is a thin wrapper (no full instructions)
echo ""
echo "Test 5: start-rlcr-loop command is thin wrapper"
if [[ -f "$START_SKILL" ]] && [[ -f "$START_CMD" ]]; then
    # Skill should have the full instructions (setup script reference)
    # Command should NOT have the setup script (it delegates to skill)
    SKILL_HAS_SCRIPT=0
    grep -q "setup-rlcr-loop.sh" "$START_SKILL" && SKILL_HAS_SCRIPT=1
    CMD_HAS_SCRIPT=0
    grep -q "setup-rlcr-loop.sh" "$START_CMD" && CMD_HAS_SCRIPT=1
    # Command should be significantly smaller than skill
    CMD_LINES=$(wc -l < "$START_CMD")
    SKILL_LINES=$(wc -l < "$START_SKILL")

    if [[ $SKILL_HAS_SCRIPT -eq 1 ]] && [[ $CMD_HAS_SCRIPT -eq 0 ]] && [[ $CMD_LINES -lt 20 ]]; then
        pass "start-rlcr-loop command is thin wrapper (skill has script, command delegates, cmd=${CMD_LINES} lines)"
    else
        fail "start-rlcr-loop thin wrapper" "Command delegates, skill has instructions" "cmd_has_script=$CMD_HAS_SCRIPT, cmd_lines=$CMD_LINES"
    fi
fi

# Test 6: cancel-rlcr-loop command is a thin wrapper (no full instructions)
echo ""
echo "Test 6: cancel-rlcr-loop command is thin wrapper"
if [[ -f "$CANCEL_SKILL" ]] && [[ -f "$CANCEL_CMD" ]]; then
    # Skill should have full cancel instructions (.humanize/rlcr references)
    # Command should NOT have them (it delegates to skill)
    SKILL_HAS_LOOP=0
    grep -q "\.humanize/rlcr" "$CANCEL_SKILL" && SKILL_HAS_LOOP=1
    CMD_HAS_LOOP=0
    grep -q "\.humanize/rlcr" "$CANCEL_CMD" && CMD_HAS_LOOP=1
    CMD_LINES=$(wc -l < "$CANCEL_CMD")

    if [[ $SKILL_HAS_LOOP -eq 1 ]] && [[ $CMD_HAS_LOOP -eq 0 ]] && [[ $CMD_LINES -lt 20 ]]; then
        pass "cancel-rlcr-loop command is thin wrapper (skill has instructions, command delegates, cmd=${CMD_LINES} lines)"
    else
        fail "cancel-rlcr-loop thin wrapper" "Command delegates, skill has instructions" "cmd_has_loop=$CMD_HAS_LOOP, cmd_lines=$CMD_LINES"
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

# Test 9: Command delegates via Skill tool, skill has appropriate tools
echo ""
echo "Test 9: start-rlcr-loop delegation pattern correct"
if [[ -f "$START_SKILL" ]] && [[ -f "$START_CMD" ]]; then
    # Command should use Skill tool for delegation
    CMD_TOOLS=$(grep "allowed-tools" "$START_CMD" | head -1)
    # Skill should have the actual execution tools (setup script)
    SKILL_TOOLS=$(grep -A5 "^allowed-tools:" "$START_SKILL" | head -6)

    # Command delegates via Skill, skill has actual tools
    CMD_HAS_SKILL_TOOL=$(echo "$CMD_TOOLS" | grep -c "Skill(" || echo "0")
    SKILL_HAS_BASH=$(echo "$SKILL_TOOLS" | grep -c "Bash\|setup-rlcr-loop.sh" || echo "0")

    if [[ $CMD_HAS_SKILL_TOOL -gt 0 ]] && [[ $SKILL_HAS_BASH -gt 0 ]]; then
        pass "start-rlcr-loop: command uses Skill tool, skill has execution tools"
    else
        fail "start-rlcr-loop delegation pattern" "Command uses Skill, skill has Bash" "cmd_skill=$CMD_HAS_SKILL_TOOL, skill_bash=$SKILL_HAS_BASH"
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
