#!/bin/bash
#
# Common functions for RLCR loop hooks
#
# This library provides shared functionality used by:
# - loop-read-validator.sh
# - loop-write-validator.sh
# - loop-bash-validator.sh
#

# ========================================
# Constants
# ========================================

# State file field names
readonly FIELD_PLAN_TRACKED="plan_tracked"
readonly FIELD_START_BRANCH="start_branch"
readonly FIELD_BASE_BRANCH="base_branch"
readonly FIELD_BASE_COMMIT="base_commit"
readonly FIELD_PLAN_FILE="plan_file"
readonly FIELD_CURRENT_ROUND="current_round"
readonly FIELD_MAX_ITERATIONS="max_iterations"
readonly FIELD_PUSH_EVERY_ROUND="push_every_round"
readonly FIELD_CODEX_MODEL="codex_model"
readonly FIELD_CODEX_EFFORT="codex_effort"
readonly FIELD_CODEX_TIMEOUT="codex_timeout"
readonly FIELD_REVIEW_STARTED="review_started"
readonly FIELD_FULL_REVIEW_ROUND="full_review_round"

# Codex review markers
readonly MARKER_COMPLETE="COMPLETE"
readonly MARKER_STOP="STOP"

# Exit reasons (used with end_loop function)
# complete   - Codex confirmed all goals achieved (normal success)
# cancel     - User cancelled with /cancel-rlcr-loop
# maxiter    - Reached maximum iterations limit
# stop       - Codex triggered circuit breaker (stagnation detected)
# unexpected - System error or invalid state (e.g., corrupted state file)
readonly EXIT_COMPLETE="complete"
readonly EXIT_CANCEL="cancel"
readonly EXIT_MAXITER="maxiter"
readonly EXIT_STOP="stop"
readonly EXIT_UNEXPECTED="unexpected"

# ========================================
# JSON Input Validation
# ========================================

# Validate JSON input and extract tool_name
# Usage: validate_hook_input "$json_input"
# Returns: 0 if valid JSON with tool_name, 1 if invalid
# Sets: VALIDATED_TOOL_NAME, VALIDATED_TOOL_INPUT
#
# Non-UTF8 handling behavior:
# - Null bytes (0x00): Rejected with exit 1
# - Invalid UTF-8 sequences (0x80-0xFF outside valid UTF-8): Rejected by jq as invalid JSON
# - Valid UTF-8 non-ASCII characters: Accepted (jq handles Unicode correctly)
validate_hook_input() {
    local input="$1"

    # Reject null bytes (security) - portable check without grep -P (BSD incompatible)
    # tr -cd '\0' keeps only null bytes, wc -c counts them
    if [[ $(printf '%s' "$input" | tr -cd '\0' | wc -c) -gt 0 ]]; then
        echo "Error: Input contains null bytes" >&2
        return 1
    fi

    # Reject non-UTF8 bytes (security/consistency)
    # Check for bytes in 0x80-0xFF that are NOT part of valid UTF-8 sequences
    # Skip if iconv is not available (common in minimal containers like Alpine)
    if command -v iconv >/dev/null 2>&1; then
        if ! printf '%s' "$input" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1; then
            echo "Error: Input contains invalid UTF-8 sequences" >&2
            return 1
        fi
    fi

    # Validate JSON syntax with jq
    if ! printf '%s' "$input" | jq -e '.' >/dev/null 2>&1; then
        echo "Error: Invalid JSON syntax" >&2
        return 1
    fi

    # Extract tool_name (required)
    VALIDATED_TOOL_NAME=$(printf '%s' "$input" | jq -r '.tool_name // empty')
    if [[ -z "$VALIDATED_TOOL_NAME" ]]; then
        echo "Error: Missing required field: tool_name" >&2
        return 1
    fi

    # Extract tool_input (required for Read/Write/Bash)
    VALIDATED_TOOL_INPUT=$(printf '%s' "$input" | jq -r '.tool_input // empty')

    return 0
}

# Validate that a specific field exists in tool_input
# Usage: require_tool_input_field "$json_input" "field_name"
# Returns: 0 if field exists and is non-empty, 1 otherwise
require_tool_input_field() {
    local input="$1"
    local field="$2"

    local value
    value=$(printf '%s' "$input" | jq -r ".tool_input.$field // empty")

    if [[ -z "$value" ]]; then
        echo "Error: Missing required field: tool_input.$field" >&2
        return 1
    fi

    return 0
}

# Check if JSON is deeply nested (potential DoS)
# Usage: is_deeply_nested "$json_input" [max_depth]
# Returns: 0 if too deeply nested, 1 otherwise
is_deeply_nested() {
    local input="$1"
    local max_depth="${2:-30}"

    # Use jq to check depth - getpath on recursive descent gives us depth
    local actual_depth
    actual_depth=$(printf '%s' "$input" | jq '[paths | length] | max // 0' 2>/dev/null || echo "0")

    if [[ "$actual_depth" -gt "$max_depth" ]]; then
        echo "Error: JSON structure exceeds maximum depth of $max_depth (actual: $actual_depth)" >&2
        return 0
    fi

    return 1
}

# ========================================
# Library Setup
# ========================================

# Source template loader
LOOP_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$LOOP_COMMON_DIR/template-loader.sh"

# Initialize template directory (can be overridden by sourcing script)
TEMPLATE_DIR="${TEMPLATE_DIR:-$(get_template_dir "$LOOP_COMMON_DIR")}"

# Validate template directory exists (warn but don't fail - allows graceful degradation)
if ! validate_template_dir "$TEMPLATE_DIR" 2>/dev/null; then
    echo "Warning: Template directory validation failed. Using inline fallbacks." >&2
fi

