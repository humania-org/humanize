#!/bin/bash
#
# Test error scenarios for template-loader.sh
#
# This tests what happens when things go wrong.
#

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PROJECT_ROOT/hooks/lib/template-loader.sh"

TEMPLATE_DIR=$(get_template_dir "$PROJECT_ROOT/hooks/lib")

echo "========================================"
echo "Testing Error Scenarios"
echo "========================================"
echo ""

# ========================================
# Scenario 1: Template file not found
# ========================================
echo "Scenario 1: Template file not found"
set +e  # Temporarily disable exit on error
CONTENT=$(load_template "$TEMPLATE_DIR" "non-existing-file.md" 2>&1)
EXIT_CODE=$?
set -e
echo "  Exit code: $EXIT_CODE"
echo "  Content: '$CONTENT'"
echo "  Result: Template not found returns empty (safe)"
echo ""

# ========================================
# Scenario 2: Template directory not found
# ========================================
echo "Scenario 2: Template directory not found"
set +e
CONTENT=$(load_template "/non/existing/path" "block/git-push.md" 2>&1)
EXIT_CODE=$?
set -e
echo "  Exit code: $EXIT_CODE"
echo "  Content: '$CONTENT'"
echo "  Result: Directory not found returns empty (safe)"
echo ""

# ========================================
# Scenario 3: load_and_render with missing template
# ========================================
echo "Scenario 3: load_and_render with missing template"
set +e
RESULT=$(load_and_render "$TEMPLATE_DIR" "non-existing.md" "VAR=value" 2>&1)
EXIT_CODE=$?
set -e
echo "  Exit code: $EXIT_CODE"
echo "  Result: '$RESULT'"
echo "  Result: Returns empty (safe)"
echo ""

# ========================================
# Scenario 4: render_template with empty content
# ========================================
echo "Scenario 4: render_template with empty content"
set +e
RESULT=$(render_template "" "VAR=value")
EXIT_CODE=$?
set -e
echo "  Exit code: $EXIT_CODE"
echo "  Result: '$RESULT'"
echo "  Result: Returns empty (safe)"
echo ""

# ========================================
# Scenario 5: Variable with special regex characters
# ========================================
echo "Scenario 5: Variable with special regex characters"
set +e
TEMPLATE="Path: {{PATH}}"
RESULT=$(render_template "$TEMPLATE" "PATH=/home/user/file.md [test] (foo) *bar*")
EXIT_CODE=$?
set -e
echo "  Exit code: $EXIT_CODE"
echo "  Result: '$RESULT'"
echo ""

# ========================================
# Scenario 6: What happens with set -e?
# ========================================
echo "Scenario 6: Testing with set -euo pipefail"
bash -c '
set -euo pipefail
source "'"$SCRIPT_DIR"'/template-loader.sh"
TEMPLATE_DIR=$(get_template_dir "'"$SCRIPT_DIR"'")

# Test with missing template
REASON=$(load_and_render "$TEMPLATE_DIR" "non-existing.md" "VAR=value" 2>/dev/null)

if [[ -z "$REASON" ]]; then
    echo "  REASON is empty - script continues, no crash"
else
    echo "  REASON has content: $REASON"
fi
echo "  Script reached end without crashing"
' 2>&1
echo ""

# ========================================
# Summary
# ========================================
echo "========================================"
echo "Error Handling Summary"
echo "========================================"
echo ""
echo "Current behavior:"
echo "  - Missing template file -> returns empty string"
echo "  - Missing directory -> returns empty string"
echo "  - Empty content -> returns empty string"
echo "  - All cases: exit code 0 (no crash)"
echo ""
echo "RISK: If REASON is empty, Claude receives empty feedback!"
echo ""
