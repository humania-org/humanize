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
# Exception: Allow mv to cancel-state.md when cancel signal file exists
#
# Note: We check TWO patterns for mv/cp:
# 1. command_modifies_file checks if DESTINATION contains state.md
# 2. Additional check below catches if SOURCE contains state.md (e.g., mv state.md /tmp/foo)

# Check 1: Destination contains state.md (covers writes, redirects, mv/cp TO state.md)
if command_modifies_file "$COMMAND_LOWER" "state\.md"; then
    # Check for cancel signal file - allow authorized cancel operation
    if is_cancel_authorized "$ACTIVE_LOOP_DIR" "$COMMAND_LOWER"; then
        exit 0
    fi
    state_file_blocked_message >&2
    exit 2
fi

# Check 2: Source of mv/cp contains state.md (covers mv/cp FROM state.md to any destination)
# This catches bypass attempts like: mv state.md /tmp/foo.txt
# Pattern handles:
# - Options like -f, -- before the source path
# - Leading whitespace and command prefixes with options (sudo -u root, env VAR=val, command --)
# - Quoted relative paths like: mv -- "state.md" /tmp/foo
# - Command chaining via ;, &&, ||, |, |&, & (each segment is checked independently)
# - Shell wrappers: sh -c, bash -c, /bin/sh -c, /bin/bash -c
# Requires state.md to be a proper filename (preceded by space, /, or quote)
# Note: sudo/command patterns match zero or more arguments (each: space + optional-minus + non-space chars)

# Split command on shell operators and check each segment
# This catches chained commands like: true; mv state.md /tmp/foo
MV_CP_SOURCE_PATTERN="^[[:space:]]*(sudo([[:space:]]+-?[^[:space:];&|]+)*[[:space:]]+)?(env[[:space:]]+[^;&|]*[[:space:]]+)?(command([[:space:]]+-?[^[:space:];&|]+)*[[:space:]]+)?(mv|cp)[[:space:]].*[[:space:]/\"']state\.md"

