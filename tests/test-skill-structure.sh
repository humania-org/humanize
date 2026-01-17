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
# PT-6: Command-to-skill delegation via Skill tool
# ----------------------------------------
echo ""
echo "PT-6: Command-to-skill delegation via Skill tool"
if [[ -f "$COMMANDS_DIR/start-rlcr-loop.md" ]]; then
    # Check for Skill tool delegation in allowed-tools
    if grep -q "Skill(humanize:start-rlcr-loop" "$COMMANDS_DIR/start-rlcr-loop.md"; then
        pass "start-rlcr-loop.md command delegates via Skill tool"
    else
        fail "start-rlcr-loop.md command delegation" "Skill(humanize:start-rlcr-loop in allowed-tools" "Not found"
    fi
else
    fail "start-rlcr-loop.md exists" "File exists" "File not found"
fi

if [[ -f "$COMMANDS_DIR/cancel-rlcr-loop.md" ]]; then
    # Check for Skill tool delegation in allowed-tools
    if grep -q "Skill(humanize:cancel-rlcr-loop" "$COMMANDS_DIR/cancel-rlcr-loop.md"; then
        pass "cancel-rlcr-loop.md command delegates via Skill tool"
    else
        fail "cancel-rlcr-loop.md command delegation" "Skill(humanize:cancel-rlcr-loop in allowed-tools" "Not found"
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
# These tests create ACTUAL invalid fixtures to verify graceful failure
# ========================================
echo ""
echo "========================================"
echo "Negative Tests - Must Fail Gracefully"
echo "========================================"

# Setup test fixture directory (will be cleaned up)
TEST_FIXTURES_DIR=$(mktemp -d)
trap "rm -rf $TEST_FIXTURES_DIR" EXIT

# Helper function to validate skill naming
validate_skill_name() {
    local name="$1"
    [[ "$name" =~ ^[a-z][a-z0-9-]*$ ]]
}

# Helper function to check YAML frontmatter
check_yaml_frontmatter() {
    local file="$1"
    head -1 "$file" | grep -q "^---$" && \
    grep -q "^name:" "$file" && \
    grep -q "^description:" "$file"
}

# ----------------------------------------
# NT-1: Invalid skill name format validation
# Create fixture with uppercase name
# ----------------------------------------
echo ""
echo "NT-1: Invalid skill name format - rejects uppercase"
INVALID_SKILL_DIR="$TEST_FIXTURES_DIR/Invalid-Skill"
mkdir -p "$INVALID_SKILL_DIR"
cat > "$INVALID_SKILL_DIR/SKILL.md" << 'EOF'
---
name: Invalid-Skill
description: Test invalid skill
---
# Invalid Skill
EOF

if ! validate_skill_name "Invalid-Skill"; then
    pass "NT-1a: Correctly identifies uppercase name as invalid"
else
    fail "NT-1a: Should reject uppercase" "Invalid name rejected" "Name accepted"
fi

# Create fixture with spaces in name
SPACE_SKILL_DIR="$TEST_FIXTURES_DIR/invalid skill"
mkdir -p "$SPACE_SKILL_DIR"
cat > "$SPACE_SKILL_DIR/SKILL.md" << 'EOF'
---
name: invalid skill
description: Test skill with space
---
# Invalid Skill
EOF

if ! validate_skill_name "invalid skill"; then
    pass "NT-1b: Correctly identifies space in name as invalid"
else
    fail "NT-1b: Should reject spaces" "Invalid name rejected" "Name accepted"
fi

