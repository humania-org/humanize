#!/bin/bash
#
# PreToolUse Hook: Validate Bash commands for RLCR loop and PR loop
#
# Blocks attempts to bypass Write/Edit hooks using shell commands:
# - cat/echo/printf > file.md (redirection)
# - tee file.md
# - sed -i file.md (in-place edit)
# - goal-tracker.md modifications after Round 0
# - PR loop state.md modifications
# - PR loop read-only file modifications (pr-comment, prompt, codex-prompt, etc.)
#

set -euo pipefail

# Load shared functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib/loop-common.sh"

# ========================================
# Parse Hook Input
# ========================================

HOOK_INPUT=$(cat)

# Validate JSON input structure
if ! validate_hook_input "$HOOK_INPUT"; then
    exit 1
fi

# Check for deeply nested JSON (potential DoS)
if is_deeply_nested "$HOOK_INPUT" 30; then
    exit 1
fi

TOOL_NAME="$VALIDATED_TOOL_NAME"

if [[ "$TOOL_NAME" != "Bash" ]]; then
    exit 0
fi

# Require command for Bash tool
if ! require_tool_input_field "$HOOK_INPUT" "command"; then
    exit 1
fi

COMMAND=$(echo "$HOOK_INPUT" | jq -r '.tool_input.command // ""')
COMMAND_LOWER=$(to_lower "$COMMAND")

# ========================================
# Find Active Loops (needed for multiple checks)
# ========================================

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Extract session_id from hook input for session-aware loop filtering
HOOK_SESSION_ID=$(extract_session_id "$HOOK_INPUT")

# Check for active RLCR loop (filtered by session_id)
LOOP_BASE_DIR="$PROJECT_ROOT/.humanize/rlcr"
ACTIVE_LOOP_DIR=$(find_active_loop "$LOOP_BASE_DIR" "$HOOK_SESSION_ID")

# Check for active PR loop
PR_LOOP_BASE_DIR="$PROJECT_ROOT/.humanize/pr-loop"
ACTIVE_PR_LOOP_DIR=$(find_active_pr_loop "$PR_LOOP_BASE_DIR")

# If no active loop of either type, allow all commands
if [[ -z "$ACTIVE_LOOP_DIR" ]] && [[ -z "$ACTIVE_PR_LOOP_DIR" ]]; then
    exit 0
fi

# ========================================
# RLCR Loop Specific Checks
# ========================================
# The following checks only apply when an RLCR loop is active

if [[ -n "$ACTIVE_LOOP_DIR" ]]; then
    # Detect if we're in Finalize Phase (finalize-state.md exists)
    STATE_FILE=$(resolve_active_state_file "$ACTIVE_LOOP_DIR")

    # Parse state file using strict validation (fail closed on malformed state)
    if ! parse_state_file_strict "$STATE_FILE" 2>/dev/null; then
        echo "Error: Malformed state file, blocking operation for safety" >&2
        exit 1
    fi
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
fi

# ========================================
# Block Git Add Commands Targeting .humanize
# ========================================
# Prevents force-adding .humanize files to version control
# Note: .humanize is in .gitignore, but git add -f bypasses it

if git_adds_humanize "$COMMAND_LOWER"; then
    git_add_humanize_blocked_message >&2
    exit 2
fi

# ========================================
# RLCR State and File Protection
# ========================================
# These checks only apply when an RLCR loop is active

if [[ -n "$ACTIVE_LOOP_DIR" ]]; then

# ========================================
# Block State File Modifications (All Rounds)
# ========================================
# State file is managed by the loop system, not Claude
# This includes both state.md and finalize-state.md
# NOTE: Check finalize-state.md FIRST because state\.md pattern also matches finalize-state.md
# Exception: Allow mv to cancel-state.md when cancel signal file exists
#
# Note: We check TWO patterns for mv/cp:
# 1. command_modifies_file checks if DESTINATION contains state.md
# 2. Additional check below catches if SOURCE contains state.md (e.g., mv state.md /tmp/foo)

