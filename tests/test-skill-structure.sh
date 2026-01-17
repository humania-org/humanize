#!/bin/bash
#
# Test script for skill structure validation
#
# Validates that skills exist in proper structure with valid YAML frontmatter.
# Tests both positive (must pass) and negative (must fail gracefully) scenarios.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SKILLS_DIR="$PROJECT_ROOT/skills"
COMMANDS_DIR="$PROJECT_ROOT/commands"

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
echo "Testing Skill Structure Validation"
echo "========================================"
echo ""

# ========================================
# Positive Tests (PT-1 to PT-9)
# ========================================
echo "========================================"
echo "Positive Tests - Must Pass"
echo "========================================"

# ----------------------------------------
# PT-1: Skill file structure validation
# ----------------------------------------
echo ""
echo "PT-1: Skill file structure validation"
SKILL_COUNT=0
for skill_dir in "$SKILLS_DIR"/*/; do
    if [[ -d "$skill_dir" ]]; then
        skill_name=$(basename "$skill_dir")
        skill_file="$skill_dir/SKILL.md"
        if [[ -f "$skill_file" ]]; then
            SKILL_COUNT=$((SKILL_COUNT + 1))
        fi
    fi
done

if [[ $SKILL_COUNT -ge 2 ]]; then
    pass "Found $SKILL_COUNT skills with valid SKILL.md files"
else
    fail "Skill file structure" "At least 2 skills with SKILL.md" "Found $SKILL_COUNT"
fi

# ----------------------------------------
# PT-2: Skill name validation (start-rlcr-loop)
# ----------------------------------------
echo ""
echo "PT-2: Skill name validation - start-rlcr-loop"
START_SKILL="$SKILLS_DIR/start-rlcr-loop/SKILL.md"
if [[ -f "$START_SKILL" ]]; then
    # Extract name field from YAML frontmatter (between first --- and second ---)
    NAME=$(sed -n '/^---$/,/^---$/{ /^name:/{ s/^name:[[:space:]]*//p; q; } }' "$START_SKILL")
    if [[ "$NAME" == "start-rlcr-loop" ]]; then
        pass "start-rlcr-loop skill has correct name field"
    else
        fail "start-rlcr-loop name validation" "start-rlcr-loop" "$NAME"
    fi
else
    fail "start-rlcr-loop skill exists" "File exists" "File not found"
fi

# ----------------------------------------
# PT-2b: Skill name validation (cancel-rlcr-loop)
# ----------------------------------------
echo ""
echo "PT-2b: Skill name validation - cancel-rlcr-loop"
CANCEL_SKILL="$SKILLS_DIR/cancel-rlcr-loop/SKILL.md"
if [[ -f "$CANCEL_SKILL" ]]; then
    NAME=$(sed -n '/^---$/,/^---$/{ /^name:/{ s/^name:[[:space:]]*//p; q; } }' "$CANCEL_SKILL")
    if [[ "$NAME" == "cancel-rlcr-loop" ]]; then
        pass "cancel-rlcr-loop skill has correct name field"
    else
        fail "cancel-rlcr-loop name validation" "cancel-rlcr-loop" "$NAME"
    fi
else
    fail "cancel-rlcr-loop skill exists" "File exists" "File not found"
fi

# ----------------------------------------
# PT-3: Skill description validation
# ----------------------------------------
echo ""
echo "PT-3: Skill description validation"
for skill_file in "$SKILLS_DIR"/*/SKILL.md; do
    if [[ -f "$skill_file" ]]; then
        skill_name=$(basename "$(dirname "$skill_file")")
        DESC=$(sed -n '/^---$/,/^---$/{ /^description:/{ s/^description:[[:space:]]*//p; q; } }' "$skill_file")
        if [[ -n "$DESC" ]]; then
            pass "$skill_name has description: ${DESC:0:50}..."
        else
            fail "$skill_name description validation" "Non-empty description" "(empty)"
        fi
    fi
done