# Find the most recent active loop directory
# Only checks the newest directory - older directories are ignored even if they have state.md
# This prevents "zombie" loops from being revived after abnormal exits
# Detects both state.md (normal loop) and finalize-state.md (Finalize Phase in progress)
# Outputs the directory path to stdout, or empty string if none found
find_active_loop() {
    local loop_base_dir="$1"

    if [[ ! -d "$loop_base_dir" ]]; then
        echo ""
        return
    fi

    # Get the newest directory (by timestamp name, descending)
    local newest_dir
    newest_dir=$(ls -1d "$loop_base_dir"/*/ 2>/dev/null | sort -r | head -1)

    # Check for active loop indicators: state.md (normal) or finalize-state.md (Finalize Phase)
    if [[ -n "$newest_dir" && ( -f "${newest_dir}state.md" || -f "${newest_dir}finalize-state.md" ) ]]; then
        echo "${newest_dir%/}"
    else
        echo ""
    fi
}

# Extract current round number from state.md
# Outputs the round number to stdout, defaults to 0
# Note: For full state parsing, use parse_state_file() instead
get_current_round() {
    local state_file="$1"

    local frontmatter
    frontmatter=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$state_file" 2>/dev/null || echo "")

    local current_round
    current_round=$(echo "$frontmatter" | grep "^${FIELD_CURRENT_ROUND}:" | sed "s/${FIELD_CURRENT_ROUND}: *//" | tr -d ' ')

    echo "${current_round:-0}"
}

# Parse state file frontmatter and set variables (tolerant mode with defaults)
# Usage: parse_state_file "$STATE_FILE"
# Sets the following variables (caller must declare them):
#   STATE_FRONTMATTER - raw frontmatter content
#   STATE_PLAN_TRACKED - "true" or "false"
#   STATE_START_BRANCH - branch name
#   STATE_BASE_BRANCH - base branch for code review
#   STATE_PLAN_FILE - plan file path
#   STATE_CURRENT_ROUND - current round number
#   STATE_MAX_ITERATIONS - max iterations
#   STATE_PUSH_EVERY_ROUND - "true" or "false"
#   STATE_CODEX_MODEL - codex model name
#   STATE_CODEX_EFFORT - codex effort level
#   STATE_CODEX_TIMEOUT - codex timeout in seconds
#   STATE_REVIEW_STARTED - "true" or "false"
#   STATE_FULL_REVIEW_ROUND - interval for Full Alignment Check (default: 5)
# Returns: 0 on success, 1 if file not found
# Note: For strict validation, use parse_state_file_strict() instead
parse_state_file() {
    local state_file="$1"

    if [[ ! -f "$state_file" ]]; then
        return 1
    fi

    STATE_FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$state_file" 2>/dev/null || echo "")

    # Parse fields with consistent quote handling
    # Legacy quote-stripping kept for backward compatibility with older state files
    STATE_PLAN_TRACKED=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_PLAN_TRACKED}:" | sed "s/${FIELD_PLAN_TRACKED}: *//" | tr -d ' ' || true)
    STATE_START_BRANCH=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_START_BRANCH}:" | sed "s/${FIELD_START_BRANCH}: *//; s/^\"//; s/\"\$//" || true)
    STATE_BASE_BRANCH=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_BASE_BRANCH}:" | sed "s/${FIELD_BASE_BRANCH}: *//; s/^\"//; s/\"\$//" || true)
    STATE_BASE_COMMIT=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_BASE_COMMIT}:" | sed "s/${FIELD_BASE_COMMIT}: *//; s/^\"//; s/\"\$//" || true)
    STATE_PLAN_FILE=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_PLAN_FILE}:" | sed "s/${FIELD_PLAN_FILE}: *//; s/^\"//; s/\"\$//" || true)
    STATE_CURRENT_ROUND=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_CURRENT_ROUND}:" | sed "s/${FIELD_CURRENT_ROUND}: *//" | tr -d ' ' || true)
    STATE_MAX_ITERATIONS=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_MAX_ITERATIONS}:" | sed "s/${FIELD_MAX_ITERATIONS}: *//" | tr -d ' ' || true)
    STATE_PUSH_EVERY_ROUND=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_PUSH_EVERY_ROUND}:" | sed "s/${FIELD_PUSH_EVERY_ROUND}: *//" | tr -d ' ' || true)
    STATE_CODEX_MODEL=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_CODEX_MODEL}:" | sed "s/${FIELD_CODEX_MODEL}: *//" | tr -d ' ' || true)
    STATE_CODEX_EFFORT=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_CODEX_EFFORT}:" | sed "s/${FIELD_CODEX_EFFORT}: *//" | tr -d ' ' || true)
    STATE_CODEX_TIMEOUT=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_CODEX_TIMEOUT}:" | sed "s/${FIELD_CODEX_TIMEOUT}: *//" | tr -d ' ' || true)
    STATE_REVIEW_STARTED=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_REVIEW_STARTED}:" | sed "s/${FIELD_REVIEW_STARTED}: *//" | tr -d ' ' || true)
    STATE_FULL_REVIEW_ROUND=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_FULL_REVIEW_ROUND}:" | sed "s/${FIELD_FULL_REVIEW_ROUND}: *//" | tr -d ' ' || true)

    # Apply defaults for non-schema-critical fields only
    # Note: review_started is NOT defaulted here so we can detect missing schema fields
    # and block with a proper message in the stop hook
    STATE_CURRENT_ROUND="${STATE_CURRENT_ROUND:-0}"
    STATE_MAX_ITERATIONS="${STATE_MAX_ITERATIONS:-10}"
    STATE_PUSH_EVERY_ROUND="${STATE_PUSH_EVERY_ROUND:-false}"
    STATE_FULL_REVIEW_ROUND="${STATE_FULL_REVIEW_ROUND:-5}"
    # STATE_REVIEW_STARTED left as-is (empty if missing, to allow schema validation)

    return 0
}

