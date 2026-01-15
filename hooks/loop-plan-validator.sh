#!/bin/bash
#
# UserPromptSubmit Hook: Validate plan file before processing prompt
#
# When in an active RLCR loop, validates the plan file based on four cases:
#
# Case 1: --commit-plan-file + Inside repo
#   - Plan file must be tracked by git
#   - Plan file must be clean (no uncommitted changes)
#   - Plan file content must match backup
#
# Case 2: No --commit-plan-file + Inside repo
#   - Plan file can have any git status (dirty, untracked, etc.)
#   - Plan file content must match backup
#
# Case 3: --commit-plan-file + Outside repo
#   - Configuration conflict - block immediately
#
# Case 4: No --commit-plan-file + Outside repo
#   - Plan file content must match backup
#
# This runs BEFORE Claude processes the prompt, preventing work on a stale plan.
#

set -euo pipefail

# Load shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib/loop-common.sh"

# ========================================
# Find Active Loop
# ========================================

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
LOOP_BASE_DIR="$PROJECT_ROOT/.humanize-loop.local"
ACTIVE_LOOP_DIR=$(find_active_loop "$LOOP_BASE_DIR")

# No active loop - allow prompt
if [[ -z "$ACTIVE_LOOP_DIR" ]]; then
    exit 0
fi

# ========================================
# Read Plan File Settings from State
# ========================================

STATE_FILE="$ACTIVE_LOOP_DIR/state.md"
if [[ ! -f "$STATE_FILE" ]]; then
    exit 0
fi

# ========================================
# Check for Pre-1.1.2 State File (Backward Compatibility)
# ========================================
# Old state files lack start_commit, which is required for post-commit validation.
# Block prompt and advise user to start a new loop.

START_COMMIT=$(grep -E "^start_commit:" "$STATE_FILE" 2>/dev/null | sed 's/start_commit: *//' || echo "")

if [[ -z "$START_COMMIT" ]] && grep -q "^plan_file:" "$STATE_FILE" 2>/dev/null; then
    # Rename state file to terminate the loop (unexpected: legacy state file)
    stop_loop "$STATE_FILE" "unexpected"

    FALLBACK="# RLCR Loop Terminated - Upgrade Required

This loop was started with an older version of Humanize (pre-1.1.2).
The state file is missing required fields for proper operation.

Your work has been preserved. Please start a new loop with the updated plugin.

