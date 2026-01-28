#!/bin/bash
# humanize.sh - Humanize shell utilities
# Part of rc.d configuration
# Compatible with both bash and zsh

# Source shared monitor utilities (per plan: scripts/lib/monitor-common.sh)
HUMANIZE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -f "$HUMANIZE_SCRIPT_DIR/lib/monitor-common.sh" ]]; then
    source "$HUMANIZE_SCRIPT_DIR/lib/monitor-common.sh"
fi

# ========================================
# Public helper functions (can be called directly for testing)
# ========================================

# Split pipe-delimited string into array (bash/zsh compatible)
# Usage: humanize_split_to_array "output_array_name" "value1|value2|value3"
humanize_split_to_array() {
    local arr_name="$1"
    local input="$2"
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        # zsh: use parameter expansion to split on |
        eval "$arr_name=(\"\${(@s:|:)input}\")"
    else
        # bash: use read -ra
        eval "IFS='|' read -ra $arr_name <<< \"\$input\""
    fi
}

# Parse goal-tracker.md and return summary values
# Returns: total_acs|completed_acs|active_tasks|completed_tasks|deferred_tasks|open_issues|goal_summary
humanize_parse_goal_tracker() {
    local tracker_file="$1"
    if [[ ! -f "$tracker_file" ]]; then
        echo "0|0|0|0|0|0|No goal tracker"
        return
    fi

    # Helper: count data rows in a markdown table section (total rows minus header and separator)
    # Usage: _count_table_data_rows "section_start_pattern" "section_end_pattern"
    _count_table_data_rows() {
        local row_count
        row_count=$(sed -n "/$1/,/$2/p" "$tracker_file" | grep -cE '^\|' || true)
        row_count=${row_count:-0}
        echo $((row_count > 2 ? row_count - 2 : 0))
    }

    # Count Acceptance Criteria (supports both table and list formats)
    # Table format: | AC-1 | or | **AC-1** |
    # List format: - **AC-1**: or - AC-1:
    local total_acs
    total_acs=$(sed -n '/### Acceptance Criteria/,/^---$/p' "$tracker_file" \
        | grep -cE '(^\|\s*\*{0,2}AC-?[0-9]+|^-\s*\*{0,2}AC-?[0-9]+)' || true)
    total_acs=${total_acs:-0}

    # Count Active Tasks (tasks that are NOT completed AND NOT deferred)
    # This counts tasks with status: pending, partial, in_progress, todo, etc.
    local active_tasks
    local total_active_section_rows
    local completed_in_active
    local deferred_in_active

    # Count total table rows in Active Tasks section (includes header and separator)
    total_active_section_rows=$(sed -n '/#### Active Tasks/,/^###/p' "$tracker_file" \
        | grep -cE '^\|' || true)
    total_active_section_rows=${total_active_section_rows:-0}
    # Subtract header row and separator row (2 rows)
    local total_active_data_rows=$((total_active_section_rows > 2 ? total_active_section_rows - 2 : 0))

    # Count completed tasks in Active Tasks section (status column contains "completed")
    completed_in_active=$(sed -n '/#### Active Tasks/,/^###/p' "$tracker_file" \
        | sed 's/\*\*//g' \
        | grep -ciE '^\|[^|]+\|[^|]+\|[[:space:]]*completed[[:space:]]*\|' || true)
    completed_in_active=${completed_in_active:-0}

    # Count deferred tasks in Active Tasks section (status column contains "deferred")
    deferred_in_active=$(sed -n '/#### Active Tasks/,/^###/p' "$tracker_file" \
        | sed 's/\*\*//g' \
        | grep -ciE '^\|[^|]+\|[^|]+\|[[:space:]]*deferred[[:space:]]*\|' || true)
    deferred_in_active=${deferred_in_active:-0}

    # Active = total data rows - completed - deferred
    active_tasks=$((total_active_data_rows - completed_in_active - deferred_in_active))
    [[ "$active_tasks" -lt 0 ]] && active_tasks=0

    # Count Completed tasks
    local completed_tasks
    completed_tasks=$(_count_table_data_rows '### Completed and Verified' '^###')

    # Count verified ACs (unique AC entries in Completed section, handles | AC-1 | and | AC1 | formats)
    local completed_acs
    completed_acs=$(sed -n '/### Completed and Verified/,/^###/p' "$tracker_file" \
        | grep -oE '^\|\s*AC-?[0-9]+' | sort -u | wc -l | tr -d ' ')
    completed_acs=${completed_acs:-0}

    # Count Deferred tasks
    local deferred_tasks
    deferred_tasks=$(_count_table_data_rows '### Explicitly Deferred' '^###')

    # Count Open Issues
    local open_issues
    open_issues=$(_count_table_data_rows '### Open Issues' '^###')

    # Extract Ultimate Goal summary (first content line after heading)
    local goal_summary
    goal_summary=$(sed -n '/### Ultimate Goal/,/^###/p' "$tracker_file" \
        | grep -v '^###' | grep -v '^$' | grep -v '^\[To be' \
        | head -1 | sed 's/^[[:space:]]*//' | cut -c1-60)
    goal_summary="${goal_summary:-No goal defined}"

    echo "${total_acs}|${completed_acs}|${active_tasks}|${completed_tasks}|${deferred_tasks}|${open_issues}|${goal_summary}"
}

# Detect special git repository states
# Returns: state_name (one of: normal, detached, rebase, merge, shallow, permission_error)
humanize_detect_git_state() {
    local git_dir

    # Check if we're in a git repo and can access it
    git_dir=$(git rev-parse --git-dir 2>/dev/null) || {
        # Check if it's a permission issue vs not a repo
        if [[ -d ".git" ]] && ! [[ -r ".git" ]]; then
            echo "permission_error"
        else
            echo "not_a_repo"
        fi
        return
    }

    # Check for permission errors on git dir
    if ! [[ -r "$git_dir" ]]; then
        echo "permission_error"
        return
    fi

    # Check for rebase in progress
    if [[ -d "$git_dir/rebase-merge" ]] || [[ -d "$git_dir/rebase-apply" ]]; then
        echo "rebase"
        return
    fi

    # Check for merge in progress
    if [[ -f "$git_dir/MERGE_HEAD" ]]; then
        echo "merge"
        return
    fi

    # Check for shallow clone
    if [[ -f "$git_dir/shallow" ]]; then
        echo "shallow"
        return
    fi

    # Check for detached HEAD
    local head_ref
    head_ref=$(git symbolic-ref HEAD 2>/dev/null) || {
        echo "detached"
        return
    }

    echo "normal"
}

