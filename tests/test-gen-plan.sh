#!/bin/bash
#
# Test script for gen-plan command structure validation
#
# Validates that gen-plan command exists in proper structure with valid YAML frontmatter.
# Tests both positive (must pass) and negative (must fail gracefully) scenarios.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMANDS_DIR="$PROJECT_ROOT/commands"
AGENTS_DIR="$PROJECT_ROOT/agents"

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
echo "Testing gen-plan Command Structure"
echo "========================================"
echo ""

# ========================================
# Positive Tests (PT-1 to PT-9)
# ========================================
echo "========================================"
echo "Positive Tests - Must Pass"
echo "========================================"

# ----------------------------------------
# PT-1: Command file structure validation
# ----------------------------------------
echo ""
echo "PT-1: Command file structure validation"
GEN_PLAN_CMD="$COMMANDS_DIR/gen-plan.md"
if [[ -f "$GEN_PLAN_CMD" ]]; then
    pass "gen-plan.md command file exists"
else
    fail "gen-plan.md command file exists" "File exists" "File not found"
fi

# ----------------------------------------
# PT-2: Command description validation
# ----------------------------------------
echo ""
echo "PT-2: Command description validation"
if [[ -f "$GEN_PLAN_CMD" ]]; then
    DESC=$(sed -n '/^---$/,/^---$/{ /^description:/{ s/^description:[[:space:]]*//p; q; } }' "$GEN_PLAN_CMD")
    if [[ -n "$DESC" ]]; then
        pass "gen-plan.md has description: ${DESC:0:50}..."
    else
        fail "gen-plan.md description validation" "Non-empty description" "(empty)"
    fi
fi

# ----------------------------------------
# PT-3: Allowed tools validation
# ----------------------------------------
echo ""
echo "PT-3: Allowed tools validation"
if [[ -f "$GEN_PLAN_CMD" ]]; then
    if grep -q "allowed-tools:" "$GEN_PLAN_CMD"; then
        pass "gen-plan.md has allowed-tools specification"
    else
        fail "gen-plan.md allowed-tools validation" "allowed-tools present" "Not found"
    fi
fi

# ----------------------------------------
# PT-4: Argument hint validation
# ----------------------------------------
echo ""
echo "PT-4: Argument hint validation"
if [[ -f "$GEN_PLAN_CMD" ]]; then
    if grep -q "argument-hint:" "$GEN_PLAN_CMD"; then
        pass "gen-plan.md has argument-hint specification"
    else
        fail "gen-plan.md argument-hint validation" "argument-hint present" "Not found"
    fi
fi

# ----------------------------------------
# PT-5: Agent file structure validation
# ----------------------------------------
echo ""
echo "PT-5: Agent file structure validation"
RELEVANCE_AGENT="$AGENTS_DIR/draft-relevance-checker.md"
if [[ -f "$RELEVANCE_AGENT" ]]; then
    pass "draft-relevance-checker.md agent file exists"
else
    fail "draft-relevance-checker.md agent file exists" "File exists" "File not found"
fi

# ----------------------------------------
# PT-5b: Claude/Codex deliberation workflow validation
# ----------------------------------------
echo ""
echo "PT-5b: Claude/Codex deliberation workflow validation"
PLAN_TEMPLATE="$PROJECT_ROOT/prompt-template/plan/gen-plan-template.md"

if [[ -f "$GEN_PLAN_CMD" ]] && grep -q "scripts/ask-codex.sh" "$GEN_PLAN_CMD"; then
    pass "gen-plan command allows ask-codex script"
else
    fail "gen-plan command allows ask-codex script" "ask-codex script reference" "missing"
fi

if [[ -f "$GEN_PLAN_CMD" ]] && grep -q -- "--auto-start-rlcr-if-converged" "$GEN_PLAN_CMD"; then
    pass "gen-plan command exposes auto-start-if-converged option"
else
    fail "gen-plan command exposes auto-start-if-converged option" "--auto-start-rlcr-if-converged" "missing"
fi