\`/humanize:start-rlcr-loop <your-plan-file>\`"

    REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/pre-112-state-file.md" "$FALLBACK")

    echo "$REASON" >&2
    exit 2
fi

# ========================================
# Check Git Ancestry (HEAD must be descendant of start_commit)
# ========================================
# If user checked out an older branch, the loop state is no longer valid.
# Stop the loop and block the prompt.

if ! check_start_commit_ancestry "$START_COMMIT"; then
    CURRENT_HEAD=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    START_COMMIT_SHORT=$(git rev-parse --short "$START_COMMIT" 2>/dev/null || echo "$START_COMMIT")

    # Stop the loop (unexpected: branch changed)
    stop_loop "$STATE_FILE" "unexpected"

    FALLBACK="# RLCR Loop Terminated - Branch Changed

The current HEAD (\`$CURRENT_HEAD\`) is not a descendant of the loop's start commit (\`$START_COMMIT_SHORT\`).

This typically happens when you checked out an older branch or reset to a previous commit.

The loop has been stopped because the commit history no longer matches.

**To continue working:**
1. If you want to continue the RLCR loop, checkout the original branch and start a new loop
2. If you want to work without the loop, you can proceed normally

\`/humanize:start-rlcr-loop <your-plan-file>\`"

    REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/branch-changed.md" "$FALLBACK" \
        "CURRENT_HEAD=$CURRENT_HEAD" \
        "START_COMMIT=$START_COMMIT_SHORT")

    echo "$REASON" >&2
    exit 2
fi

PLAN_FILE=$(grep -E "^plan_file:" "$STATE_FILE" 2>/dev/null | sed 's/plan_file: *//' || echo "")
COMMIT_PLAN_FILE=$(grep -E "^commit_plan_file:" "$STATE_FILE" 2>/dev/null | sed 's/commit_plan_file: *//' || echo "false")

# No plan file configured - allow prompt
if [[ -z "$PLAN_FILE" ]]; then
    exit 0
fi

# ========================================
# Determine Plan File Location
# ========================================
# Use git toplevel (not PROJECT_ROOT) to handle monorepo subdirectories correctly

PLAN_FILE_REL=$(get_relative_path "$PROJECT_ROOT" "$PLAN_FILE")

# Compute path relative to git toplevel for inside/outside decision
GIT_TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
PLAN_FILE_INSIDE_REPO="false"
if [[ -n "$GIT_TOPLEVEL" ]]; then
    PLAN_FILE_REL_GIT=$(get_relative_path "$GIT_TOPLEVEL" "$PLAN_FILE")
    if [[ "$PLAN_FILE_REL_GIT" != ../* ]]; then
        PLAN_FILE_INSIDE_REPO="true"
    fi
fi

# ========================================
# Case 3: --commit-plan-file + Outside repo = Configuration Conflict
# ========================================

if [[ "$COMMIT_PLAN_FILE" == "true" ]] && [[ "$PLAN_FILE_INSIDE_REPO" == "false" ]]; then
    # Use git-relative path for display if available
    DISPLAY_REL="${PLAN_FILE_REL_GIT:-$PLAN_FILE_REL}"

    FALLBACK="# Configuration Conflict: Plan File Outside Repository

**Error**: --commit-plan-file is set but the plan file is outside the git repository.

**Plan file**: \`$PLAN_FILE\`
**Relative to git root**: \`$DISPLAY_REL\`

This is a configuration error. The loop cannot continue.

**To fix**: Cancel this loop and start a new one with either:
1. Move the plan file inside the repository and use --commit-plan-file
2. Use the loop without --commit-plan-file for external plan files

\`/humanize:cancel-rlcr-loop\`"

    REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/plan-file-outside-repo-conflict.md" "$FALLBACK" \
        "PLAN_FILE=$PLAN_FILE" \
        "PLAN_FILE_REL=$DISPLAY_REL")

    echo "$REASON" >&2
    exit 2
fi

# ========================================
# Case 1: --commit-plan-file + Inside repo = Must be tracked AND clean
# ========================================

if [[ "$COMMIT_PLAN_FILE" == "true" ]] && [[ "$PLAN_FILE_INSIDE_REPO" == "true" ]]; then
    # Check if plan file is tracked (use git-relative path for monorepo support)
    if ! git ls-files --error-unmatch "$PLAN_FILE_REL_GIT" &>/dev/null 2>&1; then
        FALLBACK="# Error: Plan File Not Tracked

The plan file is not tracked by git, but --commit-plan-file requires it to be tracked.

**Plan file**: \`$PLAN_FILE\`

**Options:**
1. **Track the plan file**: \`git add '$PLAN_FILE' && git commit -m 'Add plan file'\`
2. **Cancel and restart** without --commit-plan-file if you want the plan to remain untracked

\`/humanize:cancel-rlcr-loop\`"

        REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/plan-file-not-tracked.md" "$FALLBACK" \
            "PLAN_FILE=$PLAN_FILE")

        echo "$REASON" >&2
        exit 2
    fi

    # Check if plan file is clean (no uncommitted changes)
    # Use git-relative path for monorepo support
    PLAN_FILE_STATUS=$(git status --porcelain "$PLAN_FILE_REL_GIT" 2>/dev/null || true)
    if [[ -n "$PLAN_FILE_STATUS" ]]; then
        FALLBACK="# Error: Plan File Has Uncommitted Changes

The plan file has uncommitted changes, but --commit-plan-file requires it to be clean.

**Plan file**: \`$PLAN_FILE\`
**Status**: \`$PLAN_FILE_STATUS\`

**Options:**
1. **Commit the plan file changes**: \`git add '$PLAN_FILE' && git commit -m 'Update plan'\`
2. **Discard the changes**: \`git checkout -- '$PLAN_FILE'\`
3. **Cancel and restart** without --commit-plan-file if you want the plan to remain uncommitted

\`/humanize:cancel-rlcr-loop\`"

        REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/plan-file-uncommitted.md" "$FALLBACK" \
            "PLAN_FILE=$PLAN_FILE" \
            "PLAN_FILE_STATUS=$PLAN_FILE_STATUS")

        echo "$REASON" >&2
        exit 2
    fi
fi

# ========================================
# All Cases: Check Plan File Content vs Backup
# ========================================
# For Cases 1, 2, and 4, verify plan file content matches backup

PLAN_BACKUP_FILE="$ACTIVE_LOOP_DIR/plan-backup.md"

# No backup - can't validate content, allow prompt
if [[ ! -f "$PLAN_BACKUP_FILE" ]]; then
    exit 0
fi

PLAN_MODIFIED="false"
PLAN_MISSING="false"

if [[ ! -f "$PLAN_FILE" ]]; then
    # Plan file was deleted/moved
    PLAN_MODIFIED="true"
    PLAN_MISSING="true"
elif ! diff -q "$PLAN_FILE" "$PLAN_BACKUP_FILE" &>/dev/null; then
    # Plan file content differs from backup
    PLAN_MODIFIED="true"
fi

# Plan file unchanged - allow prompt
if [[ "$PLAN_MODIFIED" != "true" ]]; then
    exit 0
fi

# ========================================
# Block Prompt - Plan File Content Changed
# ========================================

STATUS_TEXT="modified"
if [[ "$PLAN_MISSING" == "true" ]]; then
    STATUS_TEXT="missing/deleted"
fi

FALLBACK="# RLCR Loop Blocked: Plan File Changed

The plan file has been $STATUS_TEXT since the loop started.

**Plan file**: \`$PLAN_FILE\`
**Backup**: \`$PLAN_BACKUP_FILE\`

The RLCR loop cannot continue because the plan has changed.

**Options:**
1. **Restart the loop** with the new plan:
   \`/humanize:start-rlcr-loop $PLAN_FILE\`

2. **Restore the original plan** from backup:
   \`cp '$PLAN_BACKUP_FILE' '$PLAN_FILE'\`
   Then submit your prompt again.

3. **Cancel the loop** and work without RLCR:
   \`/humanize:cancel-rlcr-loop\`"

REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/plan-file-changed-prompt-block.md" "$FALLBACK" \
    "PLAN_FILE=$PLAN_FILE" \
    "PLAN_BACKUP_FILE=$PLAN_BACKUP_FILE" \
    "STATUS_TEXT=$STATUS_TEXT")

echo "$REASON" >&2
exit 2
