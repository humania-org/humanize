#!/usr/bin/env bash
#
# PreToolUse Hook: Validate Bash commands for RLCR loop
#
# Blocks attempts to bypass Write/Edit hooks using shell commands:
# - cat/echo/printf > file.md (redirection)
# - tee file.md
# - sed -i file.md (in-place edit)
# - goal-tracker.md modifications via Bash
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

PROJECT_ROOT="$(resolve_project_root)" || exit 0

# Extract session_id from hook input for session-aware loop filtering
HOOK_SESSION_ID=$(extract_session_id "$HOOK_INPUT")

# Check for active RLCR loop (filtered by session_id)
LOOP_BASE_DIR="$PROJECT_ROOT/.humanize/rlcr"
ACTIVE_LOOP_DIR=$(find_active_loop "$LOOP_BASE_DIR" "$HOOK_SESSION_ID")

# ========================================
# Methodology Analysis Phase Bash Restriction
# ========================================
# During methodology analysis, block file-modifying bash commands.
# Only read-only operations and cancel-rlcr-loop.sh are allowed.
# This prevents source code modifications after Codex has signed off.
#
# Accepted limitations:
# - Read-only bash commands (cat, grep, find, etc.) are NOT blocked. Blocking
#   them would break basic Claude operations. The analysis prompt directs Claude
#   to derive user-facing content only from methodology-analysis-report.md.
# - Spawned agents (different session_id) are not restricted by hooks; their
#   sanitization is enforced by the analysis prompt. This is an inherent
#   limitation of the hook architecture which cannot distinguish spawned agents
#   from unrelated sessions.
#
# Use only the session-matched loop. Do NOT fall back to an unfiltered search,
# as that would incorrectly restrict unrelated sessions opened in the same repo.
_MA_BASH_DIR="$ACTIVE_LOOP_DIR"

if [[ -n "$_MA_BASH_DIR" ]] && [[ -f "$_MA_BASH_DIR/methodology-analysis-state.md" ]]; then
    # Allow cancel-rlcr-loop.sh only as the leading command (not as an argument
    # to another command like cp/mv). The optional path prefix must be a single
    # token with no embedded whitespace, otherwise commands like
    # `bash cancel-rlcr-loop.sh` or `tee cancel-rlcr-loop.sh` would match.
    # The script name must be followed by whitespace or end-of-line so trailing
    # tokens cannot hide additional arguments. Reject if chained with shell
    # operators.
    if echo "$COMMAND_LOWER" | grep -qE '^[[:space:]]*"?([^[:space:]"]+/)?cancel-rlcr-loop\.sh"?([[:space:]]|$)' && \
       ! echo "$COMMAND_LOWER" | grep -qE '[;|&]'; then
        exit 0
    fi
    # Block git commands that modify the working tree
    if echo "$COMMAND_LOWER" | grep -qE '(^|[[:space:];|&])git[[:space:]]+(commit|add|reset|checkout|merge|rebase|cherry-pick|am|apply|stash|push|restore|clean|rm|mv|switch|pull|clone|submodule|worktree)'; then
        echo "# Bash Blocked During Methodology Analysis

Git write commands are not allowed during the methodology analysis phase." >&2
        exit 2
    fi
    # Block file manipulation commands (touch, mv, cp, rm, mkdir, ln, etc.)
    if echo "$COMMAND_LOWER" | grep -qE '(^|[[:space:];|&])(tee|install|touch|mv|cp|rm|dd|truncate|chmod|chown|mkdir|rmdir|ln|mktemp)[[:space:]]'; then
        echo "# Bash Blocked During Methodology Analysis

File modification commands are not allowed during the methodology analysis phase." >&2
        exit 2
    fi
    # Block in-place file editing tools
    if echo "$COMMAND_LOWER" | grep -qE 'sed[[:space:]]+-i|awk[[:space:]]+-i[[:space:]]+inplace|perl[[:space:]]+-[^[:space:]]*i'; then
        echo "# Bash Blocked During Methodology Analysis

In-place file editing is not allowed during the methodology analysis phase." >&2
        exit 2
    fi
    # Block common interpreters that could write files (defense-in-depth)
    if echo "$COMMAND_LOWER" | grep -qE '(^|[[:space:];|&])(python[23]?|ruby|node|perl|php)[[:space:]]'; then
        echo "# Bash Blocked During Methodology Analysis