if [[ -f "$GEN_PLAN_CMD" ]] && grep -n "GEN_PLAN_MODE=direct" "$GEN_PLAN_CMD" | grep -q "PLAN_CONVERGENCE_STATUS=partially_converged"; then
    pass "gen-plan direct mode does not mark plan as converged"
else
    fail "gen-plan direct mode does not mark plan as converged" "PLAN_CONVERGENCE_STATUS=partially_converged in direct-mode branch" "missing or still marked converged"
fi

if [[ -f "$GEN_PLAN_CMD" ]] && grep -n -A12 "Optional Direct Work Start" "$GEN_PLAN_CMD" | grep -q "GEN_PLAN_MODE=discussion"; then
    pass "gen-plan auto-start requires discussion mode"
else
    fail "gen-plan auto-start requires discussion mode" "GEN_PLAN_MODE=discussion in auto-start conditions" "missing"
fi

if [[ -f "$GEN_PLAN_CMD" ]] && grep -qi "ultrathink" "$GEN_PLAN_CMD"; then
    pass "gen-plan command requires ultrathink execution mode"
else
    fail "gen-plan command requires ultrathink execution mode" "ultrathink instruction" "missing"
fi

if [[ -f "$GEN_PLAN_CMD" ]] && grep -q "## Pending User Decisions" "$GEN_PLAN_CMD"; then
    pass "gen-plan command requires pending user decisions section"
else
    fail "gen-plan command requires pending user decisions section" "Pending User Decisions section" "missing"
fi

if [[ -f "$GEN_PLAN_CMD" ]] && grep -q "## Phase 3: Codex First-Pass Analysis" "$GEN_PLAN_CMD"; then
    pass "gen-plan command includes codex first-pass analysis phase"
else
    fail "gen-plan command includes codex first-pass analysis phase" "Phase 3 codex first-pass section" "missing"
fi

if [[ -f "$GEN_PLAN_CMD" ]] && grep -q "## Phase 5: Iterative Convergence Loop" "$GEN_PLAN_CMD"; then
    pass "gen-plan command includes iterative convergence loop phase"
else
    fail "gen-plan command includes iterative convergence loop phase" "Phase 5 convergence loop section" "missing"
fi

if [[ -f "$GEN_PLAN_CMD" ]] && grep -q "Maximum 3 rounds reached" "$GEN_PLAN_CMD"; then
    pass "gen-plan command defines convergence loop termination limit"
else
    fail "gen-plan command defines convergence loop termination limit" "Maximum 3 rounds reached" "missing"
fi

if [[ -f "$GEN_PLAN_CMD" ]]; then
    PHASE3_LINE=$(grep -n "## Phase 3: Codex First-Pass Analysis" "$GEN_PLAN_CMD" | head -1 | cut -d: -f1 || true)
    PHASE4_LINE=$(grep -n "## Phase 4: Claude Candidate Plan (v1)" "$GEN_PLAN_CMD" | head -1 | cut -d: -f1 || true)
    if [[ -n "$PHASE3_LINE" && -n "$PHASE4_LINE" && "$PHASE3_LINE" -lt "$PHASE4_LINE" ]]; then
        pass "gen-plan command orders codex analysis before claude candidate plan"
    else
        fail "gen-plan command orders codex analysis before claude candidate plan" "Phase 3 line < Phase 4 line" "phase3=$PHASE3_LINE phase4=$PHASE4_LINE"
    fi
fi

if [[ -f "$PLAN_TEMPLATE" ]] && grep -q "## Claude-Codex Deliberation" "$PLAN_TEMPLATE"; then
    pass "plan template includes Claude-Codex deliberation section"
else
    fail "plan template includes Claude-Codex deliberation section" "Claude-Codex Deliberation section" "missing"
fi

if [[ -f "$PLAN_TEMPLATE" ]] && grep -q "## Pending User Decisions" "$PLAN_TEMPLATE"; then
    pass "plan template includes pending user decisions section"
else
    fail "plan template includes pending user decisions section" "Pending User Decisions section" "missing"
