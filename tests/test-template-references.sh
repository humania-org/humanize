#!/bin/bash
#
# Template Reference Validation
#
# This script scans all shell scripts that use template loading functions
# and verifies that all referenced template files actually exist.
#
# This prevents the critical issue where a missing template file causes
# Claude to receive empty error messages when a validator blocks an action.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_DIR="$PROJECT_ROOT/prompt-template"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

TESTS_PASSED=0
TESTS_FAILED=0
WARNINGS=0

pass() {
    echo -e "  ${GREEN}PASS${NC}: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo -e "  ${RED}FAIL${NC}: $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

warn() {
    echo -e "  ${YELLOW}WARN${NC}: $1"
    WARNINGS=$((WARNINGS + 1))
}

section() {
    echo ""
    echo -e "${BLUE}========================================"
    echo "$1"
    echo -e "========================================${NC}"
}

# ========================================
# Section 1: Find All Template References
# ========================================
section "Section 1: Scanning Shell Scripts for Template References"

# Find all shell scripts that might use templates
SCRIPTS_TO_CHECK=(
    "$PROJECT_ROOT/hooks/loop-codex-stop-hook.sh"
    "$PROJECT_ROOT/hooks/loop-plan-validator.sh"
    "$PROJECT_ROOT/hooks/loop-read-validator.sh"
    "$PROJECT_ROOT/hooks/loop-write-validator.sh"
    "$PROJECT_ROOT/hooks/loop-edit-validator.sh"
    "$PROJECT_ROOT/hooks/loop-bash-validator.sh"
    "$PROJECT_ROOT/hooks/lib/loop-common.sh"
)

# Patterns that reference templates
# - load_template "$TEMPLATE_DIR" "path/to/template.md"
# - load_and_render "$TEMPLATE_DIR" "path/to/template.md"
# - load_and_render_safe "$TEMPLATE_DIR" "path/to/template.md"

MISSING_TEMPLATES=()
FOUND_REFERENCES=0

for script in "${SCRIPTS_TO_CHECK[@]}"; do
    if [[ ! -f "$script" ]]; then
        warn "Script not found: $script"
        continue
    fi

    script_name=$(basename "$script")
    echo "Checking: $script_name"

    # Extract template paths from load_template, load_and_render, load_and_render_safe calls
    # Pattern: function_name "$TEMPLATE_DIR" "template/path.md"
    # We look for quoted strings after $TEMPLATE_DIR

    while IFS= read -r line; do
        # Skip comments
        if [[ "$line" =~ ^[[:space:]]*# ]]; then
            continue
        fi

        # Match load_template, load_and_render, or load_and_render_safe
        if echo "$line" | grep -qE '(load_template|load_and_render|load_and_render_safe)[[:space:]]+"\$TEMPLATE_DIR"'; then
            # Extract the template path (second quoted argument)
            template_path=$(echo "$line" | sed -n 's/.*"\$TEMPLATE_DIR"[[:space:]]*"\([^"]*\)".*/\1/p')

            if [[ -n "$template_path" ]]; then
                FOUND_REFERENCES=$((FOUND_REFERENCES + 1))
                full_path="$TEMPLATE_DIR/$template_path"

                if [[ -f "$full_path" ]]; then
                    pass "Template exists: $template_path"
                else
                    fail "Template MISSING: $template_path (referenced in $script_name)"
                    MISSING_TEMPLATES+=("$template_path")
                fi
            fi
        fi
    done < "$script"
done

echo ""
echo "Total template references found: $FOUND_REFERENCES"

# ========================================
# Section 2: Check Template Directory Completeness
# ========================================
section "Section 2: Verify All Templates Are Referenced"

# Get list of all template files
TEMPLATE_FILES=()
while IFS= read -r -d '' file; do
    relative_path="${file#$TEMPLATE_DIR/}"
    TEMPLATE_FILES+=("$relative_path")
done < <(find "$TEMPLATE_DIR" -name "*.md" -type f -print0)

echo "Total template files: ${#TEMPLATE_FILES[@]}"

# For each template, check if it's referenced somewhere
# (This is informational - not all templates need to be referenced)
UNREFERENCED=()

for template in "${TEMPLATE_FILES[@]}"; do
    # Search for this template path in any shell script
    if grep -rq "\"$template\"" "$PROJECT_ROOT/hooks/" 2>/dev/null; then
        pass "Template referenced: $template"
    else
        warn "Template not directly referenced: $template (may be OK if used dynamically)"
        UNREFERENCED+=("$template")
    fi
done

# ========================================
# Section 3: Cross-Reference Validation
# ========================================
section "Section 3: Cross-Reference Validation"

# Check that message functions in loop-common.sh reference valid templates
echo "Checking loop-common.sh message functions..."

COMMON_TEMPLATES=(
    "block/todos-file-access.md"
    "block/prompt-file-write.md"
    "block/state-file-modification.md"
    "block/summary-bash-write.md"
    "block/goal-tracker-bash-write.md"
    "block/goal-tracker-modification.md"
)

for template in "${COMMON_TEMPLATES[@]}"; do
    if [[ -f "$TEMPLATE_DIR/$template" ]]; then
        pass "Common template exists: $template"
    else
        fail "Common template MISSING: $template"
    fi
done

# ========================================
# Section 4: Verify Fallback Messages Exist
# ========================================
section "Section 4: Verify load_and_render_safe Usage"

echo "Checking that critical validators use load_and_render_safe..."

CRITICAL_SCRIPTS=(
    "$PROJECT_ROOT/hooks/loop-read-validator.sh"
    "$PROJECT_ROOT/hooks/loop-write-validator.sh"
    "$PROJECT_ROOT/hooks/loop-edit-validator.sh"
)

for script in "${CRITICAL_SCRIPTS[@]}"; do
    script_name=$(basename "$script")

    # Count lines with load_and_render that are NOT load_and_render_safe
    # First get all load_and_render lines, then exclude _safe ones
    unsafe_count=0
    while IFS= read -r line; do
        if echo "$line" | grep -q 'load_and_render[[:space:]]*"\$TEMPLATE_DIR"'; then
            if ! echo "$line" | grep -q 'load_and_render_safe'; then
                unsafe_count=$((unsafe_count + 1))
            fi
        fi
    done < "$script"

    if [[ "$unsafe_count" -gt 0 ]]; then
        fail "$script_name has $unsafe_count unsafe load_and_render calls (should use load_and_render_safe)"
    else
        pass "$script_name uses load_and_render_safe for all template rendering"
    fi
done

# ========================================
# Summary
# ========================================
section "Test Summary"

echo ""
echo -e "Passed:   ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed:   ${RED}$TESTS_FAILED${NC}"
echo -e "Warnings: ${YELLOW}$WARNINGS${NC}"

if [[ ${#MISSING_TEMPLATES[@]} -gt 0 ]]; then
    echo ""
    echo -e "${RED}CRITICAL: Missing template files:${NC}"
    for t in "${MISSING_TEMPLATES[@]}"; do
        echo "  - $t"
    done
fi

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo ""
    echo -e "${GREEN}All template reference checks passed!${NC}"
    exit 0
else
    echo ""
    echo -e "${RED}Template reference validation failed!${NC}"
    echo "Fix the missing templates before committing."
    exit 1
fi
