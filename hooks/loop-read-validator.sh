#!/bin/bash
#
# PreToolUse Hook: Validate Read access for RLCR loop and PR loop files
#
# Blocks Claude from reading:
# - Wrong round's prompt/summary files (outdated information)
# - Round files from wrong locations (not in .humanize/rlcr/)
# - Round files from old session directories
# - Todos files (should use native Task tools instead)
#
# PR loop files (.humanize/pr-loop/) are generally allowed to read
# to give Claude access to comments, prompts, and feedback.
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

if [[ "$TOOL_NAME" != "Read" ]]; then
    exit 0
fi

# Require file_path for Read tool
if ! require_tool_input_field "$HOOK_INPUT" "file_path"; then
    exit 1
fi

FILE_PATH=$(echo "$HOOK_INPUT" | jq -r '.tool_input.file_path // ""')
FILE_PATH_LOWER=$(to_lower "$FILE_PATH")

# Extract session_id from hook input for session-aware loop filtering
HOOK_SESSION_ID=$(extract_session_id "$HOOK_INPUT")

# ========================================
# Block Todos Files
# ========================================

if is_round_file_type "$FILE_PATH_LOWER" "todos"; then
    PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
    LOOP_BASE_DIR="$PROJECT_ROOT/.humanize/rlcr"
    LOOP_DIR=$(find_active_loop "$LOOP_BASE_DIR" "$HOOK_SESSION_ID")
    if [[ -z "$LOOP_DIR" ]] || ! is_allowlisted_file "$FILE_PATH" "$LOOP_DIR"; then
        todos_blocked_message "Read" >&2
        exit 2
    fi
fi

# ========================================
# Methodology Analysis Phase Read Restriction
# ========================================
# During methodology analysis, restrict reads of files within the loop
# directory to only the artifacts the analysis agent needs. This prevents
# project-specific information from leaking into the analysis report.
# Files outside the loop directory are allowed (Claude needs system files).
# This check MUST come before the summary/prompt early exit below,
# otherwise non-summary/prompt files in the loop dir escape restriction.

PROJECT_ROOT="${PROJECT_ROOT:-${CLAUDE_PROJECT_DIR:-$(pwd)}}"
LOOP_BASE_DIR="${LOOP_BASE_DIR:-$PROJECT_ROOT/.humanize/rlcr}"
# Use only the session-matched loop. Do NOT fall back to an unfiltered search,
# as that would incorrectly restrict unrelated sessions opened in the same repo.
# Limitation: Spawned agents (different session_id) are not restricted by hooks;
# their sanitization is enforced by the analysis prompt.
ACTIVE_LOOP_DIR="${LOOP_DIR:-$(find_active_loop "$LOOP_BASE_DIR" "$HOOK_SESSION_ID")}"
_MA_CHECK_DIR="$ACTIVE_LOOP_DIR"

if [[ -n "$_MA_CHECK_DIR" ]]; then
    _MA_STATE=$(resolve_active_state_file "$_MA_CHECK_DIR")
    if [[ "$_MA_STATE" == *"/methodology-analysis-state.md" ]]; then
        # Canonicalize to prevent path traversal
        # If realpath fails (file doesn't exist yet on BSD/macOS), resolve parent dir
        _ma_real_path=$(realpath "$FILE_PATH" 2>/dev/null || echo "")
        if [[ -z "$_ma_real_path" ]]; then
            _ma_parent=$(realpath "$(dirname "$FILE_PATH")" 2>/dev/null || echo "")
            [[ -n "$_ma_parent" ]] && _ma_real_path="$_ma_parent/$(basename "$FILE_PATH")"
        fi
        _ma_real_loop=$(realpath "$_MA_CHECK_DIR" 2>/dev/null || echo "")
        # Fallback to raw paths when realpath is unavailable (older macOS/BSD)
        [[ -z "$_ma_real_path" ]] && _ma_real_path="$FILE_PATH"
        [[ -z "$_ma_real_loop" ]] && _ma_real_loop="$_MA_CHECK_DIR"
        if [[ "$_ma_real_path" == "$_ma_real_loop/"* ]]; then
            _ma_basename=$(basename "$_ma_real_path")
            # Allowlist: only methodology artifacts (not raw development records).
            # Raw records (round-*-summary.md, round-*-review-result.md) are
            # intentionally excluded so the originating session cannot read
            # project-specific content and must rely solely on the sanitized
            # methodology-analysis-report.md for all user-facing output.
            # The spawned Opus agent reads raw records directly (not restricted
            # by hooks due to different session_id -- see limitation comment above).
            case "$_ma_basename" in
                methodology-analysis-report.md|methodology-analysis-done.md|methodology-analysis-state.md)
                    exit 0
                    ;;
                *)
                    echo "# Read Blocked During Methodology Analysis

