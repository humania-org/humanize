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

# Source portable timeout wrapper for git operations
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PLUGIN_ROOT/scripts/portable-timeout.sh"

# Default timeout for git operations (30 seconds)
GIT_TIMEOUT=30

# Read hook input (required for UserPromptSubmit hooks)
INPUT=$(cat)

# Extract session_id from hook input for session-aware loop filtering
HOOK_SESSION_ID=$(extract_session_id "$INPUT")

# Find active loop using shared function (filtered by session_id)
LOOP_BASE_DIR="$PROJECT_ROOT/.humanize/rlcr"
LOOP_DIR=$(find_active_loop "$LOOP_BASE_DIR" "$HOOK_SESSION_ID")

# If no active loop, allow exit
if [[ -z "$LOOP_DIR" ]]; then
    exit 0
fi

# Detect if we're in Finalize Phase (finalize-state.md exists)
STATE_FILE=$(resolve_active_state_file "$LOOP_DIR")

# Parse state file using strict validation (fail closed on malformed state)
if ! parse_state_file_strict "$STATE_FILE" 2>/dev/null; then
    echo "Error: Malformed state file, blocking operation for safety" >&2
    exit 1
fi

# Map STATE_* variables to local names for backward compatibility
PLAN_TRACKED="$STATE_PLAN_TRACKED"
PLAN_FILE="$STATE_PLAN_FILE"
START_BRANCH="$STATE_START_BRANCH"

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

# Check required fields (using FIELD_* constants from loop-common.sh)
REQUIRED_FIELDS=("${FIELD_PLAN_TRACKED}:$PLAN_TRACKED" "${FIELD_START_BRANCH}:$START_BRANCH")
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

# Use || GIT_EXIT_CODE=$? to prevent set -e from aborting on non-zero exit
CURRENT_BRANCH=$(run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null) || GIT_EXIT_CODE=$?
GIT_EXIT_CODE=${GIT_EXIT_CODE:-0}
if [[ $GIT_EXIT_CODE -ne 0 || -z "$CURRENT_BRANCH" ]]; then
    cat << EOF
{
  "decision": "block",
  "reason": "Git operation failed or timed out.\\n\\nCannot verify branch consistency. Please check git status and try again."
}
EOF
    exit 0
fi
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
    # Use || LS_FILES_EXIT=$? to prevent set -e from aborting on non-zero exit
    # ls-files --error-unmatch returns: 0 (tracked), 1 (not tracked), 124 (timeout), other (error)
    run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" ls-files --error-unmatch "$PLAN_FILE" &>/dev/null || LS_FILES_EXIT=$?
    LS_FILES_EXIT=${LS_FILES_EXIT:-0}
    if [[ $LS_FILES_EXIT -eq 124 ]]; then
        # Timeout - fail closed
        cat << EOF
{
  "decision": "block",
  "reason": "Git operation timed out while checking plan file tracking status.\\n\\nPlease check git status and try again."
}
EOF
        exit 0
    elif [[ $LS_FILES_EXIT -ne 0 && $LS_FILES_EXIT -ne 1 ]]; then
        # Unexpected git error - fail closed
        cat << EOF
{
  "decision": "block",
  "reason": "Git operation failed while checking plan file tracking status (exit code: $LS_FILES_EXIT).\\n\\nPlease check git status and try again."
}
EOF
        exit 0
    fi
    PLAN_IS_TRACKED=$([[ $LS_FILES_EXIT -eq 0 ]] && echo "true" || echo "false")

    # Use || STATUS_EXIT=$? to prevent set -e from aborting on non-zero exit
    # git status --porcelain returns: 0 (success), 124 (timeout), other (error)
    PLAN_GIT_STATUS=$(run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" status --porcelain "$PLAN_FILE" 2>/dev/null) || STATUS_EXIT=$?
    STATUS_EXIT=${STATUS_EXIT:-0}
    if [[ $STATUS_EXIT -eq 124 ]]; then
        # Timeout - fail closed
        cat << EOF
{
  "decision": "block",
  "reason": "Git operation timed out while checking plan file status.\\n\\nPlease check git status and try again."
}
EOF
        exit 0
    elif [[ $STATUS_EXIT -ne 0 ]]; then
        # Unexpected git error - fail closed
        cat << EOF
{
  "decision": "block",
  "reason": "Git operation failed while checking plan file status (exit code: $STATUS_EXIT).\\n\\nPlease check git status and try again."
}
EOF
        exit 0
    fi

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
    # Check if git command succeeds - fail closed on timeout/error
    # ls-files --error-unmatch returns: 0 (tracked), 1 (not tracked), 124 (timeout), other (error)
    run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" ls-files --error-unmatch "$PLAN_FILE" &>/dev/null || LS_FILES_EXIT=$?
    LS_FILES_EXIT=${LS_FILES_EXIT:-0}
    if [[ $LS_FILES_EXIT -eq 124 ]]; then
        # Timeout - fail closed
        cat << EOF
{
  "decision": "block",
  "reason": "Git operation timed out while checking plan file tracking status.\\n\\nPlease check git status and try again."
}
EOF
        exit 0
    elif [[ $LS_FILES_EXIT -ne 0 && $LS_FILES_EXIT -ne 1 ]]; then
        # Unexpected git error - fail closed
        cat << EOF
{
  "decision": "block",
  "reason": "Git operation failed while checking plan file tracking status (exit code: $LS_FILES_EXIT).\\n\\nPlease check git status and try again."
}
EOF
        exit 0
    fi
    PLAN_IS_TRACKED=$([[ $LS_FILES_EXIT -eq 0 ]] && echo "true" || echo "false")

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