# Strict state file parser that rejects malformed files
# Usage: parse_state_file_strict "$STATE_FILE"
# Sets the same variables as parse_state_file()
# Returns: 0 on success, non-zero on validation failure
#   1 - file not found
#   2 - missing YAML frontmatter separators
#   3 - missing required field (current_round or max_iterations)
#   4 - non-numeric current_round value
#   5 - non-numeric max_iterations value
parse_state_file_strict() {
    local state_file="$1"

    if [[ ! -f "$state_file" ]]; then
        echo "Error: State file not found: $state_file" >&2
        return 1
    fi

    # Check for YAML frontmatter separators (must have at least two --- lines)
    local separator_count
    separator_count=$(grep -c '^---$' "$state_file" 2>/dev/null || echo "0")
    if [[ "$separator_count" -lt 2 ]]; then
        echo "Error: Missing YAML frontmatter separators (---)" >&2
        return 2
    fi

    # Extract frontmatter
    STATE_FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$state_file" 2>/dev/null || echo "")

    # Parse fields
    STATE_PLAN_TRACKED=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_PLAN_TRACKED}:" | sed "s/${FIELD_PLAN_TRACKED}: *//" | tr -d ' ' || true)
    STATE_START_BRANCH=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_START_BRANCH}:" | sed "s/${FIELD_START_BRANCH}: *//; s/^\"//; s/\"\$//" || true)
    STATE_BASE_BRANCH=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_BASE_BRANCH}:" | sed "s/${FIELD_BASE_BRANCH}: *//; s/^\"//; s/\"\$//" || true)
    STATE_BASE_COMMIT=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_BASE_COMMIT}:" | sed "s/${FIELD_BASE_COMMIT}: *//; s/^\"//; s/\"\$//" || true)
    STATE_PLAN_FILE=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_PLAN_FILE}:" | sed "s/${FIELD_PLAN_FILE}: *//; s/^\"//; s/\"\$//" || true)
    STATE_CURRENT_ROUND=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_CURRENT_ROUND}:" | sed "s/${FIELD_CURRENT_ROUND}: *//" | tr -d ' ' || true)
    STATE_MAX_ITERATIONS=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_MAX_ITERATIONS}:" | sed "s/${FIELD_MAX_ITERATIONS}: *//" | tr -d ' ' || true)
    STATE_PUSH_EVERY_ROUND=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_PUSH_EVERY_ROUND}:" | sed "s/${FIELD_PUSH_EVERY_ROUND}: *//" | tr -d ' ' || true)
    STATE_CODEX_MODEL=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_CODEX_MODEL}:" | sed "s/${FIELD_CODEX_MODEL}: *//" | tr -d ' ' || true)
    STATE_CODEX_EFFORT=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_CODEX_EFFORT}:" | sed "s/${FIELD_CODEX_EFFORT}: *//" | tr -d ' ' || true)
    STATE_CODEX_TIMEOUT=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_CODEX_TIMEOUT}:" | sed "s/${FIELD_CODEX_TIMEOUT}: *//" | tr -d ' ' || true)
    STATE_REVIEW_STARTED=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_REVIEW_STARTED}:" | sed "s/${FIELD_REVIEW_STARTED}: *//" | tr -d ' ' || true)
    STATE_FULL_REVIEW_ROUND=$(echo "$STATE_FRONTMATTER" | grep "^${FIELD_FULL_REVIEW_ROUND}:" | sed "s/${FIELD_FULL_REVIEW_ROUND}: *//" | tr -d ' ' || true)

    # Validate required fields exist
    if [[ -z "$STATE_CURRENT_ROUND" ]]; then
        echo "Error: Missing required field: current_round" >&2
        return 3
    fi
    if [[ -z "$STATE_MAX_ITERATIONS" ]]; then
        echo "Error: Missing required field: max_iterations" >&2
        return 3
    fi
    if [[ -z "$STATE_REVIEW_STARTED" ]]; then
        echo "Error: Missing required field: review_started" >&2
        return 3
    fi
    if [[ -z "$STATE_BASE_BRANCH" ]]; then
        echo "Error: Missing required field: base_branch" >&2
        return 3
    fi

    # Validate current_round is numeric (including 0 and negative)
    if ! [[ "$STATE_CURRENT_ROUND" =~ ^-?[0-9]+$ ]]; then
        echo "Error: Non-numeric current_round value: $STATE_CURRENT_ROUND" >&2
        return 4
    fi

    # Validate max_iterations is numeric
    if ! [[ "$STATE_MAX_ITERATIONS" =~ ^-?[0-9]+$ ]]; then
        echo "Error: Non-numeric max_iterations value: $STATE_MAX_ITERATIONS" >&2
        return 5
    fi

    # Validate review_started is boolean
    if [[ "$STATE_REVIEW_STARTED" != "true" && "$STATE_REVIEW_STARTED" != "false" ]]; then
        echo "Error: Invalid review_started value (must be true or false): $STATE_REVIEW_STARTED" >&2
        return 6
    fi

    # Apply defaults for optional fields only
    STATE_PUSH_EVERY_ROUND="${STATE_PUSH_EVERY_ROUND:-false}"
    STATE_FULL_REVIEW_ROUND="${STATE_FULL_REVIEW_ROUND:-5}"

    return 0
}

