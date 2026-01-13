#!/bin/bash
#
# Common functions for RLCR loop hooks
#
# This library provides shared functionality used by:
# - loop-read-validator.sh
# - loop-write-validator.sh
# - loop-bash-validator.sh
#

# Find the most recent active loop directory
# Only checks the newest directory - older directories are ignored even if they have rlcr-state.md
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

    if [[ -n "$newest_dir" ]] && [[ -f "${newest_dir}rlcr-state.md" ]]; then
        # Remove trailing slash to avoid double slashes in paths
        echo "${newest_dir%/}"
    else
        echo ""
    fi
}

# Extract current round number from rlcr-state.md
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

    cat << 'EOF'
# Todos File Access Blocked

Do NOT create or access `round-*-todos.md` files.

**Use the native TodoWrite tool instead.**

The native todo tools provide proper state tracking visible in the UI and
integration with Claude Code's task management system.
EOF
}

# Standard message for blocking prompt file writes
prompt_write_blocked_message() {
    cat << 'EOF'
# Prompt File Write Blocked

You cannot write to `round-*-prompt.md` files.

**Prompt files contain instructions FROM Codex TO you (Claude).**

You cannot modify your own instructions. Your job is to:
1. Read the current round's prompt file for instructions
2. Execute the tasks described in the prompt
3. Write your results to the summary file

If the prompt contains errors, document this in your summary file.
EOF
}

# Standard message for blocking state file modifications
state_file_blocked_message() {
    cat << 'EOF'
# State File Modification Blocked

You cannot modify `rlcr-state.md`. This file is managed by the loop system.

The state file contains:
- Current round number
- Max iterations
- Codex configuration

Modifying it would corrupt the loop state.
EOF
}

# Standard message for blocking summary file modifications via Bash
# Usage: summary_bash_blocked_message "$correct_summary_path"
summary_bash_blocked_message() {
    local correct_path="$1"

    cat << EOF
# Bash Write Blocked: Use Write or Edit Tool

Do not use Bash commands to modify summary files.

**Use the Write or Edit tool instead**: \`$correct_path\`

Bash commands like cat, echo, sed, awk, etc. bypass the validation hooks.
Please use the proper tools to ensure correct round number validation.
EOF
}

# Standard message for blocking goal-tracker modifications via Bash in Round 0
# Usage: goal_tracker_bash_blocked_message "$correct_goal_tracker_path"
goal_tracker_bash_blocked_message() {
    local correct_path="$1"

    cat << EOF
# Bash Write Blocked: Use Write or Edit Tool

Do not use Bash commands to modify rlcr-tracker.md.

**Use the Write or Edit tool instead**: \`$correct_path\`

Bash commands like cat, echo, sed, awk, etc. bypass the validation hooks.
Please use the proper tools to modify the Goal Tracker.
EOF
}

# Check if a path (lowercase) targets rlcr-tracker.md
is_goal_tracker_path() {
    local path_lower="$1"
    echo "$path_lower" | grep -qE 'goal-tracker\.md$'
}

# Check if a path (lowercase) targets rlcr-state.md
is_state_file_path() {
    local path_lower="$1"
    echo "$path_lower" | grep -qE 'state\.md$'
}

# Check if a path is inside .humanize-rlcr.local directory
is_in_humanize_loop_dir() {
    local path="$1"
    echo "$path" | grep -q '\.humanize-rlcr\.local/'
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

    cat << EOF
# Goal Tracker Modification Blocked (Round ${current_round})

After Round 0, **only Codex can modify the Goal Tracker**.

You CANNOT directly modify \`rlcr-tracker.md\` via Write, Edit, or Bash commands.

## How to Request Changes

Include a **"Goal Tracker Update Request"** section in your summary file:
\`$summary_file\`

Use this format:
\`\`\`markdown
## Goal Tracker Update Request

### Requested Changes:
- [E.g., "Mark Task X as completed with evidence: tests pass"]
- [E.g., "Add to Open Issues: discovered Y needs addressing"]
- [E.g., "Plan Evolution: changed approach from A to B because..."]

### Justification:
[Explain why these changes are needed and how they serve the Ultimate Goal]
\`\`\`

Codex will review your request and update the Goal Tracker if the changes are justified.
EOF
}