fi

if [[ -f "$PLAN_TEMPLATE" ]] && ! grep -q "## Convergence Log" "$PLAN_TEMPLATE"; then
    pass "plan template does not include convergence log section"
else
    fail "plan template does not include convergence log section" "no Convergence Log section" "section still present"
fi

if [[ -f "$PLAN_TEMPLATE" ]] && ! grep -q "## Codex Team Workflow" "$PLAN_TEMPLATE"; then
    pass "plan template does not include codex team workflow section"
else
    fail "plan template does not include codex team workflow section" "no Codex Team Workflow section" "section still present"
fi

if [[ -f "$PLAN_TEMPLATE" ]] && grep -q "### Convergence Status" "$PLAN_TEMPLATE"; then
    pass "plan template includes convergence status subsection"
else
    fail "plan template includes convergence status subsection" "Convergence Status subsection" "missing"
fi

if [[ -f "$GEN_PLAN_CMD" ]] && grep -q "## Task Breakdown" "$GEN_PLAN_CMD"; then
    pass "gen-plan command requires task breakdown section"
else
    fail "gen-plan command requires task breakdown section" "Task Breakdown section" "missing"
fi

if [[ -f "$GEN_PLAN_CMD" ]] && grep -q "Task Tag Requirement" "$GEN_PLAN_CMD"; then
    pass "gen-plan command defines mandatory coding/analyze tags"
else
    fail "gen-plan command defines mandatory coding/analyze tags" "Task Tag Requirement rule" "missing"
fi

if [[ -f "$PLAN_TEMPLATE" ]] && grep -q "Tag (\`coding\`/\`analyze\`)" "$PLAN_TEMPLATE"; then
    pass "plan template includes coding/analyze task tag column"
else
    fail "plan template includes coding/analyze task tag column" "tag column in task table" "missing"
fi

# ----------------------------------------
# PT-6: Agent name validation
# ----------------------------------------
echo ""
echo "PT-6: Agent name validation"
if [[ -f "$RELEVANCE_AGENT" ]]; then
    NAME=$(sed -n '/^---$/,/^---$/{ /^name:/{ s/^name:[[:space:]]*//p; q; } }' "$RELEVANCE_AGENT")
    if [[ "$NAME" == "draft-relevance-checker" ]]; then
        pass "draft-relevance-checker agent has correct name field"
    else
        fail "draft-relevance-checker name validation" "draft-relevance-checker" "$NAME"
    fi
fi

# ----------------------------------------
# PT-7: Agent model specification validation
# ----------------------------------------
echo ""
echo "PT-7: Agent model specification validation"
if [[ -f "$RELEVANCE_AGENT" ]]; then
    MODEL=$(sed -n '/^---$/,/^---$/{ /^model:/{ s/^model:[[:space:]]*//p; q; } }' "$RELEVANCE_AGENT")
    if [[ "$MODEL" == "haiku" ]]; then
        pass "draft-relevance-checker agent uses haiku model"
    else
        fail "draft-relevance-checker model validation" "haiku" "$MODEL"
    fi
fi

# ----------------------------------------
# PT-8: Agent tools specification validation
# ----------------------------------------
echo ""
echo "PT-8: Agent tools specification validation"
if [[ -f "$RELEVANCE_AGENT" ]]; then
    if grep -q "^tools:" "$RELEVANCE_AGENT"; then
        pass "draft-relevance-checker agent has tools specification"
    else
        fail "draft-relevance-checker tools validation" "tools present" "Not found"
    fi
fi

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

# Helper function to validate command/agent naming
validate_name() {
    local name="$1"
    [[ "$name" =~ ^[a-z][a-z0-9-]*$ ]]
}

# Helper function to check YAML frontmatter
check_yaml_frontmatter() {
    local file="$1"
    head -1 "$file" | grep -q "^---$" && \
    grep -q "^description:" "$file"
}