# Detect review issues from codex review log file
# Returns:
#   0 - issues found (caller should continue review loop)
#   1 - no issues found (caller can proceed to finalize)
#   2 - log file missing/empty (hard error - caller must block and require retry)
# Outputs: extracted review content to stdout if issues found
# Arguments: $1=round_number
# Required globals: LOOP_DIR, CACHE_DIR
#
# Algorithm:
# 1. Scan the entire log file for [P?] markers in the first 10 characters of each line
# 2. Find the first line where [P?] (? is a digit) appears in the first 10 characters
# 3. If found: extract from that line to the end and output it
# 4. If not found: no issues, return 1
#
# Note: codex review outputs to stderr, so we analyze the combined log file
# which contains both stdout and stderr (redirected with 2>&1).
detect_review_issues() {
    local round="$1"
    local log_file="$CACHE_DIR/round-${round}-codex-review.log"
    local result_file="$LOOP_DIR/round-${round}-review-result.md"

    # Check if log file exists and is not empty
    if [[ ! -f "$log_file" || ! -s "$log_file" ]]; then
        echo "Error: Codex review log file not found or empty: $log_file" >&2
        return 2
    fi

    local total_lines
    total_lines=$(wc -l < "$log_file")
    echo "Analyzing log file: $log_file ($total_lines lines)" >&2

    # Use awk to find the first line where [P?] appears in the first 10 characters
    # This is more efficient than a shell while loop with sed per line
    local found_line
    found_line=$(awk '
        substr($0, 1, 10) ~ /\[P[0-9]\]/ {
            print NR
            exit
        }
    ' "$log_file")

    if [[ -n "$found_line" && "$found_line" -gt 0 ]]; then
        echo "Found [P?] issue at line $found_line" >&2

        # Extract from found_line to end
        local extracted_content
        extracted_content=$(sed -n "${found_line},\$p" "$log_file")

        # Save to result file for audit purposes
        printf '%s\n' "$extracted_content" > "$result_file"
        echo "Review issues extracted to: $result_file" >&2

        # Output the content for the caller
        printf '## Codex Review Issues\n\n%s\n' "$extracted_content"
        return 0
    fi

    echo "No [P?] issues found in log file" >&2
    return 1
}

# Convert a string to lowercase
to_lower() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

# Check if a path (lowercase) matches a round file pattern
# Usage: is_round_file "$lowercase_path" "summary|prompt|todos"
is_round_file_type() {
    local path_lower="$1"
    local file_type="$2"

    echo "$path_lower" | grep -qE "round-[0-9]+-${file_type}\\.md\$"
}

# Extract round number from a filename
# Usage: extract_round_number "round-5-summary.md"
# Outputs the round number or empty string
extract_round_number() {
    local filename="$1"
    local filename_lower
    filename_lower=$(to_lower "$filename")

    # Use sed for portable regex extraction (works in both bash and zsh)
    echo "$filename_lower" | sed -n 's/.*round-\([0-9][0-9]*\)-\(summary\|prompt\|todos\)\.md$/\1/p'
}

# Check if a file is in the allowlist for the active loop
# Usage: is_allowlisted_file "$file_path" "$active_loop_dir"
# Returns: 0 if allowlisted, 1 otherwise
is_allowlisted_file() {
    local file_path="$1"
    local active_loop_dir="$2"

    local allowlist=(
        "round-1-todos.md"
        "round-2-todos.md"
        "round-0-summary.md"
        "round-1-summary.md"
    )

    for allowed in "${allowlist[@]}"; do
        if [[ "$file_path" == "$active_loop_dir/$allowed" ]]; then
            return 0
        fi
    done

    return 1
}

# Standard message for blocking todos file access
# Usage: todos_blocked_message "Read|Write|Bash"
todos_blocked_message() {
    local action="$1"
    local fallback="# Todos File Access Blocked

Do NOT create or access round-*-todos.md files. Use the native TodoWrite tool instead."

    load_and_render_safe "$TEMPLATE_DIR" "block/todos-file-access.md" "$fallback"
}

# Standard message for blocking prompt file writes
prompt_write_blocked_message() {
    local fallback="# Prompt File Write Blocked

You cannot write to round-*-prompt.md files. These contain instructions FROM Codex TO you."

    load_and_render_safe "$TEMPLATE_DIR" "block/prompt-file-write.md" "$fallback"
}

# Standard message for blocking state file modifications
state_file_blocked_message() {
    local fallback="# State File Modification Blocked

You cannot modify state.md. This file is managed by the loop system."

    load_and_render_safe "$TEMPLATE_DIR" "block/state-file-modification.md" "$fallback"
}

# Standard message for blocking finalize-state file modifications
finalize_state_file_blocked_message() {
    local fallback="# Finalize State File Modification Blocked

You cannot modify finalize-state.md. This file is managed by the loop system during the Finalize Phase."

    load_and_render_safe "$TEMPLATE_DIR" "block/finalize-state-file-modification.md" "$fallback"
}

# Standard message for blocking summary file modifications via Bash
# Usage: summary_bash_blocked_message "$correct_summary_path"
summary_bash_blocked_message() {
    local correct_path="$1"
    local fallback="# Bash Write Blocked

Do not use Bash commands to modify summary files. Use the Write or Edit tool instead: {{CORRECT_PATH}}"

    load_and_render_safe "$TEMPLATE_DIR" "block/summary-bash-write.md" "$fallback" "CORRECT_PATH=$correct_path"
}

# Standard message for blocking goal-tracker modifications via Bash in Round 0
# Usage: goal_tracker_bash_blocked_message "$correct_goal_tracker_path"
goal_tracker_bash_blocked_message() {
    local correct_path="$1"
    local fallback="# Bash Write Blocked

Do not use Bash commands to modify goal-tracker.md. Use the Write or Edit tool instead: {{CORRECT_PATH}}"

    load_and_render_safe "$TEMPLATE_DIR" "block/goal-tracker-bash-write.md" "$fallback" "CORRECT_PATH=$correct_path"
}

# Check if a path (lowercase) targets goal-tracker.md
is_goal_tracker_path() {
    local path_lower="$1"
    echo "$path_lower" | grep -qE 'goal-tracker\.md$'
}

# Check if a path (lowercase) targets state.md
is_state_file_path() {
    local path_lower="$1"
    echo "$path_lower" | grep -qE 'state\.md$'
}

# Check if a path (lowercase) targets finalize-state.md
is_finalize_state_file_path() {
    local path_lower="$1"
    echo "$path_lower" | grep -qE 'finalize-state\.md$'
}

# Check if a path (lowercase) targets finalize-summary.md
is_finalize_summary_path() {
    local path_lower="$1"
    echo "$path_lower" | grep -qE 'finalize-summary\.md$'
}

# Normalize paths by removing /./ and collapsing // to /
# This allows paths like /path/to/./state.md to match /path/to/state.md
_normalize_path() {
    echo "$1" | sed 's|/\./|/|g; s|//|/|g'
}

# Check if cancel operation is authorized via signal file
# Usage: is_cancel_authorized "$active_loop_dir" "$command_lower"
# Returns: 0 if authorized, non-zero otherwise
#   1 - missing signal file
#   2 - security violation (injection, command substitution, etc.)
#   3 - mixed quote styles
#   4 - multiple trailing spaces
#   5 - invalid command structure
#   6 - source file is a symlink (filesystem check)
#
# Security notes:
# - Normalizes $loop_dir/${loop_dir} to actual path before validation
# - Rejects $(cmd) command substitution and backticks
# - Rejects any remaining $ after normalization (prevents hidden vars like ${IFS})
# - Enforces exactly two arguments: state.md or finalize-state.md source and cancel-state.md dest
# - Rejects shell operators for command chaining
# - Rejects mixed quote styles and multiple trailing spaces
# - Rejects if source file is a symlink
is_cancel_authorized() {
    local active_loop_dir="$1"
    local command_lower="$2"

    local cancel_signal="$active_loop_dir/.cancel-requested"

    # Signal file must exist
    if [[ ! -f "$cancel_signal" ]]; then
        return 1
    fi

    # SECURITY: Reject command substitution and backticks
    if echo "$command_lower" | grep -qE '\$\(|`'; then
        return 2
    fi

    # Reject newlines (multi-command injection)
    if [[ "$command_lower" == *$'\n'* ]]; then
        return 2
    fi

    # Reject shell operators for command chaining
    if echo "$command_lower" | grep -qE ';|&&|\|\||\|'; then
        return 2
    fi

    # Reject multiple trailing spaces
    if echo "$command_lower" | grep -qE '[[:space:]]{2,}$'; then
        return 4
    fi

    # Normalize: Replace $loop_dir and ${loop_dir} with actual path
    local normalized="$command_lower"
    local loop_dir_lower
    loop_dir_lower="${active_loop_dir%/}/"
    loop_dir_lower=$(echo "$loop_dir_lower" | tr '[:upper:]' '[:lower:]')

    normalized="${normalized//\$\{loop_dir\}/$loop_dir_lower}"
    normalized="${normalized//\$loop_dir/$loop_dir_lower}"

    # After normalization, reject any remaining $ (prevents hidden vars like ${IFS})
    if echo "$normalized" | grep -qE '\$'; then
        return 2
    fi

    # Must start with mv followed by space
    if ! echo "$normalized" | grep -qE '^mv[[:space:]]+'; then
        return 5
    fi

    # Extract arguments after "mv "
    local args
    args=$(echo "$normalized" | sed 's/^mv[[:space:]]*//')

    # Detect quote types used in both arguments
    # Check for mixed quotes by detecting if both ' and " are used as delimiters
    local has_single=false has_double=false
    local first_char
    first_char=$(echo "$args" | cut -c1)
    if [[ "$first_char" == '"' ]]; then
        has_double=true
    elif [[ "$first_char" == "'" ]]; then
        has_single=true
    fi

    # Skip first argument to check second
    local args_after_first
    if [[ "$first_char" == '"' ]]; then
        args_after_first=$(echo "$args" | sed 's/^"[^"]*"[[:space:]]*//')
    elif [[ "$first_char" == "'" ]]; then
        args_after_first=$(echo "$args" | sed "s/^'[^']*'[[:space:]]*//")
    else
        args_after_first=$(echo "$args" | sed 's/^[^[:space:]]*[[:space:]]*//')
    fi

    local second_char
    second_char=$(echo "$args_after_first" | cut -c1)
    if [[ "$second_char" == '"' ]]; then
        has_double=true
    elif [[ "$second_char" == "'" ]]; then
        has_single=true
    fi

    # Reject mixed quote styles
    if [[ "$has_single" == "true" ]] && [[ "$has_double" == "true" ]]; then
        return 3
    fi

    # Parse arguments, respecting quotes
    local src dest
    if echo "$args" | grep -qE "^[\"']"; then
        local quote_char
        quote_char=$(echo "$args" | cut -c1)
        if [[ "$quote_char" == '"' ]]; then
            src=$(echo "$args" | sed -n 's/^"\([^"]*\)".*/\1/p')
            args=$(echo "$args" | sed 's/^"[^"]*"[[:space:]]*//')
        else
            src=$(echo "$args" | sed -n "s/^'\\([^']*\\)'.*/\\1/p")
            args=$(echo "$args" | sed "s/^'[^']*'[[:space:]]*//")
        fi
    else
        src=$(echo "$args" | sed 's/[[:space:]].*//')
        args=$(echo "$args" | sed 's/^[^[:space:]]*[[:space:]]*//')
    fi

    if echo "$args" | grep -qE "^[\"']"; then
        local quote_char
        quote_char=$(echo "$args" | cut -c1)
        if [[ "$quote_char" == '"' ]]; then
            dest=$(echo "$args" | sed -n 's/^"\([^"]*\)".*/\1/p')
            args=$(echo "$args" | sed 's/^"[^"]*"[[:space:]]*//')
        else
            dest=$(echo "$args" | sed -n "s/^'\\([^']*\\)'.*/\\1/p")
            args=$(echo "$args" | sed "s/^'[^']*'[[:space:]]*//")
        fi
    else
        dest=$(echo "$args" | sed 's/[[:space:]].*//')
        args=$(echo "$args" | sed 's/^[^[:space:]]*//')
    fi

    if [[ -z "$src" ]] || [[ -z "$dest" ]]; then
        return 5
    fi

    # Check for extra arguments
    args=$(echo "$args" | sed 's/^[[:space:]]*//')
    if [[ -n "$args" ]]; then
        return 5
    fi

    # Normalize and validate source path
    src=$(_normalize_path "$src")
    local expected_src_state="${loop_dir_lower}state.md"
    local expected_src_finalize="${loop_dir_lower}finalize-state.md"
    if [[ "$src" != "$expected_src_state" ]] && [[ "$src" != "$expected_src_finalize" ]]; then
        return 5
    fi

    # Normalize and validate destination path
    dest=$(_normalize_path "$dest")
    local expected_dest="${loop_dir_lower}cancel-state.md"
    if [[ "$dest" != "$expected_dest" ]]; then
        return 5
    fi

    # SECURITY: Reject if source file is a symlink (filesystem check)
    # Determine source file by comparing against expected paths (not substring match)
    # This avoids vulnerability when loop directory path contains "finalize"
    local src_original
    if [[ "$src" == "$expected_src_finalize" ]]; then
        src_original="${active_loop_dir}/finalize-state.md"
    else
        src_original="${active_loop_dir}/state.md"
    fi
    if [[ -L "$src_original" ]]; then
        return 6  # Source is a symlink
    fi

    return 0
}

# Check if a path is inside .humanize/rlcr directory
is_in_humanize_loop_dir() {
    local path="$1"
    echo "$path" | grep -q '\.humanize/rlcr/'
}

# ========================================
# PR Loop Bot Name Mapping
# ========================================

# Map bot names to GitHub comment author names:
# - claude -> claude[bot]
# - codex -> chatgpt-codex-connector[bot]
#
# Usage: author=$(map_bot_to_author "codex")
map_bot_to_author() {
    local bot="$1"
    case "$bot" in
        codex) echo "chatgpt-codex-connector[bot]" ;;
        *) echo "${bot}[bot]" ;;
    esac
}