# Parse git status and return summary values
# Returns: modified|added|deleted|untracked|insertions|deletions
humanize_parse_git_status() {
    # Check if we're in a git repo
    if ! git rev-parse --git-dir &>/dev/null 2>&1; then
        echo "0|0|0|0|0|0|not a git repo"
        return
    fi

    # Get porcelain status (fast, machine-readable)
    local git_status_output=$(git status --porcelain 2>/dev/null)

    # Count file states from status output
    local modified=0 added=0 deleted=0 untracked=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local xy="${line:0:2}"
        case "$xy" in
            "??") ((untracked++)) ;;
            "A "* | " A"* | "AM"*) ((added++)) ;;
            "D "* | " D"*) ((deleted++)) ;;
            "M "* | " M"* | "MM"*) ((modified++)) ;;
            "R "* | " R"*) ((modified++)) ;;  # Renamed counts as modified
            *)
                # Handle other cases (staged + unstaged combinations)
                [[ "${xy:0:1}" == "M" || "${xy:1:1}" == "M" ]] && ((modified++))
                [[ "${xy:0:1}" == "A" ]] && ((added++))
                [[ "${xy:0:1}" == "D" || "${xy:1:1}" == "D" ]] && ((deleted++))
                ;;
        esac
    done <<< "$git_status_output"

    # Get line changes (insertions/deletions) - diff of staged + unstaged
    local diffstat=$(git diff --shortstat HEAD 2>/dev/null || git diff --shortstat 2>/dev/null)
    local insertions=0 deletions=0

    if [[ -n "$diffstat" ]]; then
        # Parse: " 3 files changed, 45 insertions(+), 12 deletions(-)"
        insertions=$(echo "$diffstat" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)
        deletions=$(echo "$diffstat" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo 0)
    fi
    insertions=${insertions:-0}
    deletions=${deletions:-0}

    echo "${modified}|${added}|${deleted}|${untracked}|${insertions}|${deletions}"
}

# ========================================
# Monitor function
# ========================================

