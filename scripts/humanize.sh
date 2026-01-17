#!/bin/bash
# humanize.sh - Humanize shell utilities
# Part of rc.d configuration
# Compatible with both bash and zsh

# Monitor the latest Codex run log from .humanize/rlcr
# Automatically switches to newer logs when they appear
# Features a fixed status bar at the top showing session info
_humanize_monitor_codex() {
    # Enable 0-indexed arrays in zsh for bash compatibility
    # This affects all _split_to_array calls within this function
    [[ -n "$ZSH_VERSION" ]] && setopt localoptions ksharrays

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

    # Function to find the latest session directory
    _find_latest_session() {
        local latest_session=""
        # Check if loop_dir exists before glob operation (prevents zsh "no matches found" error)
        if [[ ! -d "$loop_dir" ]]; then
            echo ""
            return
        fi
        # Use find instead of glob to avoid zsh "no matches found" errors
        # find is safe even when directory is empty or has no matching files
        while IFS= read -r session_dir; do
            [[ -z "$session_dir" ]] && continue
            [[ ! -d "$session_dir" ]] && continue

            local session_name=$(basename "$session_dir")
            if [[ "$session_name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]]; then
                if [[ -z "$latest_session" ]] || [[ "$session_name" > "$(basename "$latest_session")" ]]; then
                    latest_session="$session_dir"
                fi
            fi
        done < <(find "$loop_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
        echo "$latest_session"
    }

    # Function to find the latest codex log file
    # Log files are now in $HOME/.cache/humanize/<sanitized-project-path>/<timestamp>/ to avoid context pollution
    _find_latest_codex_log() {
        local latest=""
        local latest_session=""
        local latest_round=-1
        local cache_base="$HOME/.cache/humanize"

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

            # Use find instead of glob to avoid zsh "no matches found" errors
            # find is safe even when directory is empty or has no matching files
            while IFS= read -r log_file; do
                [[ -z "$log_file" ]] && continue
                [[ ! -f "$log_file" ]] && continue

                local log_basename=$(basename "$log_file")
                local round_num="${log_basename#round-}"
                round_num="${round_num%%-codex-run.log}"

                if [[ -z "$latest" ]] || \
                   [[ "$session_name" > "$latest_session" ]] || \
                   [[ "$session_name" == "$latest_session" && "$round_num" -gt "$latest_round" ]]; then
                    latest="$log_file"
                    latest_session="$session_name"
                    latest_round="$round_num"
                fi
            done < <(find "$cache_dir" -maxdepth 1 -name 'round-*-codex-run.log' -type f 2>/dev/null)
        done < <(find "$loop_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

        echo "$latest"
    }

    # Find the state file for a session directory
    # Returns: state_file_path|loop_status
    # - If state.md exists: returns "state.md|active"
    # - If <STOP_REASON>-state.md exists: returns "<file>|<stop_reason>"
    # - If no state file found: returns "|unknown"
    _find_state_file() {
        local session_dir="$1"
        if [[ -z "$session_dir" || ! -d "$session_dir" ]]; then
            echo "|unknown"
            return
        fi

        # Priority 1: state.md indicates active loop
        if [[ -f "$session_dir/state.md" ]]; then
            echo "$session_dir/state.md|active"
            return
        fi

        # Priority 2: Look for <STOP_REASON>-state.md files
        # Common stop reasons: completed, failed, cancelled, timeout, error
        # Use find instead of glob to avoid zsh "no matches found" errors
        local state_file=""
        local stop_reason=""
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            if [[ -f "$f" ]]; then
                state_file="$f"
                # Extract stop reason from filename (e.g., "completed-state.md" -> "completed")
                local basename=$(basename "$f")
                stop_reason="${basename%-state.md}"
                break
            fi
        done < <(find "$session_dir" -maxdepth 1 -name '*-state.md' -type f 2>/dev/null)

        if [[ -n "$state_file" ]]; then
            echo "$state_file|$stop_reason"
        else
            echo "|unknown"
        fi
    }

    # Parse state.md and return values
    _parse_state_md() {
        local state_file="$1"
        if [[ ! -f "$state_file" ]]; then
            echo "N/A|N/A|N/A|N/A|N/A|N/A"
            return
        fi

        local current_round=$(grep -E "^current_round:" "$state_file" 2>/dev/null | sed 's/current_round: *//')
        local max_iterations=$(grep -E "^max_iterations:" "$state_file" 2>/dev/null | sed 's/max_iterations: *//')
        local codex_model=$(grep -E "^codex_model:" "$state_file" 2>/dev/null | sed 's/codex_model: *//')
        local codex_effort=$(grep -E "^codex_effort:" "$state_file" 2>/dev/null | sed 's/codex_effort: *//')
        local started_at=$(grep -E "^started_at:" "$state_file" 2>/dev/null | sed 's/started_at: *//')
        local plan_file=$(grep -E "^plan_file:" "$state_file" 2>/dev/null | sed 's/plan_file: *//')

        echo "${current_round:-N/A}|${max_iterations:-N/A}|${codex_model:-N/A}|${codex_effort:-N/A}|${started_at:-N/A}|${plan_file:-N/A}"
    }

    # Parse goal-tracker.md and return summary values
    # Returns: total_acs|completed_acs|active_tasks|completed_tasks|deferred_tasks|open_issues|goal_summary
    _parse_goal_tracker() {
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

    # Parse git status and return summary values
    # Returns: modified|added|deleted|untracked|insertions|deletions
    _parse_git_status() {
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

    # Split pipe-delimited string into array (bash/zsh compatible)
    # Usage: _split_to_array "output_array_name" "value1|value2|value3"
    _split_to_array() {
        local arr_name="$1"
        local input="$2"
        if [[ -n "$ZSH_VERSION" ]]; then
            # zsh: use parameter expansion to split on |
            eval "$arr_name=(\"\${(@s:|:)input}\")"
        else
            # bash: use read -ra
            eval "IFS='|' read -ra $arr_name <<< \"\$input\""
        fi
    }

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

        # Clear status bar area (10 lines)
        tput cup 0 0
        for _ in {1..11}; do printf "%-${term_width}s\n" ""; done

        # Draw header and session info
        tput cup 0 0
        local session_basename=$(basename "$session_dir")
        printf "${bg}${bold}%-${term_width}s${reset}\n" " Humanize Loop Monitor"
        printf "${cyan}Session:${reset}  ${session_basename}    ${cyan}Started:${reset} ${start_display}\n"
        printf "${green}Round:${reset}    ${bold}${current_round}${reset} / ${max_iterations}    ${yellow}Model:${reset} ${codex_model} (${codex_effort})\n"

        # Loop status line with color based on status
        local status_color="${green}"
        case "$loop_status" in
            active) status_color="${green}" ;;
            completed) status_color="${cyan}" ;;
            failed|error|timeout) status_color="${red}" ;;
            cancelled) status_color="${yellow}" ;;
            unknown) status_color="${dim}" ;;
            *) status_color="${yellow}" ;;
        esac
        printf "${magenta}Status:${reset}   ${status_color}${loop_status}${reset}\n"

        # Progress line (color based on completion status)
        local ac_color="${green}"
        [[ "$completed_acs" -lt "$total_acs" ]] && ac_color="${yellow}"
        local issue_color="${dim}"
        [[ "$open_issues" -gt 0 ]] && issue_color="${red}"

        # Use magenta for Progress and Git labels (status/data lines)
        printf "${magenta}Progress:${reset} ${ac_color}ACs: ${completed_acs}/${total_acs}${reset}  Tasks: ${active_tasks} active, ${completed_tasks} done"
        [[ "$deferred_tasks" -gt 0 ]] && printf "  ${yellow}${deferred_tasks} deferred${reset}"
        [[ "$open_issues" -gt 0 ]] && printf "  ${issue_color}Issues: ${open_issues}${reset}"
        printf "\n"

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
        printf "\n"

        # Use cyan for Goal, Plan, Log labels (context/reference lines)
        printf "${cyan}Goal:${reset}     ${goal_display}\n"
        printf "${cyan}Plan:${reset}     ${plan_display}\n"
        printf "${cyan}Log:${reset}      ${log_file}\n"
        printf "%.s─" $(seq 1 $term_width)
        printf "\n"

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
    _cleanup() {
        # Prevent multiple cleanup calls
        [[ "$cleanup_done" == "true" ]] && return
        cleanup_done=true
        monitor_running=false

        # Reset traps to prevent re-triggering
        trap - INT TERM

        # Kill background processes
        if [[ -n "$tail_pid" ]] && kill -0 $tail_pid 2>/dev/null; then
            kill $tail_pid 2>/dev/null
            wait $tail_pid 2>/dev/null
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
        [[ "$cleanup_done" == "true" ]] && return

        # Call _cleanup to do the actual cleanup work (per plan requirement)
        _cleanup

        # Print the specific graceful stop message after cleanup
        echo "Monitoring stopped: $reason"
        echo "The RLCR loop may have been cancelled or the directory was deleted."
    }

    # Set up signal handlers (bash/zsh compatible)
    trap '_cleanup' INT TERM

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

    # Get file size (cross-platform: Linux uses -c%s, macOS uses -f%z)
    _get_file_size() {
        stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0
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

    # Reset trap handlers
    trap - INT TERM
}

# Main humanize function
humanize() {
    local cmd="$1"
    shift

    case "$cmd" in
        monitor)
            local target="$1"
            case "$target" in
                rlcr-loop)
                    _humanize_monitor_codex
                    ;;
                *)
                    echo "Usage: humanize monitor rlcr-loop"
                    echo ""
                    echo "Monitor the latest RLCR loop log from .humanize/rlcr"
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
            echo "  monitor rlcr-loop    Monitor the latest RLCR loop log"
            return 1
            ;;
    esac
}
