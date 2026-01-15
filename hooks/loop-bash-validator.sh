#!/bin/bash
#
# PreToolUse Hook: Validate Bash commands for RLCR loop
#
# Blocks attempts to bypass Write/Edit hooks using shell commands:
# - cat/echo/printf > file.md (redirection)
# - tee file.md
# - sed -i file.md (in-place edit)
# - goal-tracker.md modifications after Round 0
#

set -euo pipefail

# Load shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib/loop-common.sh"

# ========================================
# Parse Hook Input
# ========================================

HOOK_INPUT=$(cat)
TOOL_NAME=$(echo "$HOOK_INPUT" | jq -r '.tool_name // ""')

if [[ "$TOOL_NAME" != "Bash" ]]; then
    exit 0
fi

COMMAND=$(echo "$HOOK_INPUT" | jq -r '.tool_input.command // ""')
COMMAND_LOWER=$(to_lower "$COMMAND")

# ========================================
# Find Active Loop (needed for multiple checks)
# ========================================

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
LOOP_BASE_DIR="$PROJECT_ROOT/.humanize-loop.local"
ACTIVE_LOOP_DIR=$(find_active_loop "$LOOP_BASE_DIR")

# If no active loop, allow all commands
if [[ -z "$ACTIVE_LOOP_DIR" ]]; then
    exit 0
fi

CURRENT_ROUND=$(get_current_round "$ACTIVE_LOOP_DIR/state.md")
STATE_FILE="$ACTIVE_LOOP_DIR/state.md"

# ========================================
# Block Git Push When push_every_round is false
# ========================================
# Default behavior: commits stay local, no need to push to remote

PUSH_EVERY_ROUND=$(grep -E "^push_every_round:" "$STATE_FILE" 2>/dev/null | sed 's/push_every_round: *//' || echo "false")

if [[ "$PUSH_EVERY_ROUND" != "true" ]]; then
    # Check if command is a git push command
    if [[ "$COMMAND_LOWER" =~ ^[[:space:]]*git[[:space:]]+push ]]; then
        FALLBACK="# Git Push Blocked

Commits should stay local during the RLCR loop.
Use --push-every-round flag when starting the loop if you need to push each round."
        load_and_render_safe "$TEMPLATE_DIR" "block/git-push.md" "$FALLBACK" >&2
        exit 2
    fi
fi

# ========================================
# Block Git Commit When Plan File is Staged
# ========================================
# When commit_plan_file is false, prevent committing if plan file is staged.
# This is a pre-commit check that catches the issue before it happens,
# complementing the post-commit check in the stop hook.

COMMIT_PLAN_FILE=$(grep -E "^commit_plan_file:" "$STATE_FILE" 2>/dev/null | sed 's/commit_plan_file: *//' || echo "false")
PLAN_FILE_FROM_STATE=$(grep -E "^plan_file:" "$STATE_FILE" 2>/dev/null | sed 's/plan_file: *//' || echo "")

if [[ "$COMMIT_PLAN_FILE" != "true" ]] && [[ -n "$PLAN_FILE_FROM_STATE" ]]; then
    # Check if command is a git commit command
    if [[ "$COMMAND_LOWER" =~ ^[[:space:]]*git[[:space:]]+commit ]]; then
        # Get relative path of plan file from git toplevel (git diff outputs repo-relative paths)
        GIT_TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
        if [[ -n "$GIT_TOPLEVEL" ]]; then
            PLAN_FILE_REL_GIT=$(get_relative_path "$GIT_TOPLEVEL" "$PLAN_FILE_FROM_STATE")
        else
            PLAN_FILE_REL_GIT=$(get_relative_path "$PROJECT_ROOT" "$PLAN_FILE_FROM_STATE")
        fi

        # Check if plan file is staged (would be included in commit)
        STAGED_FILES=$(git diff --cached --name-only 2>/dev/null || true)

        # Escape regex metacharacters for exact matching
        PLAN_FILE_ESCAPED=$(echo "$PLAN_FILE_REL_GIT" | sed 's/[.[\*^$()+?{|]/\\&/g')

        if echo "$STAGED_FILES" | grep -qx "$PLAN_FILE_ESCAPED"; then
            FALLBACK="# Git Commit Blocked: Plan File is Staged

The plan file is staged and would be included in this commit, but \`--commit-plan-file\` was not set when starting the loop.

**Plan file**: \`{{PLAN_FILE}}\`

**To fix**: Unstage the plan file before committing:
\`\`\`bash
git reset HEAD {{PLAN_FILE}}
\`\`\`

Then retry your commit command.

**Alternative**: If you want to track plan file changes, restart the loop with \`--commit-plan-file\`:
\`\`\`
/humanize:cancel-rlcr-loop
/humanize:start-rlcr-loop {{PLAN_FILE}} --commit-plan-file
\`\`\`"
            load_and_render_safe "$TEMPLATE_DIR" "block/plan-file-staged.md" "$FALLBACK" \
                "PLAN_FILE=$PLAN_FILE_REL_GIT" >&2
            exit 2
        fi
    fi
fi

# ========================================
# Block State File Modifications (All Rounds)
# ========================================
# State file is managed by the loop system, not Claude

if command_modifies_file "$COMMAND_LOWER" "state\.md"; then
    state_file_blocked_message >&2
    exit 2
fi

# ========================================
# Block Goal Tracker Modifications (All Rounds)
# ========================================
# Round 0: prompt to use Write/Edit
# Round > 0: prompt to put request in summary

if command_modifies_file "$COMMAND_LOWER" "goal-tracker\.md"; then
    if [[ "$CURRENT_ROUND" -eq 0 ]]; then
        GOAL_TRACKER_PATH="$ACTIVE_LOOP_DIR/goal-tracker.md"
        goal_tracker_bash_blocked_message "$GOAL_TRACKER_PATH" >&2
    else
        SUMMARY_FILE="$ACTIVE_LOOP_DIR/round-${CURRENT_ROUND}-summary.md"
        goal_tracker_blocked_message "$CURRENT_ROUND" "$SUMMARY_FILE" >&2
    fi
    exit 2
fi

# ========================================
# Block Prompt File Modifications (All Rounds)
# ========================================
# Prompt files are read-only - they contain instructions FROM Codex TO Claude

if command_modifies_file "$COMMAND_LOWER" "round-[0-9]+-prompt\.md"; then
    prompt_write_blocked_message >&2
    exit 2
fi

# ========================================
# Block Summary File Modifications (All Rounds)
# ========================================
# Summary files should be written using Write or Edit tools for proper validation

if command_modifies_file "$COMMAND_LOWER" "round-[0-9]+-summary\.md"; then
    CORRECT_PATH="$ACTIVE_LOOP_DIR/round-${CURRENT_ROUND}-summary.md"
    summary_bash_blocked_message "$CORRECT_PATH" >&2
    exit 2
fi

# ========================================
# Block Todos File Modifications (All Rounds)
# ========================================

if command_modifies_file "$COMMAND_LOWER" "round-[0-9]+-todos\.md"; then
    todos_blocked_message "Bash" >&2
    exit 2
fi

exit 0