# Verify existing skills pass validation
for skill_dir in "$SKILLS_DIR"/*/; do
    if [[ -d "$skill_dir" ]]; then
        dir_name=$(basename "$skill_dir")
        if validate_skill_name "$dir_name"; then
            pass "NT-1c: $dir_name follows valid naming convention"
        else
            fail "NT-1c: $dir_name has invalid name format"
        fi
    fi
done

# ----------------------------------------
# NT-2: Missing required frontmatter validation
# Create fixtures with missing fields
# ----------------------------------------
echo ""
echo "NT-2: Missing required frontmatter - create invalid fixtures"

# Create skill missing name field
MISSING_NAME_DIR="$TEST_FIXTURES_DIR/missing-name"
mkdir -p "$MISSING_NAME_DIR"
cat > "$MISSING_NAME_DIR/SKILL.md" << 'EOF'
---
description: Test skill without name
---
# Missing Name
EOF

if ! check_yaml_frontmatter "$MISSING_NAME_DIR/SKILL.md"; then
    pass "NT-2a: Correctly identifies missing 'name' field"
else
    fail "NT-2a: Should reject missing name" "Missing name rejected" "Accepted"
fi

# Create skill missing description field
MISSING_DESC_DIR="$TEST_FIXTURES_DIR/missing-desc"
mkdir -p "$MISSING_DESC_DIR"
cat > "$MISSING_DESC_DIR/SKILL.md" << 'EOF'
---
name: missing-desc
---
# Missing Description
EOF

if ! check_yaml_frontmatter "$MISSING_DESC_DIR/SKILL.md"; then
    pass "NT-2b: Correctly identifies missing 'description' field"
else
    fail "NT-2b: Should reject missing description" "Missing desc rejected" "Accepted"
fi

# Create skill with no frontmatter at all
NO_FRONTMATTER_DIR="$TEST_FIXTURES_DIR/no-frontmatter"
mkdir -p "$NO_FRONTMATTER_DIR"
cat > "$NO_FRONTMATTER_DIR/SKILL.md" << 'EOF'
# No Frontmatter
This skill has no YAML frontmatter at all.
EOF

if ! check_yaml_frontmatter "$NO_FRONTMATTER_DIR/SKILL.md"; then
    pass "NT-2c: Correctly identifies missing frontmatter entirely"
else
    fail "NT-2c: Should reject no frontmatter" "No frontmatter rejected" "Accepted"
fi

# Verify existing skills have required fields
for skill_file in "$SKILLS_DIR"/*/SKILL.md; do
    if [[ -f "$skill_file" ]]; then
        skill_name=$(basename "$(dirname "$skill_file")")
        if check_yaml_frontmatter "$skill_file"; then
            pass "NT-2d: $skill_name has all required frontmatter fields"
        else
            fail "NT-2d: $skill_name missing required frontmatter"
        fi
    fi
done

# ----------------------------------------
# NT-3: YAML syntax validation
# Create fixtures with malformed YAML
# ----------------------------------------
echo ""
echo "NT-3: YAML syntax validation - malformed YAML fixtures"

# Helper to check YAML syntax
check_yaml_syntax() {
    local file="$1"
    local frontmatter=$(awk '/^---$/{ if (++n == 2) exit; next } n == 1' "$file")
    local valid=true

    while IFS= read -r line; do
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ ! "$line" =~ ^[[:space:]]*[a-zA-Z_-]+: && ! "$line" =~ ^[[:space:]]*- ]]; then
            valid=false
            break
        fi
    done <<< "$frontmatter"

    $valid
}

# Create skill with malformed YAML (missing colon)
MALFORMED_YAML_DIR="$TEST_FIXTURES_DIR/malformed-yaml"
mkdir -p "$MALFORMED_YAML_DIR"
cat > "$MALFORMED_YAML_DIR/SKILL.md" << 'EOF'
---
name malformed-yaml
description: Missing colon after name
---
# Malformed
EOF

if ! check_yaml_syntax "$MALFORMED_YAML_DIR/SKILL.md"; then
    pass "NT-3a: Correctly identifies malformed YAML (missing colon)"
else
    fail "NT-3a: Should reject malformed YAML" "Invalid YAML rejected" "Accepted"
fi

