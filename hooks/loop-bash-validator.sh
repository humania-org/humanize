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
LOOP_BASE_DIR="$PROJECT_ROOT/.humanize/rlcr"
ACTIVE_LOOP_DIR=$(find_active_loop "$LOOP_BASE_DIR")

# If no active loop, allow all commands
if [[ -z "$ACTIVE_LOOP_DIR" ]]; then
    exit 0
fi

STATE_FILE="$ACTIVE_LOOP_DIR/state.md"

# Parse state file using shared function to get current round
parse_state_file "$STATE_FILE"
CURRENT_ROUND="$STATE_CURRENT_ROUND"

# ========================================
# Block Git Push When push_every_round is false
# ========================================
# Default behavior: commits stay local, no need to push to remote

# Note: parse_state_file was called above, STATE_* vars are available
PUSH_EVERY_ROUND="$STATE_PUSH_EVERY_ROUND"

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
# Block State File Modifications (All Rounds)
# ========================================
# State file is managed by the loop system, not Claude

if command_modifies_file "$COMMAND_LOWER" "state\.md"; then
    state_file_blocked_message >&2
    exit 2
fi

# ========================================
# Block Plan Backup Modifications (All Rounds)
# ========================================
# Plan backup is read-only - protects plan integrity during loop
# Use command_modifies_file helper for consistent pattern matching

if command_modifies_file "$COMMAND_LOWER" "\.humanize/rlcr(/[^/]+)?/plan\.md"; then
    FALLBACK="Writing to plan.md backup is not allowed during RLCR loop."
    REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/plan-backup-protected.md" "$FALLBACK")
    echo "$REASON" >&2
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
    # Require full path to active loop dir to prevent same-basename bypass from different roots
    ACTIVE_LOOP_DIR_LOWER=$(to_lower "$ACTIVE_LOOP_DIR")
    ACTIVE_LOOP_DIR_ESCAPED=$(echo "$ACTIVE_LOOP_DIR_LOWER" | sed 's/[\\.*^$[(){}+?|]/\\&/g')
    if ! echo "$COMMAND_LOWER" | grep -qE "${ACTIVE_LOOP_DIR_ESCAPED}/round-[12]-todos\.md"; then
        todos_blocked_message "Bash" >&2
        exit 2
    fi
fi

exit 0
