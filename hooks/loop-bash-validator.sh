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
        echo "BLOCKED: git push is not required during RLCR loop." >&2
        echo "" >&2
        echo "Current commits should stay local - no need to push to remote." >&2
        echo "The loop will handle commits locally until completion." >&2
        echo "" >&2
        echo "If you need to push, use --push-every-round when starting the loop:" >&2
        echo "  /humanize:start-rlcr-loop plan.md --push-every-round" >&2
        exit 2
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