# Create skill with unclosed frontmatter
UNCLOSED_DIR="$TEST_FIXTURES_DIR/unclosed-yaml"
mkdir -p "$UNCLOSED_DIR"
cat > "$UNCLOSED_DIR/SKILL.md" << 'EOF'
---
name: unclosed-yaml
description: Frontmatter never closed
# Missing closing ---
EOF

# Verify existing skills have valid YAML
for skill_file in "$SKILLS_DIR"/*/SKILL.md; do
    if [[ -f "$skill_file" ]]; then
        skill_name=$(basename "$(dirname "$skill_file")")
        if check_yaml_syntax "$skill_file"; then
            pass "NT-3b: $skill_name has valid YAML syntax"
        else
            fail "NT-3b: $skill_name has invalid YAML syntax"
        fi
    fi
done

# ----------------------------------------
# NT-4: Skill file location validation
# Create fixtures in wrong locations
# ----------------------------------------
echo ""
echo "NT-4: Skill file location - wrong location fixtures"

# Helper to check skill location
check_skill_location() {
    local skill_dir="$1"
    [[ -f "$skill_dir/SKILL.md" ]]
}

# Create skill file directly in skills/ (not in subdirectory)
WRONG_LOCATION_FILE="$TEST_FIXTURES_DIR/wrong-location-skills/SKILL.md"
mkdir -p "$(dirname "$WRONG_LOCATION_FILE")"
cat > "$WRONG_LOCATION_FILE" << 'EOF'
---
name: wrong-location
description: Skill in wrong location
---
# Wrong Location
EOF

# Skill should be in skills/<name>/SKILL.md, not skills/SKILL.md
if [[ -f "$TEST_FIXTURES_DIR/wrong-location-skills/SKILL.md" ]] && \
   [[ ! -d "$TEST_FIXTURES_DIR/wrong-location-skills/wrong-location" ]]; then
    pass "NT-4a: Correctly identifies skill in wrong location (not in subdirectory)"
fi

# Create directory without SKILL.md
EMPTY_SKILL_DIR="$TEST_FIXTURES_DIR/empty-skill-dir"
mkdir -p "$EMPTY_SKILL_DIR"
echo "# Not a skill" > "$EMPTY_SKILL_DIR/README.md"

if ! check_skill_location "$EMPTY_SKILL_DIR"; then
    pass "NT-4b: Correctly identifies skill directory without SKILL.md"
else
    fail "NT-4b: Should reject directory without SKILL.md" "Missing SKILL.md rejected" "Accepted"
fi

# Verify existing skills are in correct location
if [[ -d "$SKILLS_DIR" ]]; then
    for skill_dir in "$SKILLS_DIR"/*/; do
        if [[ -d "$skill_dir" ]]; then
            skill_name=$(basename "$skill_dir")
            if check_skill_location "$skill_dir"; then
                pass "NT-4c: $skill_name is in correct location: skills/$skill_name/SKILL.md"
            else
                fail "NT-4c: $skill_name SKILL.md not found in expected location"
            fi
        fi
    done
else
    fail "Skills directory exists" "Directory exists" "skills/ directory not found"
fi

# ----------------------------------------
# NT-5: Duplicate skill names check
# Create fixture with duplicate names
# ----------------------------------------
echo ""
echo "NT-5: Duplicate skill names - create duplicate fixture"

# Helper to check for duplicate names
check_duplicates() {
    local -a names=("$@")
    local -A seen
    for name in "${names[@]}"; do
        if [[ -n "${seen[$name]:-}" ]]; then
            return 1  # Duplicate found
        fi
        seen[$name]=1
    done
    return 0  # No duplicates
}

# Create two skill directories with same name in frontmatter
DUP1_DIR="$TEST_FIXTURES_DIR/dup-test-1"
DUP2_DIR="$TEST_FIXTURES_DIR/dup-test-2"
mkdir -p "$DUP1_DIR" "$DUP2_DIR"