# ----------------------------------------
# PT-4: No context fork in v1.2.3
# ----------------------------------------
echo ""
echo "PT-4: No context:fork in v1.2.3"
CONTEXT_FORK_FOUND=false
for skill_file in "$SKILLS_DIR"/*/SKILL.md; do
    if [[ -f "$skill_file" ]]; then
        skill_name=$(basename "$(dirname "$skill_file")")
        if grep -q "^context:[[:space:]]*fork" "$skill_file"; then
            CONTEXT_FORK_FOUND=true
            fail "$skill_name has context:fork (not allowed in v1.2.3)"
        fi
    fi
done
if [[ "$CONTEXT_FORK_FOUND" == "false" ]]; then
    pass "No skills have context:fork (correct for v1.2.3)"
fi

# ----------------------------------------
# PT-5: Model specification validation
# ----------------------------------------
echo ""
echo "PT-5: Model specification validation"
for skill_file in "$SKILLS_DIR"/*/SKILL.md; do
    if [[ -f "$skill_file" ]]; then
        skill_name=$(basename "$(dirname "$skill_file")")
        MODEL=$(sed -n '/^---$/,/^---$/{ /^model:/{ s/^model:[[:space:]]*//p; q; } }' "$skill_file")
        if [[ -n "$MODEL" ]]; then
            pass "$skill_name has model specification: $MODEL"
        else
            fail "$skill_name model validation" "Model specification present" "(empty)"
        fi
    fi
done

# ----------------------------------------
# PT-6: Command-to-skill delegation
# ----------------------------------------
echo ""
echo "PT-6: Command-to-skill delegation"
if [[ -f "$COMMANDS_DIR/start-rlcr-loop.md" ]]; then
    if grep -q "Command wrapper.*delegates to.*skills/start-rlcr-loop" "$COMMANDS_DIR/start-rlcr-loop.md"; then
        pass "start-rlcr-loop.md command references skill"
    else
        fail "start-rlcr-loop.md command delegation" "Reference to skill" "No reference found"
    fi
else
    fail "start-rlcr-loop.md exists" "File exists" "File not found"
fi

if [[ -f "$COMMANDS_DIR/cancel-rlcr-loop.md" ]]; then
    if grep -q "Command wrapper.*delegates to.*skills/cancel-rlcr-loop" "$COMMANDS_DIR/cancel-rlcr-loop.md"; then
        pass "cancel-rlcr-loop.md command references skill"
    else
        fail "cancel-rlcr-loop.md command delegation" "Reference to skill" "No reference found"
    fi
else
    fail "cancel-rlcr-loop.md exists" "File exists" "File not found"
fi

# ----------------------------------------
# PT-7: Allowed tools validation
# ----------------------------------------
echo ""
echo "PT-7: Allowed tools validation"
for skill_file in "$SKILLS_DIR"/*/SKILL.md; do
    if [[ -f "$skill_file" ]]; then
        skill_name=$(basename "$(dirname "$skill_file")")
        # Check if allowed-tools exists (can be multi-line YAML list)
        if grep -q "^allowed-tools:" "$skill_file"; then
            pass "$skill_name has allowed-tools specification"
        else
            fail "$skill_name allowed-tools validation" "allowed-tools present" "Not found"
        fi
    fi
done

# ----------------------------------------
# PT-8: User-invocable validation (default is true)
# ----------------------------------------
echo ""
echo "PT-8: User-invocable validation"
for skill_file in "$SKILLS_DIR"/*/SKILL.md; do
    if [[ -f "$skill_file" ]]; then
        skill_name=$(basename "$(dirname "$skill_file")")
        # If user-invocable is not specified, it defaults to true (which is what we want)
        if grep -q "^user-invocable:[[:space:]]*false" "$skill_file"; then
            fail "$skill_name should be user-invocable" "user-invocable: true or not specified" "user-invocable: false"
        else
            pass "$skill_name is user-invocable (default or explicit)"
        fi
    fi
done

# ----------------------------------------
# PT-9: Version consistency check
# ----------------------------------------
echo ""
echo "PT-9: Version consistency check"
PLUGIN_JSON="$PROJECT_ROOT/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$PROJECT_ROOT/.claude-plugin/marketplace.json"
README_MD="$PROJECT_ROOT/README.md"