if command_modifies_file "$COMMAND_LOWER" "finalize-state\.md"; then
    # Check for cancel signal file - allow authorized cancel operation
    if is_cancel_authorized "$ACTIVE_LOOP_DIR" "$COMMAND_LOWER"; then
        exit 0
    fi
    finalize_state_file_blocked_message >&2
    exit 2
fi

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
MV_CP_FINALIZE_SOURCE_PATTERN="^[[:space:]]*(sudo([[:space:]]+-?[^[:space:];&|]+)*[[:space:]]+)?(env[[:space:]]+[^;&|]*[[:space:]]+)?(command([[:space:]]+-?[^[:space:];&|]+)*[[:space:]]+)?(mv|cp)[[:space:]].*[[:space:]/\"']finalize-state\.md"

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

    # Check for finalize-state.md as SOURCE first (more specific pattern)
    if echo "$SEGMENT_CLEANED" | grep -qE "$MV_CP_FINALIZE_SOURCE_PATTERN"; then
        # Check for cancel signal file - allow authorized cancel operation
        if is_cancel_authorized "$ACTIVE_LOOP_DIR" "$COMMAND_LOWER"; then
            exit 0
        fi
        finalize_state_file_blocked_message >&2
        exit 2
    fi

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
# Pattern: look for sh/bash with -c flag and state.md or finalize-state.md in the payload
if echo "$COMMAND_LOWER" | grep -qE "(^|[[:space:]/])(sh|bash)[[:space:]]+-c[[:space:]]"; then
    # Shell wrapper detected - check if payload contains mv/cp finalize-state.md (check first, more specific)
    if echo "$COMMAND_LOWER" | grep -qE "(mv|cp)[[:space:]].*finalize-state\.md"; then
        # Check for cancel signal file - allow authorized cancel operation
        if is_cancel_authorized "$ACTIVE_LOOP_DIR" "$COMMAND_LOWER"; then
            exit 0
        fi
        finalize_state_file_blocked_message >&2
        exit 2
    fi
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

fi  # End of RLCR-specific checks

# ========================================
# PR Loop File Protection
# ========================================
# Block modifications to PR loop state and read-only files
# Note: ACTIVE_PR_LOOP_DIR was already set at the top of the script

if [[ -n "$ACTIVE_PR_LOOP_DIR" ]]; then
    # Block PR loop state.md modifications
    # Check both full path pattern AND bare filename to catch relative path bypass
    # (e.g., cd .humanize/pr-loop/timestamp && sed -i state.md)
    if command_modifies_file "$COMMAND_LOWER" "\.humanize/pr-loop(/[^/]+)?/state\.md"; then
        pr_loop_state_blocked_message >&2
        exit 2
    fi
    # Bare filename check for state.md (catches relative path usage)
    if command_modifies_file "$COMMAND_LOWER" "state\.md"; then
        pr_loop_state_blocked_message >&2
        exit 2
    fi

    # Block PR loop read-only files:
    # - round-N-pr-comment.md (fetched comments)
    # - round-N-prompt.md (prompts from system)
    # - round-N-codex-prompt.md (Codex prompts)
    # - round-N-pr-check.md (Codex output)
    # - round-N-pr-feedback.md (feedback for next round)
    PR_LOOP_READONLY_PATTERNS=(
        "round-[0-9]+-pr-comment\.md"
        "round-[0-9]+-prompt\.md"
        "round-[0-9]+-codex-prompt\.md"
        "round-[0-9]+-pr-check\.md"
        "round-[0-9]+-pr-feedback\.md"
    )

    for pattern in "${PR_LOOP_READONLY_PATTERNS[@]}"; do
        # Check both full path pattern AND bare filename to catch relative path bypass
        if command_modifies_file "$COMMAND_LOWER" "\.humanize/pr-loop(/[^/]+)?/${pattern}"; then
            pr_loop_prompt_blocked_message >&2
            exit 2
        fi
        # Bare filename check (catches relative path usage from within loop dir)
        if command_modifies_file "$COMMAND_LOWER" "${pattern}"; then
            pr_loop_prompt_blocked_message >&2
            exit 2
        fi
    done
fi

exit 0