# Monitor the latest Codex run log from .humanize/rlcr
# Automatically switches to newer logs when they appear
# Features a fixed status bar at the top showing session info
_humanize_monitor_codex() {
    # Enable 0-indexed arrays in zsh for bash compatibility
    # This affects all _split_to_array calls within this function
    [[ -n "${ZSH_VERSION:-}" ]] && setopt localoptions ksharrays

    local loop_dir=".humanize/rlcr"
    local current_file=""
    local current_session_dir=""
    local check_interval=2  # seconds between checking for new files
    local status_bar_height=11  # number of lines for status bar (includes loop status line)

    # Check if .humanize/rlcr exists
    if [[ ! -d "$loop_dir" ]]; then
        echo "Error: $loop_dir directory not found in current directory"
        echo "Are you in a project with an active humanize loop?"
        return 1
    fi

    # Use shared monitor helper for finding latest session
    _find_latest_session() {
        monitor_find_latest_session "$loop_dir"
    }

    # Function to find the latest codex log file
    # Log files are now in $HOME/.cache/humanize/<sanitized-project-path>/<timestamp>/ to avoid context pollution
    # Respects XDG_CACHE_HOME for testability in restricted environments
    # Searches for both implementation phase logs (codex-run.log) and review phase logs (codex-review.log)
    _find_latest_codex_log() {
        local latest=""
        local latest_session=""
        local latest_round=-1
        local cache_base="${XDG_CACHE_HOME:-$HOME/.cache}/humanize"

        # Get current project's absolute path and sanitize it
        # This matches the sanitization in loop-codex-stop-hook.sh
        local project_root="$(pwd)"
        local sanitized_project=$(echo "$project_root" | sed 's/[^a-zA-Z0-9._-]/-/g' | sed 's/--*/-/g')
        local project_cache_dir="$cache_base/$sanitized_project"

        # Check if loop_dir exists before iteration (prevents errors on missing dir)
        if [[ ! -d "$loop_dir" ]]; then
            echo ""
            return
        fi

        # Helper to extract round number from log filename
        # Handles both codex-run.log and codex-review.log patterns
        _extract_round_num() {
            local basename="$1"
            local round="${basename#round-}"
            # Remove either -codex-run.log or -codex-review.log suffix
            round="${round%%-codex-run.log}"
            round="${round%%-codex-review.log}"
            echo "$round"
        }

        # Helper to detect log file type
        _is_review_log() {
            [[ "$1" == *-codex-review.log ]]
        }

        # Use find instead of glob to avoid zsh "no matches found" errors
        # find is safe even when directory is empty or has no matching files
        while IFS= read -r session_dir; do
            [[ -z "$session_dir" ]] && continue
            [[ ! -d "$session_dir" ]] && continue

            local session_name=$(basename "$session_dir")
            if [[ ! "$session_name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
                continue
            fi

            # Look for log files in the project-specific cache directory with matching timestamp
            local cache_dir="$project_cache_dir/$session_name"
            if [[ ! -d "$cache_dir" ]]; then
                continue
            fi

            # Track max round numbers for each log type (for consistency check)
            local max_run_round=-1
            local min_review_round=-1

            # Search for both implementation phase (codex-run) and review phase (codex-review) logs
            # Use find with -o (OR) to match both patterns
            while IFS= read -r log_file; do
                [[ -z "$log_file" ]] && continue
                [[ ! -f "$log_file" ]] && continue

                local log_basename=$(basename "$log_file")
                local round_num=$(_extract_round_num "$log_basename")

                # Track round numbers by type for consistency check
                if _is_review_log "$log_basename"; then
                    if [[ "$min_review_round" -eq -1 ]] || [[ "$round_num" -lt "$min_review_round" ]]; then
                        min_review_round="$round_num"
                    fi
                else
                    if [[ "$round_num" -gt "$max_run_round" ]]; then
                        max_run_round="$round_num"
                    fi
                fi

                if [[ -z "$latest" ]] || \
                   [[ "$session_name" > "$latest_session" ]] || \
                   [[ "$session_name" == "$latest_session" && "$round_num" -gt "$latest_round" ]]; then
                    latest="$log_file"
                    latest_session="$session_name"
                    latest_round="$round_num"
                fi
            done < <(find "$cache_dir" -maxdepth 1 \( -name 'round-*-codex-run.log' -o -name 'round-*-codex-review.log' \) -type f 2>/dev/null)

            # Defensive check: codex-run round must be strictly less than codex-review round
            # If review phase exists, all review rounds must be > all run rounds
            if [[ "$max_run_round" -ge 0 ]] && [[ "$min_review_round" -ge 0 ]]; then
                if [[ "$max_run_round" -ge "$min_review_round" ]]; then
                    echo "ERROR: Inconsistent log state in session $session_name: codex-run round ($max_run_round) >= codex-review round ($min_review_round)" >&2
                    echo ""
                    return 1
                fi
            fi
        done < <(find "$loop_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

        echo "$latest"
    }

    # Use shared monitor helper for finding state file
    _find_state_file() {
        monitor_find_state_file "$1"
    }

    # Parse state.md and return values
    _parse_state_md() {
        local state_file="$1"
        if [[ ! -f "$state_file" ]]; then
            echo "N/A|N/A|N/A|N/A|N/A|N/A|false|false"
            return
        fi

        local current_round=$(grep -E "^current_round:" "$state_file" 2>/dev/null | sed 's/current_round: *//')
        local max_iterations=$(grep -E "^max_iterations:" "$state_file" 2>/dev/null | sed 's/max_iterations: *//')
        local codex_model=$(grep -E "^codex_model:" "$state_file" 2>/dev/null | sed 's/codex_model: *//')
        local codex_effort=$(grep -E "^codex_effort:" "$state_file" 2>/dev/null | sed 's/codex_effort: *//')
        local started_at=$(grep -E "^started_at:" "$state_file" 2>/dev/null | sed 's/started_at: *//')
        local plan_file=$(grep -E "^plan_file:" "$state_file" 2>/dev/null | sed 's/plan_file: *//')
        local ask_codex_question=$(grep -E "^ask_codex_question:" "$state_file" 2>/dev/null | sed 's/ask_codex_question: *//' | tr -d ' ')
        local review_started=$(grep -E "^review_started:" "$state_file" 2>/dev/null | sed 's/review_started: *//' | tr -d ' ')

        echo "${current_round:-N/A}|${max_iterations:-N/A}|${codex_model:-N/A}|${codex_effort:-N/A}|${started_at:-N/A}|${plan_file:-N/A}|${ask_codex_question:-false}|${review_started:-false}"
    }

    # Internal wrappers that call top-level functions
    # These maintain backward compatibility within _humanize_monitor_codex
    _parse_goal_tracker() { humanize_parse_goal_tracker "$@"; }
    _parse_git_status() { humanize_parse_git_status "$@"; }
    _split_to_array() { humanize_split_to_array "$@"; }

    # Draw the status bar at the top
    _draw_status_bar() {
        # Note: ksharrays is set at _humanize_monitor_codex() level for zsh compatibility

        local session_dir="$1"
        local log_file="$2"
        local loop_status="$3"  # "active", "completed", "failed", etc.
        local goal_tracker_file="$session_dir/goal-tracker.md"
        local term_width=$(tput cols)

        # Find and parse state file (state.md or *-state.md)
        local -a state_file_parts
        _split_to_array state_file_parts "$(_find_state_file "$session_dir")"
        local state_file="${state_file_parts[0]}"
        # Use passed loop_status if provided, otherwise use detected status
        [[ -z "$loop_status" ]] && loop_status="${state_file_parts[1]}"

        # Parse state file
        local -a state_parts
        _split_to_array state_parts "$(_parse_state_md "$state_file")"
        local current_round="${state_parts[0]}"
        local max_iterations="${state_parts[1]}"
        local codex_model="${state_parts[2]}"
        local codex_effort="${state_parts[3]}"
        local started_at="${state_parts[4]}"
        local plan_file="${state_parts[5]}"
        local ask_codex_question="${state_parts[6]:-false}"
        local review_started="${state_parts[7]:-false}"

        # Parse goal-tracker.md
        local -a goal_parts
        _split_to_array goal_parts "$(_parse_goal_tracker "$goal_tracker_file")"
        local total_acs="${goal_parts[0]}"
        local completed_acs="${goal_parts[1]}"
        local active_tasks="${goal_parts[2]}"
        local completed_tasks="${goal_parts[3]}"
        local deferred_tasks="${goal_parts[4]}"
        local open_issues="${goal_parts[5]}"
        local goal_summary="${goal_parts[6]}"

        # Parse git status
        local -a git_parts
        _split_to_array git_parts "$(_parse_git_status)"
        local git_modified="${git_parts[0]}"
        local git_added="${git_parts[1]}"
        local git_deleted="${git_parts[2]}"
        local git_untracked="${git_parts[3]}"
        local git_insertions="${git_parts[4]}"
        local git_deletions="${git_parts[5]}"

        # Format started_at for display
        local start_display="$started_at"
        if [[ "$started_at" != "N/A" ]]; then
            # Convert ISO format to more readable format
            start_display=$(echo "$started_at" | sed 's/T/ /; s/Z/ UTC/')
        fi

        # Truncate strings for display (label column is ~10 chars)
        local max_display_len=$((term_width - 12))
        local plan_display="$plan_file"
        local goal_display="$goal_summary"
        # Bash-compatible string slicing
        if [[ ${#plan_file} -gt $max_display_len ]]; then
            local suffix_len=$((max_display_len - 3))
            plan_display="...${plan_file: -$suffix_len}"
        fi
        if [[ ${#goal_summary} -gt $max_display_len ]]; then
            local prefix_len=$((max_display_len - 3))
            goal_display="${goal_summary:0:$prefix_len}..."
        fi

        # Save cursor position and move to top
        tput sc
        tput cup 0 0

        # ANSI color codes
        local green="\033[1;32m" yellow="\033[1;33m" cyan="\033[1;36m"
        local magenta="\033[1;35m" red="\033[1;31m" reset="\033[0m"
        local bg="\033[44m" bold="\033[1m" dim="\033[2m"
        local blue="\033[1;34m"
        local clr_eol="\033[K"  # Clear to end of line (reduces flicker vs clearing entire area)

        # Move to top and draw directly (no pre-clearing to avoid flicker)
        tput cup 0 0
        local session_basename=$(basename "$session_dir")
        printf "${bg}${bold}%-${term_width}s${reset}${clr_eol}\n" " Humanize Loop Monitor"
        printf "${cyan}Session:${reset}  ${session_basename}    ${cyan}Started:${reset} ${start_display}${clr_eol}\n"
        printf "${green}Round:${reset}    ${bold}${current_round}${reset} / ${max_iterations}    ${yellow}Model:${reset} ${codex_model} (${codex_effort})${clr_eol}\n"

        # Loop status line with color based on status
        local status_color="${green}"
        local status_display="$loop_status"
        case "$loop_status" in
            active)
                status_color="${green}"
                # Show phase: impl or review
                if [[ "$review_started" == "true" ]]; then
                    status_display="active(review)"
                else
                    status_display="active(impl)"
                fi
                ;;
            completed) status_color="${cyan}" ;;
            failed|error|timeout) status_color="${red}" ;;
            cancelled) status_color="${yellow}" ;;
            unknown) status_color="${dim}" ;;
            *) status_color="${yellow}" ;;
        esac
        # Display ask_codex_question setting (On/Off)
        local ask_q_display="Off"
        local ask_q_color="${dim}"
        if [[ "$ask_codex_question" == "true" ]]; then
            ask_q_display="On"
            ask_q_color="${green}"
        fi
        printf "${magenta}Status:${reset}   ${status_color}${status_display}${reset} | Codex Ask Question: ${ask_q_color}${ask_q_display}${reset}${clr_eol}\n"

        # Progress line (color based on completion status)
        local ac_color="${green}"
        [[ "$completed_acs" -lt "$total_acs" ]] && ac_color="${yellow}"
        local issue_color="${dim}"
        [[ "$open_issues" -gt 0 ]] && issue_color="${red}"

        # Use magenta for Progress and Git labels (status/data lines)
        printf "${magenta}Progress:${reset} ${ac_color}ACs: ${completed_acs}/${total_acs}${reset}  Tasks: ${active_tasks} active, ${completed_tasks} done"
        [[ "$deferred_tasks" -gt 0 ]] && printf "  ${yellow}${deferred_tasks} deferred${reset}"
        [[ "$open_issues" -gt 0 ]] && printf "  ${issue_color}Issues: ${open_issues}${reset}"
        printf "${clr_eol}\n"

        # Git status line (same color as Progress)
        local git_total=$((git_modified + git_added + git_deleted))
        printf "${magenta}Git:${reset}      "
        if [[ "$git_total" -eq 0 && "$git_untracked" -eq 0 ]]; then
            printf "${dim}clean${reset}"
        else
            [[ "$git_modified" -gt 0 ]] && printf "${yellow}~${git_modified}${reset} "
            [[ "$git_added" -gt 0 ]] && printf "${green}+${git_added}${reset} "
            [[ "$git_deleted" -gt 0 ]] && printf "${red}-${git_deleted}${reset} "
            [[ "$git_untracked" -gt 0 ]] && printf "${dim}?${git_untracked}${reset} "
            printf " ${green}+${git_insertions}${reset}/${red}-${git_deletions}${reset} lines"
        fi
        printf "${clr_eol}\n"

        # Use cyan for Goal, Plan, Log labels (context/reference lines)
        printf "${cyan}Goal:${reset}     ${goal_display}${clr_eol}\n"
        printf "${cyan}Plan:${reset}     ${plan_display}${clr_eol}\n"
        printf "${cyan}Log:${reset}      ${log_file}${clr_eol}\n"
        printf "%.s─" $(seq 1 $term_width)
        printf "${clr_eol}\n"

        # Restore cursor position
        tput rc
    }

    # Setup terminal for split view
    _setup_terminal() {
        # Clear screen
        clear
        # Set scroll region (leave top lines for status bar)
        printf "\033[${status_bar_height};%dr" $(tput lines)
        # Move cursor to scroll region
        tput cup $status_bar_height 0
    }

    # Restore terminal to normal
    _restore_terminal() {
        # Reset scroll region to full screen
        printf "\033[r"
        # Move to bottom
        tput cup $(tput lines) 0
    }

    # Track PIDs for cleanup
    local tail_pid=""
    local monitor_running=true
    local cleanup_done=false

    # Cleanup function - called by trap
    # Must work cleanly in both bash and zsh
    _cleanup() {
        # Prevent multiple cleanup calls
        [[ "${cleanup_done:-false}" == "true" ]] && return
        cleanup_done=true
        monitor_running=false

        # Reset traps to prevent re-triggering
        # Use explicit signal numbers for better zsh compatibility
        trap - INT TERM 2>/dev/null || true

        # Kill background processes more robustly
        if [[ -n "$tail_pid" ]]; then
            # Check if process exists before killing
            if kill -0 "$tail_pid" 2>/dev/null; then
                kill "$tail_pid" 2>/dev/null || true
                # Use timeout-safe wait
                ( wait "$tail_pid" 2>/dev/null ) &
                wait $! 2>/dev/null || true
            fi
        fi

        _restore_terminal
        echo ""
        echo "Stopped monitoring."
    }

    # Graceful stop when loop directory is deleted
    # Per R1.2: calls _cleanup() to restore terminal state
    _graceful_stop() {
        local reason="$1"
        # Prevent multiple cleanup calls (checked again in _cleanup but check here too)
        [[ "${cleanup_done:-false}" == "true" ]] && return

        # Call _cleanup to do the actual cleanup work (per plan requirement)
        _cleanup

        # Print the specific graceful stop message after cleanup
        echo "Monitoring stopped: $reason"
        echo "The RLCR loop may have been cancelled or the directory was deleted."
    }

    # Set up signal handlers (bash/zsh compatible)
    # Use function name without quotes for zsh compatibility
    # In zsh, traps in functions are local by default when using POSIX_TRAPS option
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        # zsh: use TRAPINT and TRAPTERM for better handling
        TRAPINT() { _cleanup; return 130; }
        TRAPTERM() { _cleanup; return 143; }
    else
        # bash: use standard trap
        trap '_cleanup' INT TERM
    fi

    # Find initial session and log file
    current_session_dir=$(_find_latest_session)
    current_file=$(_find_latest_codex_log)

    # Check if we have a valid session directory
    if [[ -z "$current_session_dir" ]]; then
        echo "No session directories found in $loop_dir"
        echo "Start an RLCR loop first with /humanize:start-rlcr-loop"
        return 1
    fi

    # Get loop status from state file
    local -a state_file_info
    _split_to_array state_file_info "$(_find_state_file "$current_session_dir")"
    local current_state_file="${state_file_info[0]}"
    local current_loop_status="${state_file_info[1]}"

    # Setup terminal
    _setup_terminal

    # Use shared monitor helper for file size
    _get_file_size() {
        monitor_get_file_size "$1"
    }

    # Track last read position for incremental reading
    local last_size=0
    local file_size=0
    local last_no_log_status=""  # Track last rendered no-log status for refresh

    # Main monitoring loop
    while [[ "$monitor_running" == "true" ]]; do
        # Check if loop directory still exists (graceful exit if deleted)
        if [[ ! -d "$loop_dir" ]]; then
            _graceful_stop ".humanize/rlcr directory no longer exists"
            return 0
        fi

        # Update loop status
        _split_to_array state_file_info "$(_find_state_file "$current_session_dir")"
        current_state_file="${state_file_info[0]}"
        current_loop_status="${state_file_info[1]}"

        # Draw status bar (check flag before expensive operation)
        [[ "$monitor_running" != "true" ]] && break
        _draw_status_bar "$current_session_dir" "${current_file:-N/A}" "$current_loop_status"
        [[ "$monitor_running" != "true" ]] && break

        # Move cursor to scroll region
        tput cup $status_bar_height 0

        # Handle case when no log file exists
        if [[ -z "$current_file" ]]; then
            # Render no-log message if status changed or not yet shown
            if [[ "$last_no_log_status" != "$current_loop_status" ]]; then
                tput cup $status_bar_height 0
                tput ed  # Clear scroll region
                if [[ "$current_loop_status" == "active" ]]; then
                    printf "\nWaiting for log file...\n"
                    printf "Status bar will update as session progresses.\n"
                else
                    printf "\nNo log file available for this session.\n"
                    printf "Loop status: %s\n" "$current_loop_status"
                fi
                last_no_log_status="$current_loop_status"
            fi

            # Poll for new log files
            while [[ "$monitor_running" == "true" ]]; do
                sleep 0.5
                [[ "$monitor_running" != "true" ]] && break

                # Check if loop directory still exists (graceful exit if deleted)
                if [[ ! -d "$loop_dir" ]]; then
                    _graceful_stop ".humanize/rlcr directory no longer exists"
                    return 0
                fi

                # Update loop status and redraw status bar
                _split_to_array state_file_info "$(_find_state_file "$current_session_dir")"
                current_loop_status="${state_file_info[1]}"
                _draw_status_bar "$current_session_dir" "N/A" "$current_loop_status"
                [[ "$monitor_running" != "true" ]] && break

                # Re-render no-log message if loop status changed
                if [[ "$last_no_log_status" != "$current_loop_status" ]]; then
                    tput cup $status_bar_height 0
                    tput ed
                    if [[ "$current_loop_status" == "active" ]]; then
                        printf "\nWaiting for log file...\n"
                        printf "Status bar will update as session progresses.\n"
                    else
                        printf "\nNo log file available for this session.\n"
                        printf "Loop status: %s\n" "$current_loop_status"
                    fi
                    last_no_log_status="$current_loop_status"
                fi

                # Check for new log files and session directories
                local latest=$(_find_latest_codex_log)
                local latest_session=$(_find_latest_session)
                [[ "$monitor_running" != "true" ]] && break

                # Handle session directory deletion
                if [[ ! -d "$current_session_dir" ]]; then
                    if [[ -n "$latest_session" ]]; then
                        # Current session deleted but another exists - switch to it
                        current_session_dir="$latest_session"
                        current_file="$latest"
                        last_no_log_status=""  # Reset to re-render status for new session
                        tput cup $status_bar_height 0
                        tput ed
                        printf "\n==> Session directory deleted, switching to: %s\n" "$(basename "$latest_session")"
                        if [[ -n "$current_file" ]]; then
                            printf "==> Log: %s\n\n" "$current_file"
                            last_size=0
                            break
                        else
                            printf "==> Waiting for log file...\n\n"
                        fi
                        continue
                    else
                        # No sessions available - wait for new ones
                        last_no_log_status=""  # Reset to re-render status
                        tput cup $status_bar_height 0
                        tput ed
                        printf "\n==> Session directory deleted, waiting for new sessions...\n"
                        current_session_dir=""
                        current_file=""
                        continue
                    fi
                fi

                # Update session dir immediately when a newer one exists (even without log)
                if [[ -n "$latest_session" && "$latest_session" != "$current_session_dir" ]]; then
                    current_session_dir="$latest_session"
                    last_no_log_status=""  # Reset to re-render status for new session
                fi

                if [[ -n "$latest" ]]; then
                    current_file="$latest"
                    current_session_dir="$latest_session"
                    last_no_log_status=""  # Reset for next no-log scenario
                    tput cup $status_bar_height 0
                    tput ed
                    printf "\n==> Log file found: %s\n\n" "$current_file"
                    last_size=0
                    break
                fi
            done
            continue
        fi

        # Get initial file size
        last_size=$(_get_file_size "$current_file")

        # Show existing content (last 50 lines)
        [[ "$monitor_running" != "true" ]] && break
        tail -n 50 "$current_file" 2>/dev/null

        # Incremental monitoring loop
        while [[ "$monitor_running" == "true" ]]; do
            sleep 0.5  # Check more frequently for smoother output
            [[ "$monitor_running" != "true" ]] && break

            # Check if loop directory still exists (graceful exit if deleted)
            if [[ ! -d "$loop_dir" ]]; then
                _graceful_stop ".humanize/rlcr directory no longer exists"
                return 0
            fi

            # Update loop status
            _split_to_array state_file_info "$(_find_state_file "$current_session_dir")"
            current_loop_status="${state_file_info[1]}"

            # Update status bar (check flag before expensive operation)
            [[ "$monitor_running" != "true" ]] && break
            _draw_status_bar "$current_session_dir" "$current_file" "$current_loop_status"
            [[ "$monitor_running" != "true" ]] && break

            # Check for new content in current file
            file_size=$(_get_file_size "$current_file")
            if [[ "$file_size" -gt "$last_size" ]]; then
                # Read and display new content
                [[ "$monitor_running" != "true" ]] && break
                tail -c +$((last_size + 1)) "$current_file" 2>/dev/null
                last_size="$file_size"
            elif [[ "$last_size" -gt 0 ]] && [[ "$file_size" -lt "$last_size" ]]; then
                # File truncated or rotated (R1.3: detect size becomes 0 unexpectedly)
                # Only trigger when file previously had content (last_size > 0)
                # This prevents treating new empty files as truncated
                tput cup $status_bar_height 0
                tput ed
                printf "\n==> Log file truncated/rotated, searching for new log...\n"
                current_file=""
                last_size=0
                last_no_log_status=""
                break
            fi
            [[ "$monitor_running" != "true" ]] && break

            # Check for newer log files and session directories
            local latest=$(_find_latest_codex_log)
            [[ "$monitor_running" != "true" ]] && break
            local latest_session=$(_find_latest_session)
            [[ "$monitor_running" != "true" ]] && break

            # Handle current session directory or log file deletion
            if [[ ! -d "$current_session_dir" ]] || [[ ! -f "$current_file" ]]; then
                # Capture deletion state BEFORE reassigning variables
                local session_was_deleted=false
                [[ ! -d "$current_session_dir" ]] && session_was_deleted=true

                if [[ -n "$latest_session" ]]; then
                    # Session or log deleted but another session exists - switch to it
                    current_session_dir="$latest_session"
                    current_file="$latest"
                    tput cup $status_bar_height 0
                    tput ed
                    if [[ "$session_was_deleted" == "true" ]]; then
                        printf "\n==> Session directory deleted, switching to: %s\n" "$(basename "$latest_session")"
                    else
                        printf "\n==> Log file deleted, switching to: %s\n" "$(basename "$latest_session")"
                    fi
                    if [[ -n "$current_file" ]]; then
                        printf "==> Log: %s\n\n" "$current_file"
                    else
                        printf "==> Waiting for log file...\n\n"
                        last_no_log_status=""  # Reset to ensure no-log branch re-renders
                    fi
                    last_size=0
                    break
                else
                    # No sessions available - wait for new ones (outer loop will handle)
                    current_session_dir=""
                    current_file=""
                    last_no_log_status=""  # Reset to re-render status
                    tput cup $status_bar_height 0
                    tput ed
                    printf "\n==> Session/log deleted, waiting for new sessions...\n"
                    break
                fi
            fi

            # Check if a newer session exists (even without log file)
            if [[ -n "$latest_session" && "$latest_session" != "$current_session_dir" ]]; then
                # New session found - switch to it
                current_session_dir="$latest_session"

                # Clear scroll region and notify
                tput cup $status_bar_height 0
                tput ed
                printf "\n==> Switching to newer session: %s\n" "$(basename "$latest_session")"

                if [[ -n "$latest" ]]; then
                    # New session has a log file
                    current_file="$latest"
                    printf "==> Log: %s\n\n" "$current_file"
                else
                    # New session has no log file yet - let outer loop handle it
                    current_file=""
                    last_no_log_status=""  # Reset to ensure no-log branch re-renders
                    printf "==> Waiting for log file...\n\n"
                fi

                # Reset for new session
                last_size=0
                break
            elif [[ "$latest" != "$current_file" && -n "$latest" ]]; then
                # Same session, but new log file (e.g., new round)
                current_file="$latest"

                # Clear scroll region and notify
                tput cup $status_bar_height 0
                tput ed
                printf "\n==> Switching to newer log: %s\n\n" "$current_file"

                # Reset for new file
                last_size=0
                break
            fi
        done
    done

    # Reset trap handlers (zsh and bash)
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        # zsh: undefine the TRAP* functions
        unfunction TRAPINT TRAPTERM 2>/dev/null || true
    else
        trap - INT TERM
    fi
}

# Main humanize function
humanize() {
    local cmd="$1"
    shift

    case "$cmd" in
        monitor)
            local target="$1"
            shift 2>/dev/null || true
            case "$target" in
                rlcr)
                    _humanize_monitor_codex "$@"
                    ;;
                pr)
                    _humanize_monitor_pr "$@"
                    ;;
                *)
                    echo "Usage: humanize monitor <rlcr|pr>"
                    echo ""
                    echo "Subcommands:"
                    echo "  rlcr    Monitor the latest RLCR loop log from .humanize/rlcr"
                    echo "  pr      Monitor the latest PR loop from .humanize/pr-loop"
                    echo ""
                    echo "Features:"
                    echo "  - Fixed status bar showing session info, round progress, model config"
                    echo "  - Goal tracker summary: Ultimate Goal, AC progress, task status"
                    echo "  - Real-time log output in scrollable area below"
                    echo "  - Automatically switches to newer logs when they appear"
                    return 1
                    ;;
            esac
            ;;
        *)
            echo "Usage: humanize <command> [args]"
            echo ""
            echo "Commands:"
            echo "  monitor rlcr    Monitor the latest RLCR loop log"
            echo "  monitor pr      Monitor the latest PR loop"
            return 1
            ;;
    esac
}