Running interpreters is not allowed during the methodology analysis phase." >&2
        exit 2
    fi
    # Block shell script entry points (bash script.sh, sh script.sh, source, .)
    if echo "$COMMAND_LOWER" | grep -qE '(^|[[:space:];|&])(/usr/bin/env[[:space:]]+)?(bash|sh|zsh|/bin/bash|/bin/sh|/bin/zsh)[[:space:]]'; then
        echo "# Bash Blocked During Methodology Analysis

Running shell scripts is not allowed during the methodology analysis phase." >&2
        exit 2
    fi
    # Block build tools that execute arbitrary commands
    if echo "$COMMAND_LOWER" | grep -qE '(^|[[:space:];|&])(make|cmake|ninja|gradle|mvn|ant|cargo|go[[:space:]]+run|go[[:space:]]+generate|npm[[:space:]]+run|yarn[[:space:]]+run|npx|pnpm)[[:space:]]'; then
        echo "# Bash Blocked During Methodology Analysis

Build tools are not allowed during the methodology analysis phase." >&2
        exit 2
    fi
    # Block source/dot commands (source script.sh, . script.sh)
    if echo "$COMMAND_LOWER" | grep -qE '(^|[[:space:];|&])(source|\.)[ 	]+[^[:space:]]'; then
        echo "# Bash Blocked During Methodology Analysis

Sourcing scripts is not allowed during the methodology analysis phase." >&2
        exit 2
    fi
    # Block direct script execution (./script.sh, ../script.sh, /path/to/script)
    if echo "$COMMAND_LOWER" | grep -qE '(^|[[:space:];|&])\.{0,2}/[^[:space:]>|&;]*\.(sh|bash|py|rb|pl|js)'; then
        echo "# Bash Blocked During Methodology Analysis

Direct script execution is not allowed during the methodology analysis phase." >&2
        exit 2
    fi
    # Block output redirection to files (catches cat > file, echo > file, etc.)
    # Strip safe redirections (/dev/ paths, fd duplication) then check for remaining >
    _ma_stripped=$(echo "$COMMAND_LOWER" | sed 's|[0-9]*>[>]*[[:space:]]*/dev/[^[:space:]]*||g; s|[0-9]*>&[0-9]*||g')
    if echo "$_ma_stripped" | grep -qE '[>]'; then
        echo "# Bash Blocked During Methodology Analysis

File redirection is not allowed during the methodology analysis phase." >&2
        exit 2
    fi
fi

# If no active RLCR loop, allow all commands
if [[ -z "$ACTIVE_LOOP_DIR" ]]; then
    exit 0
fi

# ========================================
# Block Direct Execution of Hook Scripts
# ========================================
# Prevents Claude from manually running stop hook or stop gate scripts.
# These scripts should only be invoked by the hooks system, not via Bash.

BLOCKED_HOOK_SCRIPTS="(loop-codex-stop-hook\.sh|rlcr-stop-gate\.sh)"
HOOK_ASSIGNMENT_PREFIX="[[:alpha:]_][[:alnum:]_]*=[^[:space:];&|]+"
HOOK_COMMAND_PREFIX="command([[:space:]]+(-[^[:space:];&|]+|--))*"
HOOK_ENV_PREFIX="env([[:space:]]+(-[^[:space:];&|]+|--|${HOOK_ASSIGNMENT_PREFIX}))*"
HOOK_UTILITY_ARG="[^[:space:];&|]+"
HOOK_TIMEOUT_OPTION="(-[^[:space:];&|]+([[:space:]]+${HOOK_UTILITY_ARG})?|--([^[:space:];&|]+(=${HOOK_UTILITY_ARG}|[[:space:]]+${HOOK_UTILITY_ARG})?)?)"
HOOK_NICE_OPTION="(-n([[:space:]]+${HOOK_UTILITY_ARG})?|--adjustment(=${HOOK_UTILITY_ARG}|[[:space:]]+${HOOK_UTILITY_ARG})|-[^[:space:];&|]+|--[^[:space:];&|]+)"
HOOK_TRACE_OPTION="(-[^[:space:];&|]+([[:space:]]+${HOOK_UTILITY_ARG})?|--([^[:space:];&|]+(=${HOOK_UTILITY_ARG}|[[:space:]]+${HOOK_UTILITY_ARG})?)?)"
HOOK_TIMEOUT_PREFIX="timeout([[:space:]]+(${HOOK_TIMEOUT_OPTION}))*([[:space:]]+--)?[[:space:]]+${HOOK_UTILITY_ARG}"
HOOK_NICE_PREFIX="nice([[:space:]]+(${HOOK_NICE_OPTION}))*([[:space:]]+--)?"
HOOK_NOHUP_PREFIX="nohup"
HOOK_TRACE_PREFIX="(strace|ltrace)([[:space:]]+(${HOOK_TRACE_OPTION}))*([[:space:]]+--)?"
HOOK_UTILITY_PREFIX="(${HOOK_TIMEOUT_PREFIX}|${HOOK_NICE_PREFIX}|${HOOK_NOHUP_PREFIX}|${HOOK_TRACE_PREFIX})"
HOOK_WRAPPER_PREFIX_PATTERN="((${HOOK_ASSIGNMENT_PREFIX}|${HOOK_COMMAND_PREFIX}|${HOOK_ENV_PREFIX}|${HOOK_UTILITY_PREFIX})[[:space:]]+)*"
HOOK_LAUNCH_PATTERN="(([^[:space:]]*/)?|(bash|sh|zsh|source|\.)[[:space:]].*)$BLOCKED_HOOK_SCRIPTS"
if echo "$COMMAND_LOWER" | grep -qE "(^|[;&|])[[:space:]]*${HOOK_WRAPPER_PREFIX_PATTERN}${HOOK_LAUNCH_PATTERN}"; then
    stop_hook_direct_execution_blocked_message >&2
    exit 2
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

