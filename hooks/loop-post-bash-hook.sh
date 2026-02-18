#!/bin/bash
#
# PostToolUse Bash Hook for RLCR loop
#
# Records the Claude Code session_id into state.md immediately after setup.
# This hook fires right after the setup script's Bash command completes.
#
# Mechanism:
# 1. Setup script creates .humanize/.pending-session-id with:
#    Line 1: path to state.md
#    Line 2: full resolved path of setup script (command signature)
# 2. This hook checks for the signal file on every Bash PostToolUse event
# 3. Boundary-aware match: verifies the Bash command is a valid invocation
#    of the setup script path (path followed by end-of-string or whitespace),
#    preventing false positives from substrings and concatenated forms
# 4. Extracts session_id from hook JSON input
# 5. Patches state.md with the session_id value using safe awk replacement
# 6. Removes the signal file (one-shot mechanism)
#
# This ensures session_id is recorded BEFORE any team members can be created,
# so only the team leader (main session) is affected by RLCR loop hooks.
#

set -euo pipefail

# Read hook JSON input from stdin
HOOK_INPUT=$(cat)

# Determine project root
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Check for pending session_id signal file
SIGNAL_FILE="$PROJECT_ROOT/.humanize/.pending-session-id"

if [[ ! -f "$SIGNAL_FILE" ]]; then
    # No pending session_id to record - this is the normal case
    exit 0
fi

# Read the signal file contents
# Line 1: state file path
# Line 2: full resolved path of setup script (command signature)
STATE_FILE_PATH=""
COMMAND_SIGNATURE=""
{
    read -r STATE_FILE_PATH || true
    read -r COMMAND_SIGNATURE || true
} < "$SIGNAL_FILE"

if [[ -z "$STATE_FILE_PATH" ]] || [[ ! -f "$STATE_FILE_PATH" ]]; then
    # Signal file is empty or points to non-existent state file - clean up
    rm -f "$SIGNAL_FILE"
    exit 0
fi

# Verify the Bash command is a real setup script invocation (not arbitrary text)
# The command signature is the full resolved path of setup-rlcr-loop.sh.
# We require the command to START with this path (quoted or unquoted),
# preventing false positives like 'echo setup-rlcr-loop.sh' from consuming the signal.
if [[ -n "$COMMAND_SIGNATURE" ]]; then
    HOOK_COMMAND=""
    if command -v jq >/dev/null 2>&1; then
        HOOK_COMMAND=$(printf '%s' "$HOOK_INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")
    fi

    if [[ -z "$HOOK_COMMAND" ]]; then
        exit 0
    fi

    # Boundary-aware match: command must be a valid setup invocation form.
    # Requires the script path to be followed by end-of-string or any POSIX
    # whitespace ([[:space:]]), preventing concatenated forms.
    # Accepts: "/full/path/setup-rlcr-loop.sh" args  (quoted, space-delimited)
    #          "/full/path/setup-rlcr-loop.sh"\targs  (quoted, tab-delimited)
    #          "/full/path/setup-rlcr-loop.sh"        (quoted, no args)
    #          /full/path/setup-rlcr-loop.sh args     (unquoted, space-delimited)
    #          /full/path/setup-rlcr-loop.sh\targs    (unquoted, tab-delimited)
    #          /full/path/setup-rlcr-loop.sh           (unquoted, no args)
    # Rejects: "/full/path/setup-rlcr-loop.sh"foo     (no boundary after quote)
    #          echo /full/path/setup-rlcr-loop.sh      (does not start with path)
    IS_SETUP="false"
    if [[ "$HOOK_COMMAND" == "\"${COMMAND_SIGNATURE}\"" ]] || [[ "$HOOK_COMMAND" == "\"${COMMAND_SIGNATURE}\""[[:space:]]* ]]; then
        IS_SETUP="true"
    elif [[ "$HOOK_COMMAND" == "${COMMAND_SIGNATURE}" ]] || [[ "$HOOK_COMMAND" == "${COMMAND_SIGNATURE}"[[:space:]]* ]]; then
        IS_SETUP="true"
    fi

    if [[ "$IS_SETUP" != "true" ]]; then
        # This Bash event is not from the setup script - do not consume signal
        exit 0
    fi
fi

# Extract session_id from the hook JSON input
SESSION_ID=""
if command -v jq >/dev/null 2>&1; then
    SESSION_ID=$(printf '%s' "$HOOK_INPUT" | jq -r '.session_id // empty' 2>/dev/null || echo "")
fi

if [[ -z "$SESSION_ID" ]]; then
    # No session_id available in hook input - leave signal file for next attempt
    exit 0
fi

# Patch state.md: replace empty session_id with actual value
# Only patch if session_id is currently empty (safety check)
CURRENT_SESSION_ID=$(grep "^session_id:" "$STATE_FILE_PATH" 2>/dev/null | sed 's/session_id: *//' || echo "")

if [[ -z "$CURRENT_SESSION_ID" ]]; then
    # Use awk for safe replacement (handles special chars in SESSION_ID: /, &, etc.)
    TEMP_FILE="${STATE_FILE_PATH}.tmp.$$"
    awk -v new_id="$SESSION_ID" '{
        if ($0 ~ /^session_id:$/) {
            print "session_id: " new_id
        } else {
            print
        }
    }' "$STATE_FILE_PATH" > "$TEMP_FILE"
    mv "$TEMP_FILE" "$STATE_FILE_PATH"
fi

# Remove signal file (one-shot: session_id is now recorded)
rm -f "$SIGNAL_FILE"

exit 0