# Reverse mapping: author name to bot name
# - chatgpt-codex-connector[bot] -> codex
# - chatgpt-codex-connector -> codex
# - claude[bot] -> claude
#
# Usage: bot=$(map_author_to_bot "chatgpt-codex-connector[bot]")
map_author_to_bot() {
    local author="$1"
    # Remove [bot] suffix if present
    local author_clean="${author%\[bot\]}"
    case "$author_clean" in
        chatgpt-codex-connector) echo "codex" ;;
        *) echo "$author_clean" ;;
    esac
}

# Build a YAML list string from an array of values
# Returns multiline string with "  - value" for each item
#
# Usage: yaml_list=$(build_yaml_list "${array[@]}")
build_yaml_list() {
    local result=""
    for item in "$@"; do
        result="${result}
  - ${item}"
    done
    echo "$result"
}

# Build a mention string from bot names (e.g., "@claude @codex")
#
# Usage: mentions=$(build_bot_mention_string "${bots[@]}")
build_bot_mention_string() {
    local result=""
    for bot in "$@"; do
        if [[ -n "$result" ]]; then
            result="${result} @${bot}"
        else
            result="@${bot}"
        fi
    done
    echo "$result"
}

# ========================================
# PR Loop Directory Functions
# ========================================

# Check if a path is inside .humanize/pr-loop directory
is_in_pr_loop_dir() {
    local path="$1"
    echo "$path" | grep -q '\.humanize/pr-loop/'
}

# Check if a path is inside any loop directory (RLCR or PR loop)
is_in_any_loop_dir() {
    local path="$1"
    is_in_humanize_loop_dir "$path" || is_in_pr_loop_dir "$path"
}