Only methodology artifacts can be read from the loop directory during this phase.
Allowed: methodology-analysis-report.md, methodology-analysis-done.md, methodology-analysis-state.md" >&2
                    exit 2
                    ;;
            esac
        fi
        # Files within the project root are blocked (project-specific information)
        # Files outside the project root are allowed (system files, config, etc.)
        _ma_project_real=$(realpath "$PROJECT_ROOT" 2>/dev/null || echo "$PROJECT_ROOT")
        if [[ -n "$_ma_project_real" ]]; then
            _ma_path_check="${_ma_real_path:-$FILE_PATH}"
            if [[ "$_ma_path_check" == "$_ma_project_real/"* ]] || \
               [[ "$_ma_path_check" == "$PROJECT_ROOT/"* ]]; then
                echo "# Read Blocked During Methodology Analysis

Reading project files is not allowed during the methodology analysis phase.
Only methodology artifacts within the loop directory can be read.
Allowed: methodology-analysis-report.md, methodology-analysis-done.md, methodology-analysis-state.md" >&2
                exit 2
            fi
        fi
        exit 0
    fi
fi

# ========================================
# Check for Round Files (summary/prompt)
# ========================================

if ! is_round_file_type "$FILE_PATH_LOWER" "summary" && ! is_round_file_type "$FILE_PATH_LOWER" "prompt"; then
    exit 0
fi

CLAUDE_FILENAME=$(basename "$FILE_PATH")
IN_HUMANIZE_LOOP_DIR=$(is_in_humanize_loop_dir "$FILE_PATH" && echo "true" || echo "false")

# ========================================
# Find Active Loop and Current Round
# ========================================

# Re-use ACTIVE_LOOP_DIR if already set by methodology analysis check above
ACTIVE_LOOP_DIR="${ACTIVE_LOOP_DIR:-${LOOP_DIR:-$(find_active_loop "$LOOP_BASE_DIR" "$HOOK_SESSION_ID")}}"

if [[ -z "$ACTIVE_LOOP_DIR" ]]; then
    exit 0
fi

# Detect loop phase from state file
STATE_FILE_TO_PARSE=$(resolve_active_state_file "$ACTIVE_LOOP_DIR")

# Parse state file using strict validation (fail closed on malformed state)
if ! parse_state_file_strict "$STATE_FILE_TO_PARSE" 2>/dev/null; then
    echo "Error: Malformed state file, blocking operation for safety" >&2
    exit 1
fi
CURRENT_ROUND="$STATE_CURRENT_ROUND"

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
    FALLBACK="# Wrong File Location

Reading {{FILE_PATH}} is blocked. Read from the active loop: {{ACTIVE_LOOP_DIR}}"
    load_and_render_safe "$TEMPLATE_DIR" "block/wrong-file-location.md" "$FALLBACK" \
        "FILE_PATH=$FILE_PATH" \
        "ACTIVE_LOOP_DIR=$ACTIVE_LOOP_DIR" \
        "CURRENT_ROUND=$CURRENT_ROUND" >&2
    exit 2
fi

# ========================================
# Validate Round Number
# ========================================

if [[ "$CLAUDE_ROUND" != "$CURRENT_ROUND" ]] && ! is_allowlisted_file "$FILE_PATH" "$ACTIVE_LOOP_DIR"; then
    FALLBACK="# Wrong Round File

You tried to read round-{{CLAUDE_ROUND}}-{{FILE_TYPE}}.md but current round is **{{CURRENT_ROUND}}**.

Read from: {{ACTIVE_LOOP_DIR}}"
    load_and_render_safe "$TEMPLATE_DIR" "block/wrong-round-file.md" "$FALLBACK" \
        "CLAUDE_ROUND=$CLAUDE_ROUND" \
        "FILE_TYPE=$FILE_TYPE" \
        "CURRENT_ROUND=$CURRENT_ROUND" \
        "ACTIVE_LOOP_DIR=$ACTIVE_LOOP_DIR" \
        "FILE_PATH=$FILE_PATH" >&2
    exit 2
fi

# ========================================
# Validate Directory Path
# ========================================

CORRECT_PATH="$ACTIVE_LOOP_DIR/$CLAUDE_FILENAME"

if [[ "$FILE_PATH" != "$CORRECT_PATH" ]]; then
    FALLBACK="# Wrong Directory Path

You tried to {{ACTION}} {{FILE_PATH}} but the correct path is {{CORRECT_PATH}}"
    load_and_render_safe "$TEMPLATE_DIR" "block/wrong-directory-path.md" "$FALLBACK" \
        "ACTION=read" \
        "FILE_PATH=$FILE_PATH" \
        "CORRECT_PATH=$CORRECT_PATH" >&2
    exit 2
fi

exit 0