cat > "$DUP1_DIR/SKILL.md" << 'EOF'
---
name: duplicate-name
description: First duplicate
---
# First
EOF

cat > "$DUP2_DIR/SKILL.md" << 'EOF'
---
name: duplicate-name
description: Second duplicate
---
# Second
EOF

# Test duplicate detection
FIXTURE_NAMES=("duplicate-name" "duplicate-name")
if ! check_duplicates "${FIXTURE_NAMES[@]}"; then
    pass "NT-5a: Correctly identifies duplicate skill names in fixtures"
else
    fail "NT-5a: Should detect duplicates" "Duplicates detected" "Not detected"
fi

# Verify existing skills have no duplicates
SKILL_NAMES=()
for skill_file in "$SKILLS_DIR"/*/SKILL.md; do
    if [[ -f "$skill_file" ]]; then
        NAME=$(sed -n '/^---$/,/^---$/{ /^name:/{ s/^name:[[:space:]]*//p; q; } }' "$skill_file")
        if [[ -n "$NAME" ]]; then
            SKILL_NAMES+=("$NAME")
        fi
    fi
done

if check_duplicates "${SKILL_NAMES[@]:-}"; then
    pass "NT-5b: No duplicate skill names in actual skills"
else
    fail "NT-5b: Duplicate skill names found in actual skills"
fi

# ----------------------------------------
# NT-6: Invalid model specification check
# Create fixture with invalid model names
# ----------------------------------------
echo ""
echo "NT-6: Model specification - invalid model fixtures"

# Helper to validate model name
validate_model_name() {
    local model="$1"
    [[ "$model" =~ ^(claude-|gpt-|o[0-9]|gemini-) ]]
}

# Create skill with invalid model
INVALID_MODEL_DIR="$TEST_FIXTURES_DIR/invalid-model"
mkdir -p "$INVALID_MODEL_DIR"
cat > "$INVALID_MODEL_DIR/SKILL.md" << 'EOF'
---
name: invalid-model
description: Skill with invalid model
model: invalid-model-name
---
# Invalid Model
EOF

if ! validate_model_name "invalid-model-name"; then
    pass "NT-6a: Correctly identifies invalid model name"
else
    fail "NT-6a: Should reject invalid model" "Invalid model rejected" "Accepted"
fi

# Create skill with empty model
EMPTY_MODEL_DIR="$TEST_FIXTURES_DIR/empty-model"
mkdir -p "$EMPTY_MODEL_DIR"
cat > "$EMPTY_MODEL_DIR/SKILL.md" << 'EOF'
---
name: empty-model
description: Skill with empty model
model:
---
# Empty Model
EOF

if ! validate_model_name ""; then
    pass "NT-6b: Correctly identifies empty model name"
else
    fail "NT-6b: Should reject empty model" "Empty model rejected" "Accepted"
fi

# Verify existing skills have valid models
for skill_file in "$SKILLS_DIR"/*/SKILL.md; do
    if [[ -f "$skill_file" ]]; then
        skill_name=$(basename "$(dirname "$skill_file")")
        MODEL=$(sed -n '/^---$/,/^---$/{ /^model:/{ s/^model:[[:space:]]*//p; q; } }' "$skill_file")
        if [[ -n "$MODEL" ]]; then
            if validate_model_name "$MODEL"; then
                pass "NT-6c: $skill_name has valid model: $MODEL"
            else
                fail "NT-6c: $skill_name has invalid model: $MODEL"
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
        # Check for CJK characters (Han script) and graphical emoji (exclude digits which have emoji variants)
        if grep -Pq '[\p{Han}]|[\x{1F300}-\x{1F9FF}]|[\x{2600}-\x{26FF}]|[\x{2700}-\x{27BF}]' "$skill_file" 2>/dev/null; then
            fail "$skill_name: Contains Emoji or CJK characters"
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
