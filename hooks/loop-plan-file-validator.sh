#!/bin/bash
#
# UserPromptSubmit hook for plan file validation during RLCR loop
#
# Validates:
# - State schema version (plan_tracked, start_branch fields required)
# - Branch consistency (no switching during loop)
# - Plan file tracking status consistency
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Source shared loop functions and template loader
source "$SCRIPT_DIR/lib/loop-common.sh"

# Read hook input (required for UserPromptSubmit hooks)
INPUT=$(cat)

# Find active loop using shared function
LOOP_BASE_DIR="$PROJECT_ROOT/.humanize-loop.local"
LOOP_DIR=$(find_active_loop "$LOOP_BASE_DIR")

# If no active loop, allow exit
if [[ -z "$LOOP_DIR" ]]; then
    exit 0
fi

STATE_FILE="$LOOP_DIR/state.md"

# Parse state file
# Note: Values are unquoted since v1.1.2+ validates paths don't contain special chars
# Legacy quote-stripping kept for backward compatibility with older state files
FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE" 2>/dev/null || echo "")

PLAN_TRACKED=$(echo "$FRONTMATTER" | grep '^plan_tracked:' | sed 's/plan_tracked: *//' | tr -d ' ' || true)
PLAN_FILE=$(echo "$FRONTMATTER" | grep '^plan_file:' | sed 's/plan_file: *//; s/^"//; s/"$//' || true)
START_BRANCH=$(echo "$FRONTMATTER" | grep '^start_branch:' | sed 's/start_branch: *//; s/^"//; s/"$//' || true)

# ========================================
# Schema Validation (v1.1.2+ required fields)
# ========================================

# Helper function to output schema validation error
schema_validation_error() {
    local field_name="$1"
    local fallback="RLCR loop state file is missing required field: \`${field_name}\`\n\nThis indicates the loop was started with an older version of humanize.\n\n**Options:**\n1. Cancel the loop: \`/humanize:cancel-rlcr-loop\`\n2. Update humanize plugin to version 1.1.2+\n3. Restart the RLCR loop with the updated plugin"

    local reason
    reason=$(load_and_render_safe "$TEMPLATE_DIR" "block/schema-outdated.md" "$fallback" "FIELD_NAME=$field_name")

    # Escape newlines for JSON
    local escaped_reason
    escaped_reason=$(echo "$reason" | jq -Rs '.')

    cat << EOF
{
  "decision": "block",
  "reason": $escaped_reason
}
EOF
}

# Check required fields
REQUIRED_FIELDS=("plan_tracked:$PLAN_TRACKED" "start_branch:$START_BRANCH")
for field_entry in "${REQUIRED_FIELDS[@]}"; do
    field_name="${field_entry%%:*}"
    field_value="${field_entry#*:}"

    if [[ -z "$field_value" ]]; then
        schema_validation_error "$field_name"
        exit 0
    fi
done

# ========================================
# Branch Consistency Check
# ========================================

CURRENT_BRANCH=$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
if [[ -n "$START_BRANCH" && "$CURRENT_BRANCH" != "$START_BRANCH" ]]; then
    cat << EOF
{
  "decision": "block",
  "reason": "Git branch has changed during RLCR loop.\\n\\nStarted on: $START_BRANCH\\nCurrent: $CURRENT_BRANCH\\n\\nBranch switching is not allowed during an active RLCR loop. Please switch back to the original branch or cancel the loop with /humanize:cancel-rlcr-loop"
}
EOF
    exit 0
fi

# ========================================
# Plan File Tracking Status Check
# ========================================

FULL_PLAN_PATH="$PROJECT_ROOT/$PLAN_FILE"

if [[ "$PLAN_TRACKED" == "true" ]]; then
    # Must be tracked and clean
    PLAN_IS_TRACKED=$(git -C "$PROJECT_ROOT" ls-files --error-unmatch "$PLAN_FILE" &>/dev/null && echo "true" || echo "false")
    PLAN_GIT_STATUS=$(git -C "$PROJECT_ROOT" status --porcelain "$PLAN_FILE" 2>/dev/null || echo "")

    if [[ "$PLAN_IS_TRACKED" != "true" ]]; then
        cat << EOF
{
  "decision": "block",
  "reason": "Plan file is no longer tracked in git.\\n\\nFile: $PLAN_FILE\\n\\nThis RLCR loop was started with --track-plan-file, but the plan file has been removed from git tracking."
}
EOF
        exit 0
    fi

    if [[ -n "$PLAN_GIT_STATUS" ]]; then
        cat << EOF
{
  "decision": "block",
  "reason": "Plan file has uncommitted modifications.\\n\\nFile: $PLAN_FILE\\nStatus: $PLAN_GIT_STATUS\\n\\nThis RLCR loop was started with --track-plan-file. Plan file modifications are not allowed during the loop."
}
EOF
        exit 0
    fi
else
    # Must be gitignored (not tracked)
    PLAN_IS_TRACKED=$(git -C "$PROJECT_ROOT" ls-files --error-unmatch "$PLAN_FILE" &>/dev/null && echo "true" || echo "false")

    if [[ "$PLAN_IS_TRACKED" == "true" ]]; then
        cat << EOF
{
  "decision": "block",
  "reason": "Plan file is now tracked in git but loop was started without --track-plan-file.\\n\\nFile: $PLAN_FILE\\n\\nThe plan file must remain gitignored during this RLCR loop."
}
EOF
        exit 0
    fi
fi

exit 0