# Find the most recent active PR loop directory with state.md
# Similar to find_active_loop but for PR loops
# Outputs the directory path to stdout, or empty string if none found
find_active_pr_loop() {
    local loop_base_dir="$1"

    if [[ ! -d "$loop_base_dir" ]]; then
        echo ""
        return
    fi

    local newest_dir
    newest_dir=$(ls -1d "$loop_base_dir"/*/ 2>/dev/null | sort -r | head -1)

    if [[ -n "$newest_dir" && -f "${newest_dir}state.md" ]]; then
        echo "${newest_dir%/}"
    else
        echo ""
    fi
}

# Check if a path (lowercase) matches a PR loop round file pattern
# Types: pr-comment, pr-resolve, pr-check, pr-feedback, prompt, codex-prompt
is_pr_round_file_type() {
    local path_lower="$1"
    local file_type="$2"

    echo "$path_lower" | grep -qE "round-[0-9]+-${file_type}\\.md\$"
}

# Check if a path matches any PR loop read-only file type
# These files are generated by the system and should not be modified by Claude
is_pr_loop_readonly_file() {
    local path_lower="$1"

    is_pr_round_file_type "$path_lower" "pr-comment" || \
    is_pr_round_file_type "$path_lower" "prompt" || \
    is_pr_round_file_type "$path_lower" "codex-prompt" || \
    is_pr_round_file_type "$path_lower" "pr-check" || \
    is_pr_round_file_type "$path_lower" "pr-feedback"
}

# Validate PR loop pr-resolve file round number
# Returns 0 if valid (correct round or no active loop), exits with error message if wrong round
# Usage: validate_pr_resolve_round "$file_path_lower" "$action_verb"
# Arguments:
#   $1 - File path (lowercase)
#   $2 - Action verb for error message ("edit" or "write to")
validate_pr_resolve_round() {
    local file_path_lower="$1"
    local action_verb="$2"

    local project_root="${CLAUDE_PROJECT_DIR:-$(pwd)}"
    local pr_loop_base_dir="$project_root/.humanize/pr-loop"
    local active_pr_loop_dir
    active_pr_loop_dir=$(find_active_pr_loop "$pr_loop_base_dir")

    if [[ -z "$active_pr_loop_dir" ]]; then
        return 0
    fi

    local pr_state_file="$active_pr_loop_dir/state.md"
    if [[ ! -f "$pr_state_file" ]]; then
        return 0
    fi

    local pr_current_round
    pr_current_round=$(sed -n '/^---$/,/^---$/{ /^current_round:/{ s/current_round: *//; p; } }' "$pr_state_file" | tr -d ' ')
    pr_current_round="${pr_current_round:-0}"

    local claude_pr_round
    claude_pr_round=$(echo "$file_path_lower" | sed -n 's|.*round-\([0-9]*\)-pr-resolve\.md$|\1|p')

    if [[ -n "$claude_pr_round" ]] && [[ "$claude_pr_round" != "$pr_current_round" ]]; then
        local correct_path="$active_pr_loop_dir/round-${pr_current_round}-pr-resolve.md"
        # NOTE: Avoid ${var^} (Bash 4+ only) for macOS Bash 3.2 compatibility
        # Use tr for portable capitalization of first letter
        local action_verb_cap
        action_verb_cap=$(echo "$action_verb" | sed 's/^\(.\)/\U\1/')
        # Fallback for systems where \U doesn't work (use awk instead)
        if [[ "$action_verb_cap" == "$action_verb" ]] || [[ "$action_verb_cap" == *'U'* ]]; then
            action_verb_cap=$(echo "$action_verb" | awk '{print toupper(substr($0,1,1)) tolower(substr($0,2))}')
        fi
        echo "# Wrong Round Number" >&2
        echo "" >&2
        echo "You tried to $action_verb round-${claude_pr_round}-pr-resolve.md but current PR loop round is **${pr_current_round}**." >&2
        echo "" >&2
        echo "$action_verb_cap: \`$correct_path\`" >&2
        return 2
    fi

    return 0
}

# Standard message for blocking PR loop state file modifications
pr_loop_state_blocked_message() {
    local fallback="# PR Loop State File Modification Blocked

You cannot modify state.md in .humanize/pr-loop/. This file is managed by the PR loop system."

    load_and_render_safe "$TEMPLATE_DIR" "block/pr-loop-state-modification.md" "$fallback"
}

# Standard message for blocking PR loop prompt/comment file writes
pr_loop_prompt_blocked_message() {
    local fallback="# PR Loop File Write Blocked

You cannot write to round-*-pr-comment.md or round-*-prompt.md files in .humanize/pr-loop/.
These files are generated by the PR loop system and are read-only."

    load_and_render_safe "$TEMPLATE_DIR" "block/pr-loop-prompt-write.md" "$fallback"
}