if [[ -f "$PLUGIN_JSON" ]] && [[ -f "$MARKETPLACE_JSON" ]] && [[ -f "$README_MD" ]]; then
    PLUGIN_VER=$(grep -o '"version":[[:space:]]*"[^"]*"' "$PLUGIN_JSON" | grep -o '"[^"]*"$' | tr -d '"')
    MARKETPLACE_VER=$(grep -o '"version":[[:space:]]*"[^"]*"' "$MARKETPLACE_JSON" | grep -o '"[^"]*"$' | tr -d '"')
    README_VER=$(grep -o 'Current Version:[[:space:]]*[0-9.]*' "$README_MD" | grep -o '[0-9.]*$')

    if [[ "$PLUGIN_VER" == "$MARKETPLACE_VER" ]] && [[ "$PLUGIN_VER" == "$README_VER" ]]; then
        pass "Version is consistent across all files: $PLUGIN_VER"
    else
        fail "Version consistency" "All files have same version" "plugin.json=$PLUGIN_VER, marketplace.json=$MARKETPLACE_VER, README.md=$README_VER"
    fi
else
    fail "Version files exist" "All version files exist" "Some files missing"
fi

# ========================================
# Negative Tests (NT-1 to NT-6)
# ========================================
echo ""
echo "========================================"
echo "Negative Tests - Must Fail Gracefully"
echo "========================================"

# ----------------------------------------
# NT-1: Invalid skill name format validation
# ----------------------------------------
echo ""
echo "NT-1: Invalid skill name format validation"
# All skill names should be lowercase with hyphens only
INVALID_NAME_FOUND=false
for skill_dir in "$SKILLS_DIR"/*/; do
    if [[ -d "$skill_dir" ]]; then
        dir_name=$(basename "$skill_dir")
        # Check for uppercase, spaces, or special characters (allow only lowercase and hyphens)
        if [[ ! "$dir_name" =~ ^[a-z][a-z0-9-]*$ ]]; then
            INVALID_NAME_FOUND=true
            fail "Skill directory name invalid: $dir_name"
        fi
    fi
done
if [[ "$INVALID_NAME_FOUND" == "false" ]]; then
    pass "All skill directory names follow lowercase-hyphen convention"
fi

# ----------------------------------------
# NT-2: Missing required frontmatter validation
# ----------------------------------------
echo ""
echo "NT-2: Required frontmatter fields validation"
for skill_file in "$SKILLS_DIR"/*/SKILL.md; do
    if [[ -f "$skill_file" ]]; then
        skill_name=$(basename "$(dirname "$skill_file")")
        # Check that file starts with ---
        if ! head -1 "$skill_file" | grep -q "^---$"; then
            fail "$skill_name: Missing YAML frontmatter start"
            continue
        fi

        # Check for name field
        if ! grep -q "^name:" "$skill_file"; then
            fail "$skill_name: Missing required 'name' field"
        else
            pass "$skill_name: Has required 'name' field"
        fi

        # Check for description field
        if ! grep -q "^description:" "$skill_file"; then
            fail "$skill_name: Missing required 'description' field"
        else
            pass "$skill_name: Has required 'description' field"
        fi
    fi
done

# ----------------------------------------
# NT-3: YAML syntax validation
# ----------------------------------------
echo ""
echo "NT-3: YAML syntax validation"
for skill_file in "$SKILLS_DIR"/*/SKILL.md; do
    if [[ -f "$skill_file" ]]; then
        skill_name=$(basename "$(dirname "$skill_file")")
        # Extract frontmatter between --- markers
        FRONTMATTER=$(awk '/^---$/{ if (++n == 2) exit; next } n == 1' "$skill_file")

        # Basic syntax checks - each line should be valid YAML
        VALID=true
        while IFS= read -r line; do
            # Skip empty lines and comments
            [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

            # Check for proper key: value or list item format
            if [[ ! "$line" =~ ^[[:space:]]*[a-zA-Z_-]+: && ! "$line" =~ ^[[:space:]]*- ]]; then
                VALID=false
                fail "$skill_name: Invalid YAML line: $line"
            fi
        done <<< "$FRONTMATTER"

        if [[ "$VALID" == "true" ]]; then
            pass "$skill_name: YAML frontmatter is syntactically valid"
        fi
    fi
done

# ----------------------------------------
# NT-4: Skill file location validation
# ----------------------------------------
echo ""
echo "NT-4: Skill file location validation"
# Verify skills are in correct directory structure
if [[ -d "$SKILLS_DIR" ]]; then
    for skill_dir in "$SKILLS_DIR"/*/; do
        if [[ -d "$skill_dir" ]]; then
            skill_name=$(basename "$skill_dir")
            if [[ -f "$skill_dir/SKILL.md" ]]; then
                pass "$skill_name is in correct location: skills/$skill_name/SKILL.md"
            else
                fail "$skill_name: SKILL.md not found in expected location"
            fi
        fi
    done