# Replace shell operators with newlines, then check each segment
# Order matters: |& before |, && before single &
# For &: protect redirections (&>>, &>, >&, N>&M) with placeholders, then split on remaining &
# Placeholders use control chars unlikely to appear in commands
# Note: &>> must be replaced before &> to avoid leaving a stray >
COMMAND_SEGMENTS=$(echo "$COMMAND_LOWER" | sed '
    s/|&/\n/g
    s/&&/\n/g
    s/&>>/\x03/g
    s/&>/\x01/g
    s/[0-9]*>&[0-9]*/\x02/g
    s/>&/\x02/g
    s/&/\n/g
    s/||/\n/g
    s/|/\n/g
    s/;/\n/g
')
while IFS= read -r SEGMENT; do
    # Skip empty segments
    [[ -z "$SEGMENT" ]] && continue

    # Strip leading redirections before pattern matching
    # This handles cases like: 2>/tmp/x mv, 2> /tmp/x mv, >/tmp/x mv, 2>&1 mv, &>/tmp/x mv
    # Also handles append redirections: >> /tmp/x mv, 2>> /tmp/x mv, &>> /tmp/x mv
    # Also handles quoted targets: >> "/tmp/x y" mv, >> '/tmp/x y' mv
    # Also handles ANSI-C quoting: >> $'/tmp/x y' mv, >> $"/tmp/x y" mv
    # Also handles escaped-space targets: >> /tmp/x\ y mv
    # Must handle:
    # - \x01 (from &>) followed by optional space and target path (quoted, ANSI-C, escaped, or unquoted)
    # - \x02 (from >&, 2>&1) with NO target - just strip placeholder
    # - \x03 (from &>>) followed by optional space and target path (quoted, ANSI-C, escaped, or unquoted)
    # - Standard redirections [0-9]*[><]+ followed by optional space and target
    # Order: double-quoted, single-quoted, ANSI-C $'...', locale $"...", escaped-unquoted, plain-unquoted
    # Note: Escaped/ANSI-C patterns use sed -E for extended regex
    SEGMENT_CLEANED=$(echo "$SEGMENT" | sed '
        :again
        s/^[[:space:]]*\x01[[:space:]]*"[^"]*"[[:space:]]*//
        t again
    ' | sed '
        :again
        s/^[[:space:]]*\x01[[:space:]]*'"'"'[^'"'"']*'"'"'[[:space:]]*//
        t again
    ' | sed -E "
        :again
        s/^[[:space:]]*\x01[[:space:]]*\\$'([^'\\\\]|\\\\.)*'[[:space:]]*//
        t again
    " | sed -E '
        :again
        s/^[[:space:]]*\x01[[:space:]]*\$"([^"\\]|\\.)*"[[:space:]]*//
        t again
    ' | sed -E '
        :again
        s/^[[:space:]]*\x01[[:space:]]*([^[:space:]\\]|\\.)+[[:space:]]*//
        t again
    ' | sed '
        :again
        s/^[[:space:]]*\x01[[:space:]]*[^[:space:]]*[[:space:]]*//
        t again
    ' | sed '
        :again
        s/^[[:space:]]*\x02[[:space:]]*//
        t again
    ' | sed '
        :again
        s/^[[:space:]]*\x03[[:space:]]*"[^"]*"[[:space:]]*//
        t again
    ' | sed '
        :again
        s/^[[:space:]]*\x03[[:space:]]*'"'"'[^'"'"']*'"'"'[[:space:]]*//
        t again
    ' | sed -E "
        :again
        s/^[[:space:]]*\x03[[:space:]]*\\$'([^'\\\\]|\\\\.)*'[[:space:]]*//
        t again
    " | sed -E '
        :again
        s/^[[:space:]]*\x03[[:space:]]*\$"([^"\\]|\\.)*"[[:space:]]*//
        t again
    ' | sed -E '
        :again
        s/^[[:space:]]*\x03[[:space:]]*([^[:space:]\\]|\\.)+[[:space:]]*//
        t again
    ' | sed '
        :again
        s/^[[:space:]]*\x03[[:space:]]*[^[:space:]]*[[:space:]]*//
        t again
    ' | sed '
        :again
        s/^[[:space:]]*[0-9]*[><][><]*[[:space:]]*"[^"]*"[[:space:]]*//
        t again
    ' | sed '
        :again
        s/^[[:space:]]*[0-9]*[><][><]*[[:space:]]*'"'"'[^'"'"']*'"'"'[[:space:]]*//
        t again
    ' | sed -E "
        :again
        s/^[[:space:]]*[0-9]*[><]+[[:space:]]*\\$'([^'\\\\]|\\\\.)*'[[:space:]]*//
        t again
    " | sed -E '
        :again
        s/^[[:space:]]*[0-9]*[><]+[[:space:]]*\$"([^"\\]|\\.)*"[[:space:]]*//
        t again
    ' | sed -E '
        :again
        s/^[[:space:]]*[0-9]*[><]+[[:space:]]*([^[:space:]\\]|\\.)+[[:space:]]*//
        t again
    ' | sed '
        :again
        s/^[[:space:]]*[0-9]*[><][><]*[[:space:]]*[^[:space:]]*[[:space:]]*//
        t again
    ')

    if echo "$SEGMENT_CLEANED" | grep -qE "$MV_CP_SOURCE_PATTERN"; then
        # Check for cancel signal file - allow authorized cancel operation
        if is_cancel_authorized "$ACTIVE_LOOP_DIR" "$COMMAND_LOWER"; then
            exit 0
        fi
        state_file_blocked_message >&2
        exit 2
    fi
done <<< "$COMMAND_SEGMENTS"

# Check 3: Shell wrapper bypass (sh -c, bash -c)
# This catches bypass attempts like: sh -c 'mv state.md /tmp/foo'
# Pattern: look for sh/bash with -c flag and state.md in the payload
if echo "$COMMAND_LOWER" | grep -qE "(^|[[:space:]/])(sh|bash)[[:space:]]+-c[[:space:]]"; then
    # Shell wrapper detected - check if payload contains mv/cp state.md
    if echo "$COMMAND_LOWER" | grep -qE "(mv|cp)[[:space:]].*state\.md"; then
        # Check for cancel signal file - allow authorized cancel operation
        if is_cancel_authorized "$ACTIVE_LOOP_DIR" "$COMMAND_LOWER"; then
            exit 0
        fi
        state_file_blocked_message >&2
        exit 2
    fi
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