if command_modifies_file "$COMMAND_LOWER" "methodology-analysis-state\.md"; then
    # Check for cancel signal file - allow authorized cancel operation
    if is_cancel_authorized "$ACTIVE_LOOP_DIR" "$COMMAND_LOWER"; then
        exit 0
    fi
    methodology_analysis_state_file_blocked_message >&2
    exit 2
fi

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
MV_CP_METHODOLOGY_SOURCE_PATTERN="^[[:space:]]*(sudo([[:space:]]+-?[^[:space:];&|]+)*[[:space:]]+)?(env[[:space:]]+[^;&|]*[[:space:]]+)?(command([[:space:]]+-?[^[:space:];&|]+)*[[:space:]]+)?(mv|cp)[[:space:]].*[[:space:]/\"']methodology-analysis-state\.md"

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

    # Check for methodology-analysis-state.md as SOURCE first (most specific pattern)
    if echo "$SEGMENT_CLEANED" | grep -qE "$MV_CP_METHODOLOGY_SOURCE_PATTERN"; then
        # Check for cancel signal file - allow authorized cancel operation
        if is_cancel_authorized "$ACTIVE_LOOP_DIR" "$COMMAND_LOWER"; then
            exit 0
        fi
        methodology_analysis_state_file_blocked_message >&2
        exit 2
    fi

    # Check for finalize-state.md as SOURCE (more specific than state.md)
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
    # Shell wrapper detected - check if payload contains mv/cp methodology-analysis-state.md (most specific)
    if echo "$COMMAND_LOWER" | grep -qE "(mv|cp)[[:space:]].*methodology-analysis-state\.md"; then
        if is_cancel_authorized "$ACTIVE_LOOP_DIR" "$COMMAND_LOWER"; then
            exit 0
        fi
        methodology_analysis_state_file_blocked_message >&2
        exit 2
    fi
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
    GOAL_TRACKER_PATH="$ACTIVE_LOOP_DIR/goal-tracker.md"
    if [[ "$CURRENT_ROUND" -eq 0 ]]; then
        goal_tracker_bash_blocked_message "$GOAL_TRACKER_PATH" >&2
    else
        goal_tracker_blocked_message "$CURRENT_ROUND" "$GOAL_TRACKER_PATH" >&2
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
# Block Round Contract File Modifications (All Rounds)
# ========================================
# Round contracts should be written using Write or Edit tools so round scoping
# stays aligned with the current loop state.

if command_modifies_file "$COMMAND_LOWER" "round-[0-9]+-contract\.md"; then
    CORRECT_PATH="$ACTIVE_LOOP_DIR/round-${CURRENT_ROUND}-contract.md"
    FALLBACK="# Round Contract Bash Write Blocked

Do not use Bash commands to modify round contract files.
Use the Write or Edit tool instead: {{CORRECT_PATH}}"
    load_and_render_safe "$TEMPLATE_DIR" "block/round-contract-bash-write.md" "$FALLBACK" \
        "CORRECT_PATH=$CORRECT_PATH" >&2
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

exit 0
