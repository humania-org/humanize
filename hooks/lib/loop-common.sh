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

# Stop an active loop by renaming state.md to <prefix>-state.md
# This preserves the state file for manual inspection/restart if needed
# The prefix indicates why the loop was stopped:
#   - completed: Normal completion (Codex said COMPLETE)
#   - stopped: Stagnation/circuit breaker (Codex said STOP, or max iterations)
#   - unexpected: Error conditions (corruption, legacy state, branch change)
#   - cancelled: User manually cancelled
# Usage: stop_loop "$STATE_FILE" "completed|stopped|unexpected|cancelled"
stop_loop() {
    local state_file="$1"
    local prefix="${2:-stopped}"  # Default to "stopped" for backward compatibility
    if [[ -f "$state_file" ]]; then
        local new_file="${state_file%state.md}${prefix}-state.md"
        mv "$state_file" "$new_file" 2>/dev/null || rm -f "$state_file"
    fi
}

# Check if HEAD is a descendant of start_commit
# Returns 0 if HEAD is descendant (valid), 1 if not (user checked out older branch)
# Usage: check_start_commit_ancestry "$START_COMMIT"
check_start_commit_ancestry() {
    local start_commit="$1"

    # If no start_commit or not in a git repo, skip check
    if [[ -z "$start_commit" ]]; then
        return 0
    fi

    if ! command -v git &>/dev/null || ! git rev-parse --git-dir &>/dev/null 2>&1; then
        return 0
    fi

    # Check if start_commit is an ancestor of HEAD
    if git merge-base --is-ancestor "$start_commit" HEAD 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

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

# Compute relative path from base to target (portable across Linux/macOS/BSD)
# Usage: get_relative_path "/base/dir" "/base/dir/sub/file.txt"
# Output: "sub/file.txt"
get_relative_path() {
    local base="$1"
    local target="$2"

    # Normalize paths (resolve symlinks, remove trailing slashes)
    local base_real target_real
    base_real=$(cd "$base" 2>/dev/null && pwd -P) || base_real="$base"
    target_real=$(realpath "$target" 2>/dev/null) || target_real="$target"

    # Try GNU realpath --relative-to (Linux)
    if realpath --relative-to="$base_real" "$target_real" 2>/dev/null; then
        return 0
    fi

    # Try grealpath (macOS with coreutils)
    if command -v grealpath &>/dev/null; then
        if grealpath --relative-to="$base_real" "$target_real" 2>/dev/null; then
            return 0
        fi
    fi

    # Fallback: compute relative path in bash (works for inside/outside base)
    if [[ "$base_real" == /* ]] && [[ "$target_real" == /* ]]; then
        local base_clean target_clean
        base_clean="${base_real%/}"
        target_clean="${target_real%/}"
        [[ -z "$base_clean" ]] && base_clean="/"
        [[ -z "$target_clean" ]] && target_clean="/"

        if [[ "$base_clean" == "$target_clean" ]]; then
            echo "."
            return 0
        fi

        local base_trim target_trim
        base_trim="${base_clean#/}"
        target_trim="${target_clean#/}"

        local -a base_parts target_parts rel_parts
        IFS='/' read -r -a base_parts <<< "$base_trim"
        IFS='/' read -r -a target_parts <<< "$target_trim"

        local i=0
        while [[ $i -lt ${#base_parts[@]} ]] && [[ $i -lt ${#target_parts[@]} ]] && \
            [[ "${base_parts[$i]}" == "${target_parts[$i]}" ]]; do
            ((i++))
        done

        local j
        for ((j=i; j<${#base_parts[@]}; j++)); do
            rel_parts+=("..")
        done
        for ((j=i; j<${#target_parts[@]}; j++)); do
            rel_parts+=("${target_parts[$j]}")
        done

        if (( ${#rel_parts[@]} == 0 )); then
            echo "."
        else
            local IFS='/'
            echo "${rel_parts[*]}"
        fi
        return 0
    fi

    # Cannot compute relative path, return basename as last resort
    basename "$target"
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
        "tee[[:space:]]+(-a[[:space:]]+)?[^[:space:]]*${file_pattern}"
        "sed[[:space:]]+-i[^|]*${file_pattern}"
        "awk[[:space:]]+-i[[:space:]]+inplace[^|]*${file_pattern}"
        "perl[[:space:]]+-[^[:space:]]*i[^|]*${file_pattern}"
        "(mv|cp)[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]*${file_pattern}"
        "dd[[:space:]].*of=[^[:space:]]*${file_pattern}"
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