# Helper function to check agent YAML frontmatter
check_agent_yaml_frontmatter() {
    local file="$1"
    head -1 "$file" | grep -q "^---$" && \
    grep -q "^name:" "$file" && \
    grep -q "^description:" "$file"
}

# ----------------------------------------
# NT-1: Invalid name format validation
# ----------------------------------------
echo ""
echo "NT-1: Invalid name format - rejects uppercase"

if ! validate_name "Invalid-Name"; then
    pass "NT-1a: Correctly identifies uppercase name as invalid"
else
    fail "NT-1a: Should reject uppercase" "Invalid name rejected" "Name accepted"
fi

if ! validate_name "invalid name"; then
    pass "NT-1b: Correctly identifies space in name as invalid"
else
    fail "NT-1b: Should reject spaces" "Invalid name rejected" "Name accepted"
fi

# Verify gen-plan follows valid naming convention
if validate_name "gen-plan"; then
    pass "NT-1c: gen-plan follows valid naming convention"
else
    fail "NT-1c: gen-plan has invalid name format"
fi

if validate_name "draft-relevance-checker"; then
    pass "NT-1d: draft-relevance-checker follows valid naming convention"
else
    fail "NT-1d: draft-relevance-checker has invalid name format"
fi

# ----------------------------------------
# NT-2: Missing required frontmatter validation
# ----------------------------------------
echo ""
echo "NT-2: Missing required frontmatter - create invalid fixtures"

# Create command missing description field
MISSING_DESC_DIR="$TEST_FIXTURES_DIR"
cat > "$MISSING_DESC_DIR/missing-desc.md" << 'EOF'
---
argument-hint: "--test"
---
# Missing Description
EOF

if ! check_yaml_frontmatter "$MISSING_DESC_DIR/missing-desc.md"; then
    pass "NT-2a: Correctly identifies missing 'description' field"
else
    fail "NT-2a: Should reject missing description" "Missing desc rejected" "Accepted"
fi

# Create file with no frontmatter at all
cat > "$MISSING_DESC_DIR/no-frontmatter.md" << 'EOF'
# No Frontmatter
This command has no YAML frontmatter at all.
EOF

if ! check_yaml_frontmatter "$MISSING_DESC_DIR/no-frontmatter.md"; then
    pass "NT-2b: Correctly identifies missing frontmatter entirely"
else
    fail "NT-2b: Should reject no frontmatter" "No frontmatter rejected" "Accepted"
fi

# Verify gen-plan.md has required fields
if [[ -f "$GEN_PLAN_CMD" ]]; then
    if check_yaml_frontmatter "$GEN_PLAN_CMD"; then
        pass "NT-2c: gen-plan.md has all required frontmatter fields"
    else
        fail "NT-2c: gen-plan.md missing required frontmatter"
    fi
fi

# Verify agent has required fields
if [[ -f "$RELEVANCE_AGENT" ]]; then
    if check_agent_yaml_frontmatter "$RELEVANCE_AGENT"; then
        pass "NT-2d: draft-relevance-checker.md has all required frontmatter fields"
    else
        fail "NT-2d: draft-relevance-checker.md missing required frontmatter"
    fi
fi

