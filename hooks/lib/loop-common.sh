#!/bin/bash
#
# Common functions for RLCR loop hooks
#
# This library provides shared functionality used by:
# - loop-read-validator.sh
# - loop-write-validator.sh
# - loop-bash-validator.sh
#

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

    if [[ -n "$newest_dir" && -f "${newest_dir}state.md" ]]; then
        echo "${newest_dir%/}"
    else
        echo ""
    fi
}

# Extract current round number from state.md
# Outputs the round number to stdout, defaults to 0
get_current_round() {
    local state_file="$1"

    local frontmatter
    frontmatter=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$state_file" 2>/dev/null || echo "")

    local current_round
    current_round=$(echo "$frontmatter" | grep '^current_round:' | sed 's/current_round: *//' | tr -d ' ')

    echo "${current_round:-0}"
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

# Check if a path is inside .humanize-loop.local directory
is_in_humanize_loop_dir() {
    local path="$1"
    echo "$path" | grep -q '\.humanize-loop\.local/'
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