# Check if a git add command would add .humanize files to version control
# Usage: git_adds_humanize "$command_lower"
# Returns 0 if the command would add .humanize files, 1 otherwise
#
# IMPORTANT: This function receives LOWERCASED input from the validator.
# Git flags like -A become -a after lowercasing, so we match both.
#
# Handles:
# - git -C <dir> add (git options before add subcommand)
# - Chained commands: cd repo && git add .humanize
# - Shell operators: ;, &&, ||, |
#
# Blocks:
# - git add .humanize or git add .humanize/
# - git add .humanize/* or git add .humanize/**
# - git add -f .humanize* (force add)
# - git add -f . or git add --force . (force add all - bypasses gitignore)
# - git add -f -A or git add --force --all (force add all)
# - git add -fA or similar combined flags
# - git add -A or git add --all (when .humanize exists)
# - git add . or git add * (when .humanize exists and not gitignored)
#
git_adds_humanize() {
    local cmd="$1"

    # Split command on shell operators and check each segment
    # This handles chained commands like: cd repo && git add .humanize
    local segments
    segments=$(echo "$cmd" | sed '
        s/&&/\n/g
        s/||/\n/g
        s/|/\n/g
        s/;/\n/g
    ')

    while IFS= read -r segment; do
        [[ -z "$segment" ]] && continue

        # Check if this segment contains a git add command
        # Pattern: git (with optional flags/options) followed by add
        # Handles:
        # - git add
        # - git -C dir add (short option with separate arg)
        # - git --git-dir=x add (long option with = arg)
        # - git -c key=value add (short option with = arg)
        # The pattern allows any non-add tokens between git and add
        if ! echo "$segment" | grep -qE '(^|[[:space:]])git[[:space:]]+([^[:space:]]+[[:space:]]+)*add([[:space:]]|$)'; then
            continue
        fi

        # Extract the part after "add" for analysis
        local add_args
        add_args=$(echo "$segment" | sed -n 's/.*[[:space:]]add[[:space:]]*//p')

        # Normalize add_args: strip quotes for path matching
        # This handles: git add ".humanize", git add '.humanize'
        local add_args_normalized
        add_args_normalized=$(echo "$add_args" | sed "s/[\"']//g")

        # Check for direct .humanize reference (blocked regardless of other flags)
        # Handles: .humanize, ./.humanize, path/to/.humanize, ".humanize", '.humanize'
        # Pattern matches .humanize at start, after space, after / or ./ AND followed by end, /, or space
        # This avoids over-blocking .humanizeconfig or .humanize-backup
        if echo "$add_args_normalized" | grep -qE '(^|[[:space:]]|/)\.humanize($|/|[[:space:]])'; then
            return 0
        fi

        # Check for -f or --force flag (including combined flags like -fa, -af)
        local has_force=false
        if echo "$add_args" | grep -qE '(^|[[:space:]])--force([[:space:]]|$)'; then
            has_force=true
        elif echo "$add_args" | grep -qE '(^|[[:space:]])-[a-z]*f[a-z]*([[:space:]]|$)'; then
            has_force=true
        fi

        # Check for -A/--all flag (including combined flags like -fa, -af)
        # Note: input is lowercased, so -A becomes -a
        local has_all=false
        if echo "$add_args" | grep -qE '(^|[[:space:]])--all([[:space:]]|$)'; then
            has_all=true
        elif echo "$add_args" | grep -qE '(^|[[:space:]])-[a-z]*a[a-z]*([[:space:]]|$)'; then
            has_all=true
        fi

        # Check for broad scope targets: . or * alone
        local has_broad_scope=false
        if echo "$add_args" | grep -qE '(^|[[:space:]])(\.|\*)([[:space:]]|$)'; then
            has_broad_scope=true
        fi

        # Force add with any broad scope (force bypasses gitignore entirely)
        if [[ "$has_force" == "true" ]]; then
            if [[ "$has_all" == "true" ]] || [[ "$has_broad_scope" == "true" ]]; then
                return 0
            fi
        fi

        # Check if .humanize exists - needed for non-force blocking
        if [[ ! -d ".humanize" ]]; then
            continue
        fi

        # git add -A/--all when .humanize exists
        # Always block because -A adds all changes including untracked files
        if [[ "$has_all" == "true" ]]; then
            return 0
        fi

        # git add . or git add * when .humanize exists and not gitignored
        # Only block if .humanize is NOT protected by gitignore
        if [[ "$has_broad_scope" == "true" ]]; then
            if ! git check-ignore -q .humanize 2>/dev/null; then
                return 0
            fi
        fi
    done <<< "$segments"

    return 1
}

# Standard message for blocking git add .humanize commands
# Usage: git_add_humanize_blocked_message
git_add_humanize_blocked_message() {
    local fallback="# Git Add Blocked: .humanize Protection

The \`.humanize/\` directory contains local loop state that should NOT be committed.

Your command was blocked because it would add .humanize files to version control.

## Allowed Commands

Use specific file paths instead of broad patterns:

    git add <specific-file>
    git add src/
    git add -p  # patch mode

## Blocked Commands

These commands are blocked when .humanize exists:

    git add .humanize      # direct reference
    git add -A             # adds all including .humanize
    git add --all          # adds all including .humanize
    git add .              # may include .humanize if not gitignored
    git add -f .           # force bypasses gitignore

## Adding .humanize to .gitignore

If you need to add \`.humanize*\` to \`.gitignore\`, follow these steps:

1. Edit \`.gitignore\` to append \`.humanize*\`
2. Run: \`git add .gitignore\`
3. Run: \`git commit -m \"Add humanize local folder into gitignore\"\`

IMPORTANT: The commit message must NOT contain the literal string \".humanize\" to avoid triggering this protection."

    load_and_render_safe "$TEMPLATE_DIR" "block/git-add-humanize.md" "$fallback"
}

# Check if a shell command attempts to modify a file matching the given pattern
# Usage: command_modifies_file "$command_lower" "goal-tracker\.md"
# Returns 0 if the command tries to modify the file, 1 otherwise
command_modifies_file() {
    local command_lower="$1"
    local file_pattern="$2"

    local patterns=(
        ">[[:space:]]*[^[:space:]]*${file_pattern}"
        ">>[[:space:]]*[^[:space:]]*${file_pattern}"
        "tee[[:space:]]+(-a[[:space:]]+)?[^[:space:]]*${file_pattern}"
        "sed[[:space:]]+-i[^|]*${file_pattern}"
        "awk[[:space:]]+-i[[:space:]]+inplace[^|]*${file_pattern}"
        "perl[[:space:]]+-[^[:space:]]*i[^|]*${file_pattern}"
        "(mv|cp)[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]*${file_pattern}"
        "rm[[:space:]]+(-[rfv]+[[:space:]]+)?[^[:space:]]*${file_pattern}"
        "dd[[:space:]].*of=[^[:space:]]*${file_pattern}"
        "truncate[[:space:]]+[^|]*${file_pattern}"
        "printf[[:space:]].*>[[:space:]]*[^[:space:]]*${file_pattern}"
        "exec[[:space:]]+[0-9]*>[[:space:]]*[^[:space:]]*${file_pattern}"
    )

    for pattern in "${patterns[@]}"; do
        if echo "$command_lower" | grep -qE "$pattern"; then
            return 0
        fi
    done
    return 1
}

# Standard message for blocking goal-tracker modifications after Round 0
# Usage: goal_tracker_blocked_message "$current_round" "$summary_file_path"
goal_tracker_blocked_message() {
    local current_round="$1"
    local summary_file="$2"
    local fallback="# Goal Tracker Modification Blocked (Round {{CURRENT_ROUND}})

After Round 0, only Codex can modify the Goal Tracker. Include a Goal Tracker Update Request in your summary: {{SUMMARY_FILE}}"

    load_and_render_safe "$TEMPLATE_DIR" "block/goal-tracker-modification.md" "$fallback" \
        "CURRENT_ROUND=$current_round" \
        "SUMMARY_FILE=$summary_file"
}

# End the loop by renaming state.md to indicate exit reason
# Usage: end_loop "$loop_dir" "$state_file" "complete|cancel|maxiter|stop|unexpected"
# Arguments:
#   $1 - loop_dir: Path to the loop directory
#   $2 - state_file: Path to the state.md file
#   $3 - reason: One of complete, cancel, maxiter, stop, unexpected
# Returns: 0 on success, 1 on failure
end_loop() {
    local loop_dir="$1"
    local state_file="$2"
    local reason="$3"  # complete, cancel, maxiter, stop, unexpected

    # Validate reason
    case "$reason" in
        complete|cancel|maxiter|stop|unexpected)
            ;;
        *)
            echo "Error: Invalid end_loop reason: $reason" >&2
            return 1
            ;;
    esac

    local target_name="${reason}-state.md"

    if [[ -f "$state_file" ]]; then
        mv "$state_file" "$loop_dir/$target_name"
        echo "Loop ended: $reason" >&2
        echo "State preserved as: $loop_dir/$target_name" >&2
        return 0
    else
        echo "Warning: State file not found, cannot end loop" >&2
        return 1
    fi
}

# ========================================
# PR Loop Goal Tracker Functions
# ========================================

# Update the PR goal tracker after Codex analysis
# Usage: update_pr_goal_tracker "$GOAL_TRACKER_FILE" "$ROUND" "$BOT_RESULTS_JSON"
#
# Arguments:
#   $1 - Path to goal-tracker.md
#   $2 - Current round number
#   $3 - JSON containing per-bot analysis results (optional)
#        Format: {"bot": "name", "issues": N, "resolved": N}
#
# Updates:
#   - Issue Summary table with new row
#   - Total Statistics section
#   - Issue Log with round entry
#
# Note: This is a helper function for the stop hook. The primary update
# mechanism is through Codex prompt instructions, but this ensures
# consistency when Codex doesn't update correctly.
update_pr_goal_tracker() {
    local tracker_file="$1"
    local round="$2"
    local bot_results="${3:-}"

    if [[ ! -f "$tracker_file" ]]; then
        echo "Warning: Goal tracker not found: $tracker_file" >&2
        return 1
    fi

    # Extract reviewer early for idempotency check (need to check round+reviewer combo)
    local reviewer="Codex"
    if [[ -n "$bot_results" && "$bot_results" != "null" ]]; then
        reviewer=$(echo "$bot_results" | jq -r '.bot // "Codex"' 2>/dev/null || echo "Codex")
    fi

    # IDEMPOTENCY CHECK: Check for BOTH round AND reviewer to support multi-bot rounds
    # This allows multiple bots to add their own rows for the same round
    local has_summary_row=false
    local has_log_entry=false

    # Check if this specific round+reviewer combo already exists in Issue Summary
    # Table format: | Round | Reviewer | Issues Found | Issues Resolved | Status |
    if grep -qE "^\|[[:space:]]*${round}[[:space:]]*\|[[:space:]]*${reviewer}[[:space:]]*\|" "$tracker_file" 2>/dev/null; then
        has_summary_row=true
    fi

    # Check if this specific round+reviewer combo already exists in Issue Log
    # Log format: "### Round N" followed by "Reviewer: ..."
    if awk -v round="$round" -v reviewer="$reviewer" '
        /^### Round / { current_round = $3 }
        current_round == round && $1 == reviewer":" { found = 1; exit }
        END { exit !found }
    ' "$tracker_file" 2>/dev/null; then
        has_log_entry=true
    fi

    if [[ "$has_summary_row" == "true" && "$has_log_entry" == "true" ]]; then
        echo "Goal tracker: Round $round/$reviewer already has both Issue Summary and Issue Log entries, skipping update" >&2
        return 0
    fi

    # Track what we need to add (for partial updates)
    local need_summary_row=true
    local need_log_entry=true
    [[ "$has_summary_row" == "true" ]] && need_summary_row=false
    [[ "$has_log_entry" == "true" ]] && need_log_entry=false

    if [[ "$has_summary_row" == "true" || "$has_log_entry" == "true" ]]; then
        echo "Goal tracker: Round $round/$reviewer has partial update (summary=$has_summary_row, log=$has_log_entry), completing..." >&2
    fi

    # Extract current totals
    local current_found
    current_found=$(grep -E "^- Total Issues Found:" "$tracker_file" | sed 's/.*: //' | tr -d ' ')
    current_found=${current_found:-0}

    local current_resolved
    current_resolved=$(grep -E "^- Total Issues Resolved:" "$tracker_file" | sed 's/.*: //' | tr -d ' ')
    current_resolved=${current_resolved:-0}

    # Parse bot results if provided (reviewer already extracted above for idempotency check)
    local new_issues=0
    local new_resolved=0

    if [[ -n "$bot_results" && "$bot_results" != "null" ]]; then
        new_issues=$(echo "$bot_results" | jq -r '.issues // 0' 2>/dev/null || echo "0")
        new_resolved=$(echo "$bot_results" | jq -r '.resolved // 0' 2>/dev/null || echo "0")
    fi

    # Calculate new totals
    local total_found=$((current_found + new_issues))
    local total_resolved=$((current_resolved + new_resolved))
    local remaining=$((total_found - total_resolved))

    # Determine status for this round
    local status="In Progress"
    if [[ $new_issues -eq 0 && $new_resolved -eq 0 ]]; then
        status="Approved"
    elif [[ $new_issues -gt 0 ]]; then
        status="Issues Found"
    elif [[ $new_resolved -gt 0 ]]; then
        status="Resolved"
    fi

    # Create temp file for updates
    local temp_file="${tracker_file}.update.$$"

    # Step 1: Update Total Statistics (only if we're adding to totals)
    # Only update totals if we're adding a new summary row (to avoid double-counting)
    if [[ "$need_summary_row" == "true" ]]; then
        sed -e "s/^- Total Issues Found:.*/- Total Issues Found: $total_found/" \
            -e "s/^- Total Issues Resolved:.*/- Total Issues Resolved: $total_resolved/" \
            -e "s/^- Remaining:.*/- Remaining: $remaining/" \
            "$tracker_file" > "$temp_file"
    else
        cp "$tracker_file" "$temp_file"
    fi

    # Step 2: Add row to Issue Summary table (only if needed)
    if [[ "$need_summary_row" == "true" ]]; then
        # Insert row INSIDE the table (after last table row, before blank line)
        local new_row="| $round     | $reviewer | $new_issues            | $new_resolved               | $status |"

        # Use awk to find the last row of the Issue Summary table and insert after it
        awk -v row="$new_row" '
            BEGIN { in_table = 0; last_row_printed = 0 }
            /^## Issue Summary/ { in_table = 1 }
            /^## Total Statistics/ { in_table = 0 }
            {
                # If we hit Total Statistics and havent printed the new row yet, print it first
                if (/^## Total Statistics/ && !last_row_printed) {
                    print row
                    print ""
                    last_row_printed = 1
                }
                # If in table and this is a table row (starts with |), store it
                if (in_table && /^\|/) {
                    last_table_line = NR
                }
                # If in table and this is a blank line after table rows, insert new row
                if (in_table && /^[[:space:]]*$/ && last_table_line > 0 && !last_row_printed) {
                    print row
                    last_row_printed = 1
                }
                print
            }
        ' "$temp_file" > "${temp_file}.2"
        mv "${temp_file}.2" "$temp_file"
    fi

    # Step 3: Add Issue Log entry for this round (only if needed)
    if [[ "$need_log_entry" == "true" ]]; then
        local timestamp
        timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        local log_entry="### Round $round
$reviewer: Found $new_issues issues, Resolved $new_resolved
Updated: $timestamp
"
        # Append to Issue Log section
        echo "" >> "$temp_file"
        echo "$log_entry" >> "$temp_file"
    fi

    mv "$temp_file" "$tracker_file"
    echo "Goal tracker updated: Round $round, Reviewer=$reviewer, Found=$new_issues, Resolved=$new_resolved" >&2
    return 0
}
