#!/bin/bash
#
# monitor-skill.sh - Skill monitor for humanize
#
# Provides the _humanize_monitor_skill function for monitoring
# ask-codex skill invocations from .humanize/skill directory.
#
# This file is sourced by humanize.sh and depends on:
# - monitor-common.sh (monitor_get_yaml_value, monitor_format_timestamp, etc.)
# - humanize.sh (humanize_split_to_array)

# Monitor ask-codex skill invocations from .humanize/skill
# Shows a fixed status bar with aggregate stats and latest invocation details,
# with live output display in the scrollable area below.
_humanize_monitor_skill() {
    # Enable 0-indexed arrays in zsh for bash compatibility
    # no_monitor suppresses background job notifications ([1] PID)
    [[ -n "${ZSH_VERSION:-}" ]] && setopt localoptions ksharrays no_monitor

    local skill_dir=".humanize/skill"
    local current_skill_dir=""
    local current_file=""
    local check_interval=2
    local status_bar_height=9
    local once_mode=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --once) once_mode=true; shift ;;
            *) shift ;;
        esac
    done

    # Check if .humanize/skill exists
    if [[ ! -d "$skill_dir" ]]; then
        echo "Error: $skill_dir directory not found in current directory"
        echo "Run /humanize:ask-codex first to create skill invocations"
        return 1
    fi

    # List all valid skill invocation directories sorted newest-first
    # Skill dirs use YYYY-MM-DD_HH-MM-SS or YYYY-MM-DD_HH-MM-SS-PID-RANDOM naming
    _skill_list_dirs_sorted() {
        local dirs=()
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            [[ ! -d "$d" ]] && continue
            local name=$(basename "$d")
            [[ "$name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2} ]] && dirs+=("$d")
        done < <(find "$skill_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
        printf '%s\n' "${dirs[@]}" | sort -r
    }

    # Find latest skill invocation directory (by timestamp in name)
    _skill_find_latest_dir() {
        _skill_list_dirs_sorted | head -1
    }

    # Find the best invocation to monitor: newest with watchable content.
    # Falls back to the absolute newest if nothing has content.
    # Returns: dir|file (pipe-delimited pair)
    _skill_find_best_invocation() {
        local best_dir="" best_file=""
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            local f=$(_skill_find_monitored_file "$d")
            if [[ -n "$f" && -s "$f" ]]; then
                best_dir="$d"; best_file="$f"
                break
            fi
        done < <(_skill_list_dirs_sorted)

        # Fallback to absolute newest even if no content
        if [[ -z "$best_dir" ]]; then
            best_dir=$(_skill_find_latest_dir)
            [[ -n "$best_dir" ]] && best_file=$(_skill_find_monitored_file "$best_dir")
        fi
        echo "${best_dir}|${best_file}"
    }

    # Count invocations by status
    # Returns: total|success|error|timeout|empty|running
    _skill_count_stats() {
        local total=0 success=0 err=0 tmo=0 empty=0 running=0
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            [[ ! -d "$d" ]] && continue
            local name=$(basename "$d")
            [[ ! "$name" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2} ]] && continue
            ((total++))
            if [[ -f "$d/metadata.md" ]]; then
                local st=$(monitor_get_yaml_value "status" "$d/metadata.md")
                case "$st" in
                    success) ((success++)) ;;
                    error) ((err++)) ;;
                    timeout) ((tmo++)) ;;
                    empty_response) ((empty++)) ;;
                esac
            else
                ((running++))
            fi
        done < <(find "$skill_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
        echo "$total|$success|$err|$tmo|$empty|$running"
    }

    # Extract question text from input.md
    _skill_get_question() {
        local dir="$1"
        [[ ! -f "$dir/input.md" ]] && echo "N/A" && return
        local q=$(sed -n '/^## Question$/,/^## /p' "$dir/input.md" \
            | grep -v '^##' | grep -v '^$' | head -1 | sed 's/^[[:space:]]*//')
        echo "${q:-N/A}"
    }

    # Find the global cache directory for a skill invocation (display only)
    # Returns the ~/.cache/humanize/... path if it exists, empty otherwise.
    _skill_find_cache_dir() {
        local unique_id=$(basename "$1")
        local project_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
        local sanitized=$(echo "$project_root" | sed 's/[^a-zA-Z0-9._-]/-/g' | sed 's/--*/-/g')
        local cache_base="${XDG_CACHE_HOME:-$HOME/.cache}"
        local cache_dir="$cache_base/humanize/$sanitized/skill-$unique_id"
        [[ -d "$cache_dir" ]] && echo "$cache_dir" || echo ""
    }

    # Find the best file to monitor for a skill invocation
    # Searches both global cache (~/.cache/humanize/), local cache ($dir/cache/),
    # and project-local files (.humanize/skill/) for the best content.
    _skill_find_monitored_file() {
        local dir="$1"
        local gcache=$(_skill_find_cache_dir "$dir")
        local lcache="$dir/cache"
        local is_running=false
        [[ ! -f "$dir/metadata.md" ]] && is_running=true

        # Helper: check a cache directory for best file
        # Args: cache_dir, prefer_log (true for running, false for completed)
        _check_cache_files() {
            local c="$1" prefer_log="$2"
            [[ ! -d "$c" ]] && return
            if [[ "$prefer_log" == "true" ]]; then
                [[ -f "$c/codex-run.log" && -s "$c/codex-run.log" ]] && { echo "$c/codex-run.log"; return; }
                [[ -f "$c/codex-run.out" && -s "$c/codex-run.out" ]] && { echo "$c/codex-run.out"; return; }
                [[ -f "$c/codex-run.log" ]] && { echo "$c/codex-run.log"; return; }
            else
                [[ -f "$c/codex-run.out" && -s "$c/codex-run.out" ]] && { echo "$c/codex-run.out"; return; }
                [[ -f "$c/codex-run.log" && -s "$c/codex-run.log" ]] && { echo "$c/codex-run.log"; return; }
            fi
        }

        if [[ "$is_running" == "true" ]]; then
            # Running: prefer cache logs (stderr has live progress)
            local f
            f=$(_check_cache_files "$gcache" true); [[ -n "$f" ]] && { echo "$f"; return; }
            f=$(_check_cache_files "$lcache" true); [[ -n "$f" ]] && { echo "$f"; return; }
            [[ -f "$dir/input.md" ]] && { echo "$dir/input.md"; return; }
        else
            # Completed: prefer output.md with content, then cache files
            [[ -f "$dir/output.md" && -s "$dir/output.md" ]] && { echo "$dir/output.md"; return; }
            local f
            f=$(_check_cache_files "$gcache" false); [[ -n "$f" ]] && { echo "$f"; return; }
            f=$(_check_cache_files "$lcache" false); [[ -n "$f" ]] && { echo "$f"; return; }
            [[ -f "$dir/output.md" ]] && { echo "$dir/output.md"; return; }
        fi
        echo ""
    }

    # Draw the status bar at the top
    _skill_draw_status_bar() {
        local latest_dir="$1"
        local monitored_file="$2"
        local term_width=$(tput cols)

        # ANSI colors
        local green="\033[1;32m" yellow="\033[1;33m" cyan="\033[1;36m"
        local magenta="\033[1;35m" red="\033[1;31m" reset="\033[0m"
        local bg="\033[44m" bold="\033[1m" dim="\033[2m"
        local clr_eol="\033[K"

        # Aggregate stats
        local -a stats
        humanize_split_to_array stats "$(_skill_count_stats)"
        local total="${stats[0]}" success="${stats[1]}" err="${stats[2]}"
        local tmo="${stats[3]}" empty="${stats[4]}" running="${stats[5]}"

        # Parse latest invocation metadata
        local inv_status="running" model="N/A" effort="N/A" duration="N/A" started_at="N/A"
        if [[ -n "$latest_dir" && -f "$latest_dir/metadata.md" ]]; then
            inv_status=$(monitor_get_yaml_value "status" "$latest_dir/metadata.md")
            model=$(monitor_get_yaml_value "model" "$latest_dir/metadata.md")
            effort=$(monitor_get_yaml_value "effort" "$latest_dir/metadata.md")
            duration=$(monitor_get_yaml_value "duration" "$latest_dir/metadata.md")
            started_at=$(monitor_get_yaml_value "started_at" "$latest_dir/metadata.md")
        elif [[ -n "$latest_dir" && -f "$latest_dir/input.md" ]]; then
            model=$(grep -E '^- Model:' "$latest_dir/input.md" 2>/dev/null | sed 's/- Model: //')
            effort=$(grep -E '^- Effort:' "$latest_dir/input.md" 2>/dev/null | sed 's/- Effort: //')
        fi
        inv_status="${inv_status:-unknown}"; model="${model:-N/A}"; effort="${effort:-N/A}"

        # Status color
        local status_color="$dim"
        case "$inv_status" in
            success) status_color="$green" ;;
            error|timeout) status_color="$red" ;;
            empty_response) status_color="$yellow" ;;
            running) status_color="$yellow" ;;
        esac

        # Question (truncated)
        local question="N/A"
        [[ -n "$latest_dir" ]] && question=$(_skill_get_question "$latest_dir")
        local max_q_len=$((term_width - 14))
        [[ ${#question} -gt $max_q_len ]] && question="${question:0:$((max_q_len - 3))}..."

        # Format timestamps
        local start_display=$(monitor_format_timestamp "$started_at")

        # Resolve cache directory for display
        local cache_dir=""
        [[ -n "$latest_dir" ]] && cache_dir=$(_skill_find_cache_dir "$latest_dir")

        # Truncate paths for display
        local max_path_len=$((term_width - 14))

        local file_display="${monitored_file:-none}"
        if [[ ${#file_display} -gt $max_path_len ]]; then
            local suffix_len=$((max_path_len - 3))
            file_display="...${file_display: -$suffix_len}"
        fi

        local cache_display="${cache_dir:-not found}"
        if [[ ${#cache_display} -gt $max_path_len ]]; then
            local csuffix_len=$((max_path_len - 3))
            cache_display="...${cache_display: -$csuffix_len}"
        fi

        tput sc
        tput cup 0 0

        # Line 1: Title
        printf "${bg}${bold}%-${term_width}s${reset}${clr_eol}\n" " Humanize Skill Monitor"
        # Line 2: Aggregate stats
        printf "${cyan}Total:${reset}    ${bold}${total}${reset} invocations"
        [[ "$success" -gt 0 ]] && printf " | ${green}${success} success${reset}"
        [[ "$err" -gt 0 ]] && printf " | ${red}${err} error${reset}"
        [[ "$tmo" -gt 0 ]] && printf " | ${red}${tmo} timeout${reset}"
        [[ "$empty" -gt 0 ]] && printf " | ${yellow}${empty} empty${reset}"
        [[ "$running" -gt 0 ]] && printf " | ${yellow}${running} running${reset}"
        printf "${clr_eol}\n"
        # Line 3: Focused invocation status + model + duration
        printf "${magenta}Focused:${reset}  ${status_color}${inv_status}${reset} | ${yellow}Model:${reset} ${model} (${effort}) | ${cyan}Duration:${reset} ${duration:-N/A}${clr_eol}\n"
        # Line 4: Started at
        printf "${cyan}Started:${reset}  ${start_display}${clr_eol}\n"
        # Line 5: Question
        printf "${cyan}Question:${reset} ${question}${clr_eol}\n"
        # Line 6: Cache directory
        printf "${dim}Cache:${reset}    ${cache_display}${clr_eol}\n"
        # Line 7: Watching file
        printf "${dim}Watching:${reset} ${file_display}${clr_eol}\n"
        # Line 8: Separator
        printf "%.s-" $(seq 1 $term_width)
        printf "${clr_eol}\n"

        tput rc
    }

    # --once mode: print summary and exit
    if [[ "$once_mode" == "true" ]]; then
        local latest=$(_skill_find_latest_dir)
        if [[ -z "$latest" ]]; then
            echo "No skill invocations found in $skill_dir"
            return 1
        fi

        # Find best invocation with content
        local best_result=$(_skill_find_best_invocation)
        local best_dir="${best_result%%|*}"
        local best_file="${best_result#*|}"
        # Use best_dir for display (it has content); fall back to latest
        local focus_dir="${best_dir:-$latest}"

        local -a stats
        humanize_split_to_array stats "$(_skill_count_stats)"
        local inv_status="running" model="N/A" effort="N/A" duration="N/A" started_at="N/A"
        if [[ -f "$focus_dir/metadata.md" ]]; then
            inv_status=$(monitor_get_yaml_value "status" "$focus_dir/metadata.md")
            model=$(monitor_get_yaml_value "model" "$focus_dir/metadata.md")
            effort=$(monitor_get_yaml_value "effort" "$focus_dir/metadata.md")
            duration=$(monitor_get_yaml_value "duration" "$focus_dir/metadata.md")
            started_at=$(monitor_get_yaml_value "started_at" "$focus_dir/metadata.md")
        fi
        local question=$(_skill_get_question "$focus_dir")
        local cache_dir=$(_skill_find_cache_dir "$focus_dir")

        echo "=========================================="
        echo " Humanize Skill Monitor"
        echo "=========================================="
        echo ""
        echo "Total Invocations: ${stats[0]}"
        echo "  Success: ${stats[1]}  Error: ${stats[2]}  Timeout: ${stats[3]}  Empty: ${stats[4]}  Running: ${stats[5]}"
        echo ""
        echo "Focused: $(basename "$focus_dir")"
        echo "  Status:   ${inv_status:-unknown}"
        echo "  Model:    ${model:-N/A} (${effort:-N/A})"
        echo "  Duration: ${duration:-N/A}"
        echo "  Started:  ${started_at:-N/A}"
        echo "  Question: $question"
        echo "  Cache:    ${cache_dir:-not found}"
        echo "  Watching: ${best_file:-none}"
        echo ""
        echo "=========================================="
        echo " Watched Output"
        echo "=========================================="
        echo ""
        if [[ -n "$best_file" && -s "$best_file" ]]; then
            cat "$best_file"
        elif [[ "$inv_status" == "running" ]]; then
            echo "(Still running...)"
        else
            echo "(No output available)"
        fi
        echo ""
        echo "=========================================="
        echo " Recent Invocations"
        echo "=========================================="
        echo ""
        local count=0
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            local name=$(basename "$d")
            local st="running" dur=""
            if [[ -f "$d/metadata.md" ]]; then
                st=$(monitor_get_yaml_value "status" "$d/metadata.md")
                dur=$(monitor_get_yaml_value "duration" "$d/metadata.md")
            fi
            local q=$(_skill_get_question "$d")
            [[ ${#q} -gt 50 ]] && q="${q:0:47}..."
            printf "  %-38s %-14s %-6s %s\n" "$name" "$st" "$dur" "$q"
            ((count++))
            [[ $count -ge 10 ]] && break
        done < <(_skill_list_dirs_sorted)
        echo ""
        echo "=========================================="
        return 0
    fi

    # Interactive mode: live terminal monitor
    tput smcup  # Save screen
    tput civis  # Hide cursor
    clear
    tput csr $status_bar_height $(($(tput lines) - 1))

    local monitor_running=true
    local cleanup_done=false
    local TAIL_PID=""

    # Cleanly stop the tail background process
    # Uses disown to remove from zsh job table, preventing "[N] terminated" messages
    _skill_stop_tail() {
        if [[ -n "${TAIL_PID:-}" ]]; then
            disown "$TAIL_PID" 2>/dev/null || true
            kill "$TAIL_PID" 2>/dev/null || true
            wait "$TAIL_PID" 2>/dev/null || true
            TAIL_PID=""
        fi
    }

    _skill_cleanup() {
        [[ "${cleanup_done:-false}" == "true" ]] && return
        cleanup_done=true
        monitor_running=false
        trap - INT TERM EXIT 2>/dev/null || true
        _skill_stop_tail
        # Reset scroll region before restoring screen
        printf '\033[r' 2>/dev/null || true
        tput cnorm 2>/dev/null || true
        tput rmcup 2>/dev/null || true
        echo ""
        echo "Monitor stopped."
    }

    # Signal handlers (bash/zsh compatible)
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        TRAPINT() { _skill_cleanup; return 130; }
        TRAPTERM() { _skill_cleanup; return 143; }
        trap '_skill_cleanup' EXIT
    else
        trap '_skill_cleanup' EXIT INT TERM
    fi

    # Main monitoring loop
    while [[ "$monitor_running" == "true" ]]; do
        # Check if skill directory still exists
        if [[ ! -d "$skill_dir" ]]; then
            _skill_cleanup
            echo "Skill directory deleted."
            return 0
        fi

        # Find best invocation with watchable content
        local best_result=$(_skill_find_best_invocation)
        local focus_dir="${best_result%%|*}"
        local monitored_file="${best_result#*|}"

        if [[ -z "$focus_dir" ]]; then
            tput cup $status_bar_height 0
            echo "Waiting for skill invocations..."
            sleep "$check_interval"
            continue
        fi

        # Detect if the focused invocation changed
        if [[ "$focus_dir" != "$current_skill_dir" ]]; then
            current_skill_dir="$focus_dir"
            current_file=""
            _skill_stop_tail
        fi

        # Draw status bar
        _skill_draw_status_bar "$focus_dir" "$monitored_file"

        # Switch to new file if the monitored file changed
        if [[ "$monitored_file" != "$current_file" ]] && [[ -n "$monitored_file" ]]; then
            current_file="$monitored_file"
            _skill_stop_tail
            tput cup $status_bar_height 0
            tput ed
            tail -n +1 -f "$current_file" 2>/dev/null &
            TAIL_PID=$!
        fi

        if [[ -z "$current_file" ]]; then
            tput cup $status_bar_height 0
            echo "Waiting for skill output..."
        fi

        sleep "$check_interval"
    done

    # Reset trap handlers
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        unfunction TRAPINT TRAPTERM 2>/dev/null || true
    else
        trap - INT TERM EXIT
    fi
}