# ========================================
# PR Loop Monitor Function
# ========================================

# Monitor the latest PR loop from .humanize/pr-loop with fixed status bar and rolling tail
_humanize_monitor_pr() {
    # Enable 0-indexed arrays in zsh for bash compatibility
    [[ -n "${ZSH_VERSION:-}" ]] && setopt localoptions ksharrays

    local loop_dir=".humanize/pr-loop"
    local current_file=""
    local current_session_dir=""
    local check_interval=2  # seconds between checking for new files
    local status_bar_height=10  # number of lines for status bar
    local once_mode=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --once)
                once_mode=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    # Check if .humanize/pr-loop exists
    if [[ ! -d "$loop_dir" ]]; then
        echo "Error: $loop_dir directory not found in current directory"
        echo "Are you in a project with an active PR loop?"
        return 1
    fi

    # Use shared monitor helper for finding latest session
    _pr_find_latest_session() {
        monitor_find_latest_session "$loop_dir"
    }

    # Function to find the latest monitorable file (pr-check, pr-feedback, or pr-comment)
    _pr_find_latest_file() {
        local session_dir="$1"
        [[ ! -d "$session_dir" ]] && return

        local latest=""
        local latest_mtime=0

        # Check for pr-check files (Codex analysis output)
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            [[ ! -f "$f" ]] && continue
            local mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
            if [[ "$mtime" -gt "$latest_mtime" ]]; then
                latest="$f"
                latest_mtime="$mtime"
            fi
        done < <(find "$session_dir" -maxdepth 1 -name 'round-*-pr-check.md' -type f 2>/dev/null)

        # Check for pr-feedback files
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            [[ ! -f "$f" ]] && continue
            local mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
            if [[ "$mtime" -gt "$latest_mtime" ]]; then
                latest="$f"
                latest_mtime="$mtime"
            fi
        done < <(find "$session_dir" -maxdepth 1 -name 'round-*-pr-feedback.md' -type f 2>/dev/null)

        # Check for pr-comment files
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            [[ ! -f "$f" ]] && continue
            local mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
            if [[ "$mtime" -gt "$latest_mtime" ]]; then
                latest="$f"
                latest_mtime="$mtime"
            fi
        done < <(find "$session_dir" -maxdepth 1 -name 'round-*-pr-comment.md' -type f 2>/dev/null)

        echo "$latest"
    }

    # Use shared monitor helper for finding state file
    # Note: monitor_find_state_file returns "approve" not "approved" for approve-state.md
    # so we maintain the PR-specific status mapping here for display purposes
    _pr_find_state_file() {
        local session_dir="$1"
        local result
        result=$(monitor_find_state_file "$session_dir")
        local state_file="${result%|*}"
        local stop_reason="${result#*|}"

        # Map stop reasons to PR-friendly status names
        case "$stop_reason" in
            approve) stop_reason="approved" ;;
            maxiter) stop_reason="max-iterations" ;;
        esac

        echo "$state_file|$stop_reason"
    }

    # Function to parse state.md and return key values
    _pr_parse_state_md() {
        local state_file="$1"
        [[ ! -f "$state_file" ]] && echo "0|42|?|?|?|?|N/A" && return

        local frontmatter
        frontmatter=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$state_file" 2>/dev/null || echo "")

        local current_round=$(echo "$frontmatter" | grep "^current_round:" | sed "s/current_round: *//" | tr -d ' ')
        local max_iterations=$(echo "$frontmatter" | grep "^max_iterations:" | sed "s/max_iterations: *//" | tr -d ' ')
        local pr_number=$(echo "$frontmatter" | grep "^pr_number:" | sed "s/pr_number: *//" | tr -d ' ')
        local start_branch=$(echo "$frontmatter" | grep "^start_branch:" | sed "s/start_branch: *//" | tr -d '"' || true)
        local configured_bots=$(echo "$frontmatter" | sed -n '/^configured_bots:$/,/^[a-z_]*:/{ /^  - /{ s/^  - //; p; } }' | tr '\n' ',' | sed 's/,$//')
        local active_bots=$(echo "$frontmatter" | sed -n '/^active_bots:$/,/^[a-z_]*:/{ /^  - /{ s/^  - //; p; } }' | tr '\n' ',' | sed 's/,$//')
        local codex_model=$(echo "$frontmatter" | grep "^codex_model:" | sed "s/codex_model: *//" | tr -d ' ')
        local codex_effort=$(echo "$frontmatter" | grep "^codex_effort:" | sed "s/codex_effort: *//" | tr -d ' ')
        local started_at=$(echo "$frontmatter" | grep "^started_at:" | sed "s/started_at: *//" || true)

        # Apply defaults
        current_round=${current_round:-0}
        max_iterations=${max_iterations:-42}
        pr_number=${pr_number:-"?"}
        start_branch=${start_branch:-"?"}
        configured_bots=${configured_bots:-"none"}
        active_bots=${active_bots:-"none"}
        codex_model=${codex_model:-"gpt-5.2-codex"}
        codex_effort=${codex_effort:-"medium"}
        started_at=${started_at:-"N/A"}

        echo "$current_round|$max_iterations|$pr_number|$start_branch|$configured_bots|$active_bots|$codex_model|$codex_effort|$started_at"
    }

    # Draw the status bar at the top
    _pr_draw_status_bar() {
        local session_dir="$1"
        local monitored_file="$2"
        local loop_status="$3"
        local term_width=$(tput cols)

        # Parse state file
        local state_info=$(_pr_find_state_file "$session_dir")
        local state_file="${state_info%|*}"
        [[ -z "$loop_status" ]] && loop_status="${state_info#*|}"

        local state_values=$(_pr_parse_state_md "$state_file")
        IFS='|' read -r current_round max_iterations pr_number start_branch configured_bots active_bots codex_model codex_effort started_at <<< "$state_values"

        # Save cursor position and move to top
        tput sc

        # ANSI color codes
        local green="\033[1;32m" yellow="\033[1;33m" cyan="\033[1;36m"
        local magenta="\033[1;35m" red="\033[1;31m" reset="\033[0m"
        local bg="\033[44m" bold="\033[1m" dim="\033[2m"
        local clr_eol="\033[K"  # Clear to end of line (reduces flicker vs clearing entire area)

        # Move to top and draw directly (no pre-clearing to avoid flicker)
        tput cup 0 0
        local session_basename=$(basename "$session_dir")
        printf "${bg}${bold}%-${term_width}s${reset}${clr_eol}\n" " PR Loop Monitor"
        printf "${cyan}Session:${reset} ${session_basename}    ${cyan}PR:${reset} #${pr_number}    ${cyan}Branch:${reset} ${start_branch}${clr_eol}\n"
        printf "${green}Round:${reset}   ${bold}${current_round}${reset} / ${max_iterations}    ${yellow}Codex:${reset} ${codex_model} (${codex_effort})${clr_eol}\n"

        # Detect phase and determine status color
        local phase=""
        local phase_display=""
        if type get_pr_loop_phase &>/dev/null; then
            phase=$(get_pr_loop_phase "$session_dir")
            phase_display=$(get_pr_loop_phase_display "$phase" "$active_bots")
        fi

        # Loop status line with color based on phase/status
        local status_color="${green}"
        case "$phase" in
            approved) status_color="${cyan}" ;;
            cancelled) status_color="${yellow}" ;;
            maxiter) status_color="${red}" ;;
            codex_analyzing) status_color="${magenta}" ;;
            waiting_initial_review) status_color="${yellow}" ;;
            waiting_reviewer) status_color="${green}" ;;
            *) status_color="${dim}" ;;
        esac

        if [[ -n "$phase_display" ]]; then
            printf "${magenta}Phase:${reset}   ${status_color}${phase_display}${reset}${clr_eol}\n"
        else
            # Fallback to loop_status if phase detection not available
            case "$loop_status" in
                active) status_color="${green}" ;;
                approved|completed) status_color="${cyan}" ;;
                cancelled) status_color="${yellow}" ;;
                max-iterations) status_color="${red}" ;;
                *) status_color="${dim}" ;;
            esac
            printf "${magenta}Status:${reset}  ${status_color}${loop_status}${reset}${clr_eol}\n"
        fi

        # Bot status
        printf "${cyan}Configured Bots:${reset} ${configured_bots}${clr_eol}\n"
        if [[ "$active_bots" == "none" ]] || [[ -z "$active_bots" ]]; then
            printf "${green}Active Bots:${reset}     ${green}all approved${reset}${clr_eol}\n"
        else
            printf "${yellow}Active Bots:${reset}     ${active_bots}${clr_eol}\n"
        fi

        # Goal tracker issue stats
        local goal_tracker_file="$session_dir/goal-tracker.md"
        if [[ -f "$goal_tracker_file" ]] && type humanize_parse_pr_goal_tracker &>/dev/null; then
            local tracker_stats=$(humanize_parse_pr_goal_tracker "$goal_tracker_file")
            local total_issues resolved_issues remaining_issues last_reviewer
            IFS='|' read -r total_issues resolved_issues remaining_issues last_reviewer <<< "$tracker_stats"
            if [[ "$total_issues" != "0" ]] || [[ "$resolved_issues" != "0" ]]; then
                printf "${cyan}Issues:${reset}          Found: ${yellow}${total_issues}${reset}, Resolved: ${green}${resolved_issues}${reset}, Remaining: ${red}${remaining_issues}${reset}${clr_eol}\n"
            fi
        fi

        # Started time
        local start_display="$started_at"
        if [[ "$started_at" != "N/A" ]]; then
            start_display=$(echo "$started_at" | sed 's/T/ /; s/Z/ UTC/')
        fi
        printf "${dim}Started:${reset} ${start_display}${clr_eol}\n"

        # Currently monitoring
        local file_basename=""
        [[ -n "$monitored_file" ]] && file_basename=$(basename "$monitored_file")
        printf "${dim}Watching:${reset} ${file_basename:-none}${clr_eol}\n"

        # Separator
        printf "%-${term_width}s${clr_eol}\n" "$(printf '%*s' "$term_width" | tr ' ' '-')"

        # Restore cursor position
        tput rc
    }

    # Track state for cleanup
    local TAIL_PID=""
    local monitor_running=true
    local cleanup_done=false

    # Cleanup function - called by trap
    # Must work cleanly in both bash and zsh
    _pr_cleanup() {
        # Prevent multiple cleanup calls
        [[ "${cleanup_done:-false}" == "true" ]] && return
        cleanup_done=true
        monitor_running=false

        # Reset traps to prevent re-triggering
        trap - INT TERM EXIT 2>/dev/null || true

        # Kill background tail if running
        if [[ -n "${TAIL_PID:-}" ]]; then
            if kill -0 "$TAIL_PID" 2>/dev/null; then
                kill "$TAIL_PID" 2>/dev/null || true
                # Use timeout-safe wait
                ( wait "$TAIL_PID" 2>/dev/null ) &
                wait $! 2>/dev/null || true
            fi
        fi

        # Show cursor and restore terminal
        tput cnorm 2>/dev/null || true
        tput rmcup 2>/dev/null || true
        echo ""
        echo "Monitor stopped."
    }

    # Set up signal handlers (bash/zsh compatible)
    # Use TRAPINT/TRAPTERM for zsh, standard trap for bash
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        # zsh: use TRAPINT and TRAPTERM for better handling
        TRAPINT() { _pr_cleanup; return 130; }
        TRAPTERM() { _pr_cleanup; return 143; }
        # Also set EXIT trap for clean exit
        trap '_pr_cleanup' EXIT
    else
        # bash: use standard trap
        trap '_pr_cleanup' EXIT INT TERM
    fi

    # One-shot mode: print status once and exit (for testing and scripting)
    if [[ "$once_mode" == "true" ]]; then
        local session_dir=$(_pr_find_latest_session)
        if [[ -z "$session_dir" ]]; then
            echo "No PR loop sessions found in $loop_dir"
            return 1
        fi

        local state_info=$(_pr_find_state_file "$session_dir")
        local state_file="${state_info%|*}"
        local loop_status="${state_info#*|}"

        if [[ -z "$state_file" ]]; then
            echo "No state file found in $session_dir"
            return 1
        fi

        local state_values=$(_pr_parse_state_md "$state_file")
        IFS='|' read -r current_round max_iterations pr_number start_branch configured_bots active_bots codex_model codex_effort started_at <<< "$state_values"

        # Get phase for --once mode display
        local phase=""
        local phase_display=""
        if declare -f get_pr_loop_phase &>/dev/null; then
            phase=$(get_pr_loop_phase "$session_dir")
            phase_display=$(get_pr_loop_phase_display "$phase" "$active_bots")
        fi

        echo "=========================================="
        echo " PR Loop Monitor"
        echo "=========================================="
        echo ""
        echo "Session: $(basename "$session_dir")"
        if [[ -n "$phase_display" ]]; then
            echo "Phase:   $phase_display"
        else
            echo "Status:  $loop_status"
        fi
        echo ""
        echo "PR Number:       #$pr_number"
        echo "Branch:          $start_branch"
        echo "Configured Bots: ${configured_bots:-none}"
        echo "Active Bots:     ${active_bots:-none}"
        echo ""
        echo "Round:         $current_round / $max_iterations"
        echo "Codex:         $codex_model:$codex_effort"
        echo "Started:       $started_at"
        echo ""
        echo "=========================================="
        echo " Recent Files"
        echo "=========================================="
        echo ""

        # List recent round files
        local round_files
        round_files=$(find "$session_dir" -maxdepth 1 -name 'round-*.md' -type f 2>/dev/null)
        if [[ -n "$round_files" ]]; then
            echo "$round_files" | xargs ls -lt 2>/dev/null | head -10 | while read -r line; do
                echo "  $line"
            done
        fi

        echo ""
        echo "=========================================="
        echo " Latest Activity"
        echo "=========================================="
        echo ""

        local latest_file=$(_pr_find_latest_file "$session_dir")
        if [[ -n "$latest_file" && -f "$latest_file" ]]; then
            echo "Latest: $(basename "$latest_file")"
            echo "----------------------------------------"
            tail -20 "$latest_file"
            echo ""
        fi

        echo "=========================================="
        return 0
    fi

    # Initialize terminal
    tput smcup  # Save screen
    tput civis  # Hide cursor
    clear

    # Create scrolling region below status bar
    tput csr $status_bar_height $(($(tput lines) - 1))

    # Main monitoring loop
    while [[ "$monitor_running" == "true" ]]; do
        # Find latest session
        local session_dir=$(_pr_find_latest_session)
        if [[ -z "$session_dir" ]]; then
            tput cup $status_bar_height 0
            echo "Waiting for PR loop session..."
            sleep "$check_interval"
            continue
        fi

        # Check if session changed
        if [[ "$session_dir" != "$current_session_dir" ]]; then
            current_session_dir="$session_dir"
            current_file=""
            [[ -n "$TAIL_PID" ]] && kill "$TAIL_PID" 2>/dev/null
            TAIL_PID=""
        fi

        # Find latest file to monitor
        local latest_file=$(_pr_find_latest_file "$session_dir")

        # Get loop status
        local state_info=$(_pr_find_state_file "$session_dir")
        local loop_status="${state_info#*|}"

        # Update status bar
        _pr_draw_status_bar "$session_dir" "$latest_file" "$loop_status"

        # Check if file changed or new file appeared
        if [[ "$latest_file" != "$current_file" ]] && [[ -n "$latest_file" ]]; then
            current_file="$latest_file"

            # Kill old tail process
            [[ -n "$TAIL_PID" ]] && kill "$TAIL_PID" 2>/dev/null

            # Clear content area and show new file
            tput cup $status_bar_height 0
            tput ed  # Clear to end of screen

            # Start tailing the new file
            tail -n +1 -f "$current_file" 2>/dev/null &
            TAIL_PID=$!
        fi

        # If no file to monitor yet, show waiting message
        if [[ -z "$current_file" ]]; then
            tput cup $status_bar_height 0
            echo "Waiting for PR loop activity..."
        fi

        sleep "$check_interval"
    done

    # Reset trap handlers (zsh and bash)
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        # zsh: undefine the TRAP* functions
        unfunction TRAPINT TRAPTERM 2>/dev/null || true
    else
        trap - INT TERM EXIT
    fi
}