# ----------------------------------------
# NT-3: YAML syntax validation
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
        if [[ ! "$line" =~ ^[[:space:]]*[a-zA-Z_-]+: && ! "$line" =~ ^[[:space:]]*- && ! "$line" =~ ^[[:space:]]*\" ]]; then
            valid=false
            break
        fi
    done <<< "$frontmatter"

    $valid
}

# Create file with malformed YAML (missing colon)
cat > "$TEST_FIXTURES_DIR/malformed-yaml.md" << 'EOF'
---
description malformed
---
# Malformed
EOF

if ! check_yaml_syntax "$TEST_FIXTURES_DIR/malformed-yaml.md"; then
    pass "NT-3a: Correctly identifies malformed YAML (missing colon)"
else
    fail "NT-3a: Should reject malformed YAML" "Invalid YAML rejected" "Accepted"
fi

# Verify gen-plan.md has valid YAML
if [[ -f "$GEN_PLAN_CMD" ]]; then
    if check_yaml_syntax "$GEN_PLAN_CMD"; then
        pass "NT-3b: gen-plan.md has valid YAML syntax"
    else
        fail "NT-3b: gen-plan.md has invalid YAML syntax"
    fi
fi

# ----------------------------------------
# NT-6: Invalid model specification check
# ----------------------------------------
echo ""
echo "NT-6: Model specification - invalid model fixtures"

# Helper to validate model name
# Accepts: short aliases (exact match) or full model IDs (prefix match)
validate_model_name() {
    local model="$1"
    # Exact match for short aliases
    [[ "$model" =~ ^(opus|sonnet|haiku)$ ]] || \
    # Prefix match for full model IDs
    [[ "$model" =~ ^(claude-|gpt-|o[0-9]|gemini-) ]]
}

if ! validate_model_name "invalid-model-name"; then
    pass "NT-6a: Correctly identifies invalid model name"
else
    fail "NT-6a: Should reject invalid model" "Invalid model rejected" "Accepted"
fi

if ! validate_model_name ""; then
    pass "NT-6b: Correctly identifies empty model name"
else
    fail "NT-6b: Should reject empty model" "Empty model rejected" "Accepted"
fi

# Test that short aliases require exact match (not prefix)
if ! validate_model_name "opus-v2"; then
    pass "NT-6d: Correctly rejects opus-v2 (partial match)"
else
    fail "NT-6d: Should reject opus-v2" "Rejected" "Accepted"
fi

if ! validate_model_name "haiku123"; then
    pass "NT-6e: Correctly rejects haiku123 (partial match)"
else
    fail "NT-6e: Should reject haiku123" "Rejected" "Accepted"
fi

if ! validate_model_name "sonnet-fast"; then
    pass "NT-6f: Correctly rejects sonnet-fast (partial match)"
else
    fail "NT-6f: Should reject sonnet-fast" "Rejected" "Accepted"
fi

# Verify agent has valid model
if [[ -f "$RELEVANCE_AGENT" ]]; then
    MODEL=$(sed -n '/^---$/,/^---$/{ /^model:/{ s/^model:[[:space:]]*//p; q; } }' "$RELEVANCE_AGENT")
    if [[ -n "$MODEL" ]]; then
        if validate_model_name "$MODEL"; then
            pass "NT-6c: draft-relevance-checker has valid model: $MODEL"
        else
            fail "NT-6c: draft-relevance-checker has invalid model: $MODEL"
        fi
    fi
fi

# ----------------------------------------
# Content validation: No Emoji or CJK
# ----------------------------------------
echo ""
echo "Content validation: No Emoji or CJK characters"

if [[ -f "$GEN_PLAN_CMD" ]]; then
    if grep -Pq '[\p{Han}]|[\x{1F300}-\x{1F9FF}]|[\x{2600}-\x{26FF}]|[\x{2700}-\x{27BF}]' "$GEN_PLAN_CMD" 2>/dev/null; then
        fail "gen-plan.md: Contains Emoji or CJK characters"
    else
        pass "gen-plan.md: Content is English only"
    fi
fi

if [[ -f "$RELEVANCE_AGENT" ]]; then
    if grep -Pq '[\p{Han}]|[\x{1F300}-\x{1F9FF}]|[\x{2600}-\x{26FF}]|[\x{2700}-\x{27BF}]' "$RELEVANCE_AGENT" 2>/dev/null; then
        fail "draft-relevance-checker.md: Contains Emoji or CJK characters"
    else
        pass "draft-relevance-checker.md: Content is English only"
    fi
fi

# ========================================
# Script Tests: validate-gen-plan-io.sh
# ========================================
echo ""
echo "Script Tests: validate-gen-plan-io.sh"

VALIDATE_SCRIPT="$PROJECT_ROOT/scripts/validate-gen-plan-io.sh"

if [[ -x "$VALIDATE_SCRIPT" ]]; then
    # Create temp directory for script tests
    SCRIPT_TEST_DIR=$(mktemp -d)
    trap "rm -rf $SCRIPT_TEST_DIR" EXIT

    # Test: --input without value should exit 6
    EXIT_CODE=0
    "$VALIDATE_SCRIPT" --input 2>/dev/null || EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 6 ]]; then
        pass "validate-gen-plan-io: --input without value exits 6"
    else
        fail "validate-gen-plan-io: --input without value should exit 6" "6" "$EXIT_CODE"
    fi

    # Test: --output without value should exit 6
    EXIT_CODE=0
    "$VALIDATE_SCRIPT" --output 2>/dev/null || EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 6 ]]; then
        pass "validate-gen-plan-io: --output without value exits 6"
    else
        fail "validate-gen-plan-io: --output without value should exit 6" "6" "$EXIT_CODE"
    fi

    # Test: --input followed by another flag should exit 6
    EXIT_CODE=0
    "$VALIDATE_SCRIPT" --input --output /tmp/out.md 2>/dev/null || EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 6 ]]; then
        pass "validate-gen-plan-io: --input followed by flag exits 6"
    else
        fail "validate-gen-plan-io: --input followed by flag should exit 6" "6" "$EXIT_CODE"
    fi

    # Test: Unknown option should exit 6
    EXIT_CODE=0
    "$VALIDATE_SCRIPT" --unknown-flag 2>/dev/null || EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 6 ]]; then
        pass "validate-gen-plan-io: unknown option exits 6"
    else
        fail "validate-gen-plan-io: unknown option should exit 6" "6" "$EXIT_CODE"
    fi

    # Test: Input file not found should exit 1
    EXIT_CODE=0
    "$VALIDATE_SCRIPT" --input "$SCRIPT_TEST_DIR/nonexistent.md" --output "$SCRIPT_TEST_DIR/out.md" 2>/dev/null || EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 1 ]]; then
        pass "validate-gen-plan-io: input not found exits 1"
    else
        fail "validate-gen-plan-io: input not found should exit 1" "1" "$EXIT_CODE"
    fi

    # Test: Empty input file should exit 2
    touch "$SCRIPT_TEST_DIR/empty.md"
    EXIT_CODE=0
    "$VALIDATE_SCRIPT" --input "$SCRIPT_TEST_DIR/empty.md" --output "$SCRIPT_TEST_DIR/out.md" 2>/dev/null || EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 2 ]]; then
        pass "validate-gen-plan-io: empty input exits 2"
    else
        fail "validate-gen-plan-io: empty input should exit 2" "2" "$EXIT_CODE"
    fi

    # Test: Output directory not found should exit 3
    echo "content" > "$SCRIPT_TEST_DIR/valid.md"
    EXIT_CODE=0
    "$VALIDATE_SCRIPT" --input "$SCRIPT_TEST_DIR/valid.md" --output "$SCRIPT_TEST_DIR/nonexistent_dir/out.md" 2>/dev/null || EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 3 ]]; then
        pass "validate-gen-plan-io: output dir not found exits 3"
    else
        fail "validate-gen-plan-io: output dir not found should exit 3" "3" "$EXIT_CODE"
    fi

    # Test: Output file already exists should exit 4
    touch "$SCRIPT_TEST_DIR/existing.md"
    EXIT_CODE=0
    "$VALIDATE_SCRIPT" --input "$SCRIPT_TEST_DIR/valid.md" --output "$SCRIPT_TEST_DIR/existing.md" 2>/dev/null || EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 4 ]]; then
        pass "validate-gen-plan-io: output exists exits 4"
    else
        fail "validate-gen-plan-io: output exists should exit 4" "4" "$EXIT_CODE"
    fi

    # Test: Output path is a directory should exit 4
    mkdir -p "$SCRIPT_TEST_DIR/output_dir"
    EXIT_CODE=0
    "$VALIDATE_SCRIPT" --input "$SCRIPT_TEST_DIR/valid.md" --output "$SCRIPT_TEST_DIR/output_dir" 2>/dev/null || EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 4 ]]; then
        pass "validate-gen-plan-io: output is directory exits 4"
    else
        fail "validate-gen-plan-io: output is directory should exit 4" "4" "$EXIT_CODE"
    fi

    # Test: Valid paths should exit 0
    EXIT_CODE=0
    "$VALIDATE_SCRIPT" --input "$SCRIPT_TEST_DIR/valid.md" --output "$SCRIPT_TEST_DIR/new-output.md" 2>/dev/null || EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 0 ]]; then
        pass "validate-gen-plan-io: valid paths exits 0"
    else
        fail "validate-gen-plan-io: valid paths should exit 0" "0" "$EXIT_CODE"
    fi

    # Test: Valid paths with auto-start flag should exit 0
    EXIT_CODE=0
    "$VALIDATE_SCRIPT" --input "$SCRIPT_TEST_DIR/valid.md" --output "$SCRIPT_TEST_DIR/new-output-auto.md" --auto-start-rlcr-if-converged 2>/dev/null || EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 0 ]]; then
        pass "validate-gen-plan-io: auto-start flag accepted"
    else
        fail "validate-gen-plan-io: auto-start flag should be accepted" "0" "$EXIT_CODE"
    fi

    # Test: --discussion flag is recognized (not rejected as unknown)
    OUTPUT=$("$VALIDATE_SCRIPT" --input /dev/null --output /dev/null --discussion 2>&1) || true
    if ! echo "$OUTPUT" | grep -qi "unknown option\|unrecognized"; then
        pass "validate script accepts --discussion flag"
    else
        fail "validate script accepts --discussion flag" "accepted" "unknown option error"
    fi

    # Test: --direct flag is recognized (not rejected as unknown)
    OUTPUT=$("$VALIDATE_SCRIPT" --input /dev/null --output /dev/null --direct 2>&1) || true
    if ! echo "$OUTPUT" | grep -qi "unknown option\|unrecognized"; then
        pass "validate script accepts --direct flag"
    else
        fail "validate script accepts --direct flag" "accepted" "unknown option error"
    fi

    # Test: --discussion and --direct together are rejected as mutually exclusive
    OUTPUT=$("$VALIDATE_SCRIPT" --input /dev/null --output /dev/null --discussion --direct 2>&1) || true
    if echo "$OUTPUT" | grep -qi "mutually exclusive\|cannot use"; then
        pass "validate script rejects --discussion and --direct together"
    else
        fail "validate script rejects --discussion and --direct together" "mutual exclusion error" "no error produced"
    fi

    # Test: Help option should exit 6
    EXIT_CODE=0
    "$VALIDATE_SCRIPT" --help 2>/dev/null || EXIT_CODE=$?
    if [[ $EXIT_CODE -eq 6 ]]; then
        pass "validate-gen-plan-io: --help exits 6"
    else
        fail "validate-gen-plan-io: --help should exit 6" "6" "$EXIT_CODE"
    fi
else
    fail "validate-gen-plan-io.sh not found or not executable"
fi

# Test: Plan Structure block in gen-plan.md matches gen-plan-template.md
if [[ -f "$GEN_PLAN_CMD" ]] && [[ -f "$PLAN_TEMPLATE" ]]; then
    EXTRACTED=$(awk '/^```markdown[[:space:]]*$/{in_block=1;next} /^```[[:space:]]*$/ && in_block{exit} in_block' "$GEN_PLAN_CMD")
    if [[ "$EXTRACTED" == "$(<"$PLAN_TEMPLATE")" ]]; then
        pass "gen-plan.md Plan Structure block matches gen-plan-template.md"
    else
        fail "gen-plan.md Plan Structure block matches gen-plan-template.md" "identical content" "content differs (run: diff <(awk '/^\`\`\`markdown/{in_block=1;next} /^\`\`\`/ && in_block{exit} in_block' \"$GEN_PLAN_CMD\") \"$PLAN_TEMPLATE\")"
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
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo ""
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi
