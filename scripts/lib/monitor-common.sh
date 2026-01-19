#!/bin/bash
#
# monitor-common.sh - Shared utilities for humanize monitor functions
#
# This file contains common functions used by both RLCR and PR loop monitors.
# It should be sourced by humanize.sh rather than executed directly.

# ========================================
# ANSI Color Constants
# ========================================

# These are defined as functions to allow dynamic evaluation
# (some terminals may not support all colors)
monitor_color_green() { echo "\033[1;32m"; }
monitor_color_yellow() { echo "\033[1;33m"; }
monitor_color_cyan() { echo "\033[1;36m"; }
monitor_color_magenta() { echo "\033[1;35m"; }
monitor_color_red() { echo "\033[1;31m"; }
monitor_color_reset() { echo "\033[0m"; }
monitor_color_bg() { echo "\033[44m"; }
monitor_color_bold() { echo "\033[1m"; }
monitor_color_dim() { echo "\033[2m"; }
monitor_color_blue() { echo "\033[1;34m"; }

# ========================================
# File Utilities
# ========================================

# Get file size (cross-platform: Linux uses -c%s, macOS uses -f%z)
# Usage: monitor_get_file_size "/path/to/file"
# Returns: file size in bytes, or 0 if file doesn't exist
monitor_get_file_size() {
    local file="$1"
    stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0
}

# Find latest directory by timestamp name pattern (YYYY-MM-DD_HH-MM-SS)
# Usage: monitor_find_latest_session "/path/to/loop/dir"
# Returns: path to latest session directory, or empty string if none found
monitor_find_latest_session() {
    local loop_dir="$1"
    local latest_session=""

    if [[ ! -d "$loop_dir" ]]; then
        echo ""
        return
    fi

    # Use find instead of glob to avoid zsh "no matches found" errors
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

# ========================================
# Terminal Utilities
# ========================================

# Setup terminal for split view with fixed header
# Usage: monitor_setup_terminal <header_height>
monitor_setup_terminal() {
    local header_height="$1"

    # Clear screen
    clear

    # Set scroll region (leave top lines for status bar)
    printf "\033[${header_height};%dr" $(tput lines)

    # Move cursor to scroll region
    tput cup "$header_height" 0
}

# Restore terminal to normal state
# Usage: monitor_restore_terminal
monitor_restore_terminal() {
    # Reset scroll region to full screen
    printf "\033[r"

    # Move to bottom
    tput cup $(tput lines) 0
}

# ========================================
# Signal Handling
# ========================================

# Setup signal handlers for clean Ctrl+C handling
# This function should be called with the cleanup function name as argument
#
# Usage: monitor_setup_signal_handlers "cleanup_function_name"
#
# The cleanup function should:
# 1. Set a cleanup_done flag to prevent multiple calls
# 2. Set monitor_running=false to stop loops
# 3. Kill any background processes
# 4. Restore terminal state
#
# Example cleanup function:
#   _cleanup() {
#       [[ "$cleanup_done" == "true" ]] && return
#       cleanup_done=true
#       monitor_running=false
#       trap - INT TERM 2>/dev/null || true
#       [[ -n "$TAIL_PID" ]] && kill "$TAIL_PID" 2>/dev/null
#       monitor_restore_terminal
#       echo "Stopped."
#   }
#
# Note: This function is a documentation reference. The actual signal
# setup should be done inline in each monitor function for proper scope
# handling of local variables (cleanup_done, monitor_running, etc.)

# ========================================
# Status Color Helper
# ========================================

# Get color code for loop status
# Usage: color=$(monitor_get_status_color "active")
monitor_get_status_color() {
    local status="$1"
    case "$status" in
        active) echo "\033[1;32m" ;;  # green
        completed) echo "\033[1;36m" ;;  # cyan
        failed|error|timeout) echo "\033[1;31m" ;;  # red
        cancelled) echo "\033[1;33m" ;;  # yellow
        max-iterations) echo "\033[1;31m" ;;  # red
        unknown) echo "\033[2m" ;;  # dim
        *) echo "\033[1;33m" ;;  # yellow (default for unknown states)
    esac
}

# ========================================
# State File Detection
# ========================================

# Find state file in session directory
# Returns: state_file_path|loop_status
# - If state.md exists: returns "path/state.md|active"
# - If <STOP_REASON>-state.md exists: returns "path/<file>|<stop_reason>"
# - If no state file found: returns "|unknown"
#
# Usage: monitor_find_state_file "/path/to/session"
monitor_find_state_file() {
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
    # Common stop reasons: completed, failed, cancelled, timeout, error, approve, maxiter
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

# ========================================
# YAML Frontmatter Parsing
# ========================================

# Extract a value from YAML frontmatter
# Usage: monitor_get_yaml_value "key" "/path/to/file.md"
# Returns: The value, or empty string if not found
monitor_get_yaml_value() {
    local key="$1"
    local file="$2"

    [[ ! -f "$file" ]] && return

    # Extract frontmatter (between first and second ---)
    local frontmatter
    frontmatter=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$file" 2>/dev/null)

    # Extract value for key
    echo "$frontmatter" | grep -E "^${key}:" | sed "s/${key}: *//" | tr -d '"'
}

# ========================================
# Progress Display Helpers
# ========================================

# Format a timestamp for display
# Converts ISO format (2026-01-18T10:00:00Z) to readable format
# Usage: monitor_format_timestamp "2026-01-18T10:00:00Z"
monitor_format_timestamp() {
    local timestamp="$1"

    if [[ "$timestamp" == "N/A" || -z "$timestamp" ]]; then
        echo "N/A"
        return
    fi

    # Convert ISO format to more readable format
    echo "$timestamp" | sed 's/T/ /; s/Z/ UTC/'
}

# Truncate a string for display, adding ellipsis
# Usage: monitor_truncate_string "long string" <max_length> <direction>
# direction: "start" (keep end) or "end" (keep start, default)
monitor_truncate_string() {
    local str="$1"
    local max_len="$2"
    local direction="${3:-end}"

    if [[ ${#str} -le $max_len ]]; then
        echo "$str"
        return
    fi

    if [[ "$direction" == "start" ]]; then
        # Keep end, truncate start
        local suffix_len=$((max_len - 3))
        echo "...${str: -$suffix_len}"
    else
        # Keep start, truncate end
        local prefix_len=$((max_len - 3))
        echo "${str:0:$prefix_len}..."
    fi
}

# ========================================
# PR Loop Phase Detection
# ========================================

# Detect current PR loop phase from file state
# Returns: one of: approved, cancelled, maxiter, codex_analyzing, waiting_initial_review, waiting_reviewer
#
# Usage: get_pr_loop_phase "/path/to/session"
get_pr_loop_phase() {
    local session_dir="$1"

    [[ ! -d "$session_dir" ]] && echo "unknown" && return

    # Check for final states first
    [[ -f "$session_dir/approve-state.md" ]] && echo "approved" && return
    [[ -f "$session_dir/cancel-state.md" ]] && echo "cancelled" && return
    [[ -f "$session_dir/maxiter-state.md" ]] && echo "maxiter" && return

    # Check for Codex running (codex log file being written)
    # Look for recent round-*-pr-check.md files that are still growing
    local latest_check
    latest_check=$(find "$session_dir" -maxdepth 1 -name 'round-*-pr-check.md' -type f -mmin -1 2>/dev/null | head -1)
    if [[ -n "$latest_check" ]]; then
        # Check if file is still growing (modified in last 5 seconds)
        local now_epoch
        local file_epoch
        now_epoch=$(date +%s)
        file_epoch=$(stat -c %Y "$latest_check" 2>/dev/null || stat -f %m "$latest_check" 2>/dev/null || echo 0)
        if [[ $((now_epoch - file_epoch)) -lt 5 ]]; then
            echo "codex_analyzing"
            return
        fi
    fi

    # Check state.md for round info
    if [[ -f "$session_dir/state.md" ]]; then
        local frontmatter
        frontmatter=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$session_dir/state.md" 2>/dev/null)

        local current_round
        local startup_case
        current_round=$(echo "$frontmatter" | grep "^current_round:" | sed "s/current_round: *//" | tr -d ' ')
        startup_case=$(echo "$frontmatter" | grep "^startup_case:" | sed "s/startup_case: *//" | tr -d ' ')

        current_round=${current_round:-0}
        startup_case=${startup_case:-1}

        if [[ "$current_round" -eq 0 && "$startup_case" -eq 1 ]]; then
            echo "waiting_initial_review"
        else
            echo "waiting_reviewer"
        fi
    else
        echo "unknown"
    fi
}

# Get human-readable description for PR loop phase
# Usage: get_pr_loop_phase_display "waiting_reviewer" "claude,codex"
get_pr_loop_phase_display() {
    local phase="$1"
    local active_bots="$2"

    case "$phase" in
        approved)
            echo "All reviews approved"
            ;;
        cancelled)
            echo "Loop cancelled"
            ;;
        maxiter)
            echo "Max iterations reached"
            ;;
        codex_analyzing)
            echo "Codex analyzing reviews..."
            ;;
        waiting_initial_review)
            if [[ -n "$active_bots" && "$active_bots" != "none" ]]; then
                echo "Waiting for initial PR review from $active_bots"
            else
                echo "Waiting for initial PR review"
            fi
            ;;
        waiting_reviewer)
            if [[ -n "$active_bots" && "$active_bots" != "none" ]]; then
                echo "Waiting for $active_bots (polling...)"
            else
                echo "Waiting for reviews (polling...)"
            fi
            ;;
        *)
            echo "Unknown phase"
            ;;
    esac
}

# ========================================
# Goal Tracker Parsing
# ========================================

# Parse goal-tracker.md and return summary values
# Returns: total_acs|completed_acs|active_tasks|completed_tasks|deferred_tasks|open_issues|goal_summary
# Usage: parse_goal_tracker "/path/to/goal-tracker.md"
parse_goal_tracker() {
    local tracker_file="$1"
    if [[ ! -f "$tracker_file" ]]; then
        echo "0|0|0|0|0|0|No goal tracker"
        return
    fi

    # Helper: count data rows in a markdown table section (total rows minus header and separator)
    _count_table_rows() {
        local start_pattern="$1"
        local end_pattern="$2"
        local row_count
        row_count=$(sed -n "/${start_pattern}/,/${end_pattern}/p" "$tracker_file" | grep -cE '^\|' || true)
        row_count=${row_count:-0}
        echo $((row_count > 2 ? row_count - 2 : 0))
    }

    # Count Acceptance Criteria (supports both table and list formats)
    # Stop at next section header (##) to avoid counting ACs from other sections
    local total_acs
    total_acs=$(sed -n '/### Acceptance Criteria/,/^##/p' "$tracker_file" \
        | grep -cE '(^\|\s*\*{0,2}AC-?[0-9]+|^-\s*\*{0,2}AC-?[0-9]+)' || true)
    total_acs=${total_acs:-0}

    # Count Active Tasks
    local total_active_section_rows
    local completed_in_active
    local deferred_in_active

    total_active_section_rows=$(sed -n '/#### Active Tasks/,/^###/p' "$tracker_file" \
        | grep -cE '^\|' || true)
    total_active_section_rows=${total_active_section_rows:-0}
    local total_active_data_rows=$((total_active_section_rows > 2 ? total_active_section_rows - 2 : 0))

    completed_in_active=$(sed -n '/#### Active Tasks/,/^###/p' "$tracker_file" \
        | sed 's/\*\*//g' \
        | grep -ciE '^\|[^|]+\|[^|]+\|[[:space:]]*completed[[:space:]]*\|' || true)
    completed_in_active=${completed_in_active:-0}

    deferred_in_active=$(sed -n '/#### Active Tasks/,/^###/p' "$tracker_file" \
        | sed 's/\*\*//g' \
        | grep -ciE '^\|[^|]+\|[^|]+\|[[:space:]]*deferred[[:space:]]*\|' || true)
    deferred_in_active=${deferred_in_active:-0}

    local active_tasks=$((total_active_data_rows - completed_in_active - deferred_in_active))
    [[ "$active_tasks" -lt 0 ]] && active_tasks=0

    # Count Completed tasks
    local completed_tasks
    completed_tasks=$(_count_table_rows '### Completed and Verified' '^###')

    # Count verified ACs (unique AC entries in Completed section)
    local completed_acs
    completed_acs=$(sed -n '/### Completed and Verified/,/^###/p' "$tracker_file" \
        | grep -oE '^\|\s*AC-?[0-9]+' | sort -u | wc -l | tr -d ' ')
    completed_acs=${completed_acs:-0}

    # Count Deferred tasks
    local deferred_tasks
    deferred_tasks=$(_count_table_rows '### Explicitly Deferred' '^###')

    # Count Open Issues
    local open_issues
    open_issues=$(_count_table_rows '### Open Issues' '^###')

    # Extract Ultimate Goal summary
    local goal_summary
    goal_summary=$(sed -n '/### Ultimate Goal/,/^###/p' "$tracker_file" \
        | grep -v '^###' | grep -v '^$' | grep -v '^\[To be' \
        | head -1 | sed 's/^[[:space:]]*//' | cut -c1-60)
    goal_summary="${goal_summary:-No goal defined}"

    echo "${total_acs}|${completed_acs}|${active_tasks}|${completed_tasks}|${deferred_tasks}|${open_issues}|${goal_summary}"
}

# Parse PR goal-tracker.md for issue statistics
# Returns: total_issues|resolved_issues|remaining_issues|last_reviewer
# Usage: humanize_parse_pr_goal_tracker "/path/to/goal-tracker.md"
humanize_parse_pr_goal_tracker() {
    local tracker_file="$1"
    if [[ ! -f "$tracker_file" ]]; then
        echo "0|0|0|none"
        return
    fi

    # Extract from Total Statistics section
    # Format: - Total Issues Found: N
    local total_issues
    total_issues=$(grep -E "^- Total Issues Found:" "$tracker_file" | sed 's/.*: //' | tr -d ' ')
    total_issues=${total_issues:-0}

    local resolved_issues
    resolved_issues=$(grep -E "^- Total Issues Resolved:" "$tracker_file" | sed 's/.*: //' | tr -d ' ')
    resolved_issues=${resolved_issues:-0}

    local remaining_issues
    remaining_issues=$(grep -E "^- Remaining:" "$tracker_file" | sed 's/.*: //' | tr -d ' ')
    remaining_issues=${remaining_issues:-0}

    # Get last reviewer from Issue Summary table (last row, Reviewer column)
    # Table format: | ID | Reviewer | Round | Status | Description |
    # Pattern matches rows like "|1|..." or "| 1 |..." (with or without spaces)
    local last_reviewer
    last_reviewer=$(sed -n '/## Issue Summary/,/^##/p' "$tracker_file" \
        | grep -E '^\|[[:space:]]*[0-9]+' | tail -1 | cut -d'|' -f3 | tr -d ' ')
    last_reviewer=${last_reviewer:-none}

    echo "${total_issues}|${resolved_issues}|${remaining_issues}|${last_reviewer}"
}
