#!/bin/bash
#
# PreToolUse Hook: Validate Read access for RLCR loop files
#
# Blocks Claude from reading:
# - Wrong round's prompt/summary files (outdated information)
# - Round files from wrong locations (not in .humanize-rlcr.local/)
# - Round files from old session directories
# - Todos files (should use native TodoWrite instead)
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

if [[ "$TOOL_NAME" != "Read" ]]; then
    exit 0
fi

FILE_PATH=$(echo "$HOOK_INPUT" | jq -r '.tool_input.file_path // ""')
FILE_PATH_LOWER=$(to_lower "$FILE_PATH")

# ========================================
# Block Todos Files
# ========================================

if is_round_file_type "$FILE_PATH_LOWER" "todos"; then
    todos_blocked_message "Read" >&2
    exit 2
fi

# ========================================
# Check for Round Files (summary/prompt)
# ========================================

IS_ROUND_FILE=false
CLAUDE_FILENAME=""

if is_round_file_type "$FILE_PATH_LOWER" "summary" || is_round_file_type "$FILE_PATH_LOWER" "prompt"; then
    IS_ROUND_FILE=true
    CLAUDE_FILENAME=$(basename "$FILE_PATH")
fi

if [[ "$IS_ROUND_FILE" == "false" ]]; then
    exit 0
fi

# Check if path contains .humanize-rlcr.local
IN_HUMANIZE_LOOP_DIR=false
if is_in_humanize_loop_dir "$FILE_PATH"; then
    IN_HUMANIZE_LOOP_DIR=true
fi

# ========================================
# Find Active Loop and Current Round
# ========================================

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
LOOP_BASE_DIR="$PROJECT_ROOT/.humanize-rlcr.local"
ACTIVE_LOOP_DIR=$(find_active_loop "$LOOP_BASE_DIR")

if [[ -z "$ACTIVE_LOOP_DIR" ]]; then
    exit 0
fi

CURRENT_ROUND=$(get_current_round "$ACTIVE_LOOP_DIR/rlcr-state.md")

# ========================================
# Extract Round Number and File Type
# ========================================

CLAUDE_ROUND=$(extract_round_number "$CLAUDE_FILENAME")
if [[ -z "$CLAUDE_ROUND" ]]; then
    exit 0
fi

# Determine file type from filename
FILE_TYPE=""
if is_round_file_type "$FILE_PATH_LOWER" "summary"; then
    FILE_TYPE="summary"
elif is_round_file_type "$FILE_PATH_LOWER" "prompt"; then
    FILE_TYPE="prompt"
fi

# ========================================
# Validate File Location
# ========================================

if [[ "$IN_HUMANIZE_LOOP_DIR" == "false" ]]; then
    CORRECT_PATH="$ACTIVE_LOOP_DIR/round-${CURRENT_ROUND}-${FILE_TYPE}.md"
    cat >&2 << EOF
# Wrong File Location

You are trying to read \`$FILE_PATH\`, but loop files are in \`$ACTIVE_LOOP_DIR/\`.

**Current round files**:
- Prompt: \`$ACTIVE_LOOP_DIR/round-${CURRENT_ROUND}-prompt.md\`
- Summary: \`$ACTIVE_LOOP_DIR/round-${CURRENT_ROUND}-summary.md\`

If you need this file, use: \`cat $FILE_PATH\`
EOF
    exit 2
fi

# ========================================
# Validate Round Number
# ========================================

if [[ "$CLAUDE_ROUND" != "$CURRENT_ROUND" ]]; then
    cat >&2 << EOF
# Wrong Round File

You are trying to read \`round-${CLAUDE_ROUND}-${FILE_TYPE}.md\`, but the current round is **${CURRENT_ROUND}**.

**Current round files**:
- Prompt: \`$ACTIVE_LOOP_DIR/round-${CURRENT_ROUND}-prompt.md\`
- Summary: \`$ACTIVE_LOOP_DIR/round-${CURRENT_ROUND}-summary.md\`

If you need this file, use: \`cat $FILE_PATH\`
EOF
    exit 2
fi

# ========================================
# Validate Directory Path
# ========================================

CORRECT_PATH="$ACTIVE_LOOP_DIR/$CLAUDE_FILENAME"

if [[ "$FILE_PATH" != "$CORRECT_PATH" ]]; then
    cat >&2 << EOF
# Wrong Directory Path

You are trying to read: \`$FILE_PATH\`
Correct path: \`$CORRECT_PATH\`

If you need this file, use: \`cat $FILE_PATH\`
EOF
    exit 2
fi

exit 0