else
    fail "Skills directory exists" "Directory exists" "skills/ directory not found"
fi

# ----------------------------------------
# NT-5: Duplicate skill names check
# ----------------------------------------
echo ""
echo "NT-5: Duplicate skill names check"
SKILL_NAMES=()
DUPLICATES_FOUND=false
for skill_file in "$SKILLS_DIR"/*/SKILL.md; do
    if [[ -f "$skill_file" ]]; then
        NAME=$(sed -n '/^---$/,/^---$/{ /^name:/{ s/^name:[[:space:]]*//p; q; } }' "$skill_file")
        if [[ -n "$NAME" ]]; then
            if [[ " ${SKILL_NAMES[*]:-} " =~ " $NAME " ]]; then
                DUPLICATES_FOUND=true
                fail "Duplicate skill name found: $NAME"
            fi
            SKILL_NAMES+=("$NAME")
        fi
    fi
done
if [[ "$DUPLICATES_FOUND" == "false" ]]; then
    pass "No duplicate skill names found"
fi

# ----------------------------------------
# NT-6: Invalid model specification check
# ----------------------------------------
echo ""
echo "NT-6: Model specification format validation"
VALID_MODEL_PATTERNS="^(claude-|gpt-|o[0-9]|gemini-)"
for skill_file in "$SKILLS_DIR"/*/SKILL.md; do
    if [[ -f "$skill_file" ]]; then
        skill_name=$(basename "$(dirname "$skill_file")")
        MODEL=$(sed -n '/^---$/,/^---$/{ /^model:/{ s/^model:[[:space:]]*//p; q; } }' "$skill_file")
        if [[ -n "$MODEL" ]]; then
            # Check if model name follows expected patterns
            if [[ "$MODEL" =~ $VALID_MODEL_PATTERNS ]]; then
                pass "$skill_name: Model '$MODEL' follows valid naming pattern"
            else
                fail "$skill_name: Model '$MODEL' may not be valid" "Pattern: claude-*, gpt-*, o*, gemini-*" "$MODEL"
            fi
        fi
    fi
done

# ----------------------------------------
# Content validation: No Emoji or CJK
# ----------------------------------------
echo ""
echo "Content validation: No Emoji or CJK characters"
for skill_file in "$SKILLS_DIR"/*/SKILL.md; do
    if [[ -f "$skill_file" ]]; then
        skill_name=$(basename "$(dirname "$skill_file")")
        # Check for CJK characters (Unicode range) and common emoji patterns
        if grep -Pq '[\x{4E00}-\x{9FFF}\x{3000}-\x{303F}\x{1F300}-\x{1F9FF}]' "$skill_file" 2>/dev/null || \
           grep -q '[^\x00-\x7F]' "$skill_file" 2>/dev/null && \
           grep -Eq '[^\x00-\x7F\xC0-\xFF]' "$skill_file" 2>/dev/null; then
            # More specific check needed - simplified approach
            if grep -Pq '[\p{Han}\p{Emoji}]' "$skill_file" 2>/dev/null; then
                fail "$skill_name: Contains Emoji or CJK characters"
            else
                pass "$skill_name: Content is English only (basic ASCII)"
            fi
        else
            pass "$skill_name: Content is English only"
        fi
    fi
done

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
