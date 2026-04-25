#!/usr/bin/env bash
#
# DISCLAIMER
# ----------
# Author: Sihao Liu
#
# This is a status line script for the CLI tool that happens to include
# an RLCR status field tied to the Humanize plugin. It is included in
# this repository solely for community sharing purposes.
#
# Provided AS-IS -- it serves as a reference and template only.
# Only the final field (RLCR) is related to this repository; the rest
# is generic session information. Future updates to the Humanize plugin
# will generally not involve changes to this script.
#
# Claude Code Status Line - Display usage information
# Format: <model> | [context bar] | $X.XX @ Xh:Ym:Zs

input=$(cat)

# Extract values using jq
get_value() {
    echo "$input" | jq -r "$1 // empty" 2>/dev/null
}

# Format milliseconds as Xh:Ym:Zs
format_duration() {
    local ms=$1
    local total_sec=$((ms / 1000))
    local hours=$((total_sec / 3600))
    local mins=$(((total_sec % 3600) / 60))
    local secs=$((total_sec % 60))
    printf "%dh:%dm:%ds" "$hours" "$mins" "$secs"
}

# Determine RLCR display status for a session directory
_resolve_rlcr_display() {
    local session_dir="$1"

    if [[ -f "$session_dir/methodology-analysis-state.md" ]]; then
        echo "Analyzing"
    elif [[ -f "$session_dir/finalize-state.md" ]]; then
        echo "Finalizing"
    elif [[ -f "$session_dir/state.md" ]]; then
        echo "Active"
    else
        local terminal_file
        terminal_file=$(ls -1 "$session_dir"/*-state.md 2>/dev/null | head -1)
        if [[ -n "$terminal_file" ]]; then
            local bname
            bname=$(basename "$terminal_file")
            local reason="${bname%-state.md}"
            # Capitalize first letter (Bash 3 compatible)
            local first_char
            first_char=$(printf '%s' "$reason" | cut -c1 | tr '[:lower:]' '[:upper:]')
            local rest
            rest=$(printf '%s' "$reason" | cut -c2-)
            echo "${first_char}${rest}"
        else
            echo "Off"
        fi
    fi
}

# Get RLCR loop status for the current session
# Mirrors find_active_loop() logic from humanize hooks/lib/loop-common.sh
get_rlcr_status() {
    local rlcr_dir="$1"
    local filter_session_id="$2"

    if [[ ! -d "$rlcr_dir" ]]; then
        echo "Off"
        return
    fi

    # Pre-scan: if any state files have a session_id, ignore those without
    local has_sid_aware=false
    if grep -rqE '^session_id: *.+' "$rlcr_dir"/*/*.md 2>/dev/null; then
        has_sid_aware=true
    fi

    if [[ -z "$filter_session_id" ]]; then
        if ! $has_sid_aware; then
            # No session-aware files: check the newest directory only (zombie-loop protection)
            local newest_dir
            newest_dir=$(ls -1d "$rlcr_dir"/*/ 2>/dev/null | sort -r | head -1)
            if [[ -z "$newest_dir" ]]; then
                echo "Off"
                return
            fi
            _resolve_rlcr_display "${newest_dir%/}"
            return
        fi
        # Session-aware files exist: find newest session-aware directory
        local dir
        while IFS= read -r dir; do
            [[ -z "$dir" ]] && continue
            local trimmed="${dir%/}"
            local any_state=""
            if [[ -f "$trimmed/methodology-analysis-state.md" ]]; then
                any_state="$trimmed/methodology-analysis-state.md"
            elif [[ -f "$trimmed/finalize-state.md" ]]; then
                any_state="$trimmed/finalize-state.md"
            elif [[ -f "$trimmed/state.md" ]]; then
                any_state="$trimmed/state.md"
            else
                any_state=$(ls -1 "$trimmed"/*-state.md 2>/dev/null | head -1)
            fi
            [[ -z "$any_state" ]] && continue
            local stored_sid
            stored_sid=$(awk '/^---$/{n++; next} n==1 && /^session_id:/{sub(/^session_id: */, ""); gsub(/ /, ""); print; exit}' "$any_state" 2>/dev/null)
            if [[ -n "$stored_sid" ]]; then
                _resolve_rlcr_display "$trimmed"
                return
            fi
        done < <(ls -1d "$rlcr_dir"/*/ 2>/dev/null | sort -r)
        echo "Off"
        return
    fi

    # With session_id: iterate newest-to-oldest, find matching session
    local dir
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        local trimmed="${dir%/}"

        # Find any state file (active or terminal)
        local any_state=""
        if [[ -f "$trimmed/finalize-state.md" ]]; then
            any_state="$trimmed/finalize-state.md"
        elif [[ -f "$trimmed/state.md" ]]; then
            any_state="$trimmed/state.md"
        else
            any_state=$(ls -1 "$trimmed"/*-state.md 2>/dev/null | head -1)
        fi
        [[ -z "$any_state" ]] && continue

        # Extract stored session_id from YAML frontmatter
        local stored_sid
        stored_sid=$(awk '/^---$/{n++; next} n==1 && /^session_id:/{sub(/^session_id: */, ""); gsub(/ /, ""); print; exit}' "$any_state" 2>/dev/null)

        # Skip session-unaware entries when session-aware ones exist
        if [[ -z "$stored_sid" ]]; then
            $has_sid_aware && continue
            _resolve_rlcr_display "$trimmed"
            return
        fi
        if [[ "$stored_sid" == "$filter_session_id" ]]; then
            _resolve_rlcr_display "$trimmed"
            return
        fi
    done < <(ls -1d "$rlcr_dir"/*/ 2>/dev/null | sort -r)

    echo "Off"
}

# Get color for RLCR status
get_rlcr_color() {
    case "$1" in
        Active|Finalizing) echo "\e[32m" ;;
        Complete) echo "\e[36m" ;;
        Cancel|Stop|Pause) echo "\e[33m" ;;
        Maxiter|Failed|Timeout) echo "\e[31m" ;;
        Off) echo "\e[2m" ;;
        *) echo "\e[33m" ;;
    esac
}

# Get all raw values
MODEL=$(get_value '.model.display_name')
CWD=$(get_value '.cwd')
SESSION_ID=$(get_value '.session_id')
TRANSCRIPT_PATH=$(get_value '.transcript_path')

# Resolve session display name (customTitle from /rename, or full session_id)
# Primary source: transcript jsonl (has custom-title events even during active session)
# Fallback: sessions-index.json (may not have active session yet)
get_session_display() {
    local sid="$1"
    local transcript="$2"
    local cwd="$3"
    [[ -z "$sid" ]] && return

    # Resolve project dir name for file lookups
    local proj_dir_name
    proj_dir_name=$(echo "$cwd" | sed 's|[/.]|-|g')

    # If transcript_path not provided, construct from project dir and session_id
    if [[ -z "$transcript" || ! -f "$transcript" ]]; then
        transcript="$HOME/.claude/projects/${proj_dir_name}/${sid}.jsonl"
    fi

    # Try transcript jsonl first (grep is faster than jq for large files)
    if [[ -f "$transcript" ]]; then
        local title
        title=$(grep '"type":"custom-title"' "$transcript" 2>/dev/null | tail -1 | jq -r '.customTitle // empty' 2>/dev/null)
        if [[ -n "$title" ]]; then
            echo "$title"
            return
        fi
    fi

    # Fallback: sessions-index.json (for resumed sessions where transcript may differ)
    local idx_file="$HOME/.claude/projects/${proj_dir_name}/sessions-index.json"
    if [[ -f "$idx_file" ]]; then
        local title
        title=$(jq -r --arg sid "$sid" \
            '(.entries[] | select(.sessionId == $sid) | .customTitle) // empty' \
            "$idx_file" 2>/dev/null)
        if [[ -n "$title" ]]; then
            echo "$title"
            return
        fi
    fi

    # Fallback: full session_id
    echo "$sid"
}

# Get fast mode status from user settings
get_fast_mode() {
    local settings="$HOME/.claude/settings.json"
    if [[ -f "$settings" ]]; then
        local val
        val=$(jq -r '.fastMode // false' "$settings" 2>/dev/null)
        if [[ "$val" == "true" ]]; then
            echo "On"
            return
        fi
    fi
    echo "Off"
}

SESSION_DISPLAY=$(get_session_display "$SESSION_ID" "$TRANSCRIPT_PATH" "$CWD")
FAST_MODE=$(get_fast_mode)

# Get git branch name for CWD
if [[ -n "$CWD" && -d "$CWD" ]]; then
    BRANCH=$(git -C "$CWD" branch --show-current 2>/dev/null)
fi
BRANCH=${BRANCH:-"?"}
COST=$(get_value '.cost.total_cost_usd')
DURATION=$(get_value '.cost.total_duration_ms')
LINES_ADDED=$(get_value '.cost.total_lines_added')
LINES_REMOVED=$(get_value '.cost.total_lines_removed')

# Format cost (2 decimal places)
COST_STR=$(printf "%.2f" "${COST:-0}")

# Format duration as h:m:s
DURATION_STR=$(format_duration "${DURATION:-0}")

# Default values if null/empty
LINES_ADDED=${LINES_ADDED:-0}
LINES_REMOVED=${LINES_REMOVED:-0}

# Determine RLCR status
if [[ -n "$CWD" && -d "$CWD/.humanize" ]]; then
    RLCR_STATUS=$(get_rlcr_status "$CWD/.humanize/rlcr" "$SESSION_ID")
else
    RLCR_STATUS="Off"
fi
RLCR_COLOR=$(get_rlcr_color "$RLCR_STATUS")

# Get color for fast mode status
get_fast_color() {
    case "$1" in
        On) echo "\e[33m" ;;   # Yellow - attention, it's expensive
        Off) echo "\e[2m" ;;   # Dim
    esac
}

FAST_COLOR=$(get_fast_color "$FAST_MODE")

# Build context usage progress bar
# Format: [###60%###|  40%   ]
# Color: remaining >70% green, 30-70% yellow, <30% red
build_context_bar() {
    local used_pct=${1:-0}
    local remaining_pct=$((100 - used_pct))
    local bar_width=20

    # Color for remaining portion based on remaining percentage
    local remain_color
    if [[ $remaining_pct -gt 70 ]]; then
        remain_color="\e[32m"    # Green
    elif [[ $remaining_pct -ge 30 ]]; then
        remain_color="\e[33m"    # Yellow
    else
        remain_color="\e[31m"    # Red
    fi

    # Used portion: white background + black foreground
    local used_style="\e[47;30m"
    local reset="\e[0m"

    local used_width=$(( (used_pct * bar_width + 50) / 100 ))
    local remain_width=$(( bar_width - used_width ))

    # Build used portion: spaces with white bg, percentage label centered
    local used_label="${used_pct}%"
    local used_str=""
    local i
    for (( i = 0; i < used_width; i++ )); do
        used_str+=" "
    done
    if [[ $used_width -ge ${#used_label} ]]; then
        local offset=$(( (used_width - ${#used_label}) / 2 ))
        used_str="${used_str:0:offset}${used_label}${used_str:offset+${#used_label}}"
    fi

    # Build remaining portion: spaces, percentage label centered
    local remain_label="${remaining_pct}%"
    local remain_str=""
    for (( i = 0; i < remain_width; i++ )); do
        remain_str+=" "
    done
    if [[ $remain_width -ge ${#remain_label} ]]; then
        local offset=$(( (remain_width - ${#remain_label}) / 2 ))
        remain_str="${remain_str:0:offset}${remain_label}${remain_str:offset+${#remain_label}}"
    fi

    printf "[%b%s%b|%b%s%b]" "$used_style" "$used_str" "$reset" "$remain_color" "$remain_str" "$reset"
}

CONTEXT_USED=$(get_value '.context_window.used_percentage')
CONTEXT_USED=${CONTEXT_USED:-0}
# Round to integer
CONTEXT_USED=$(printf "%.0f" "$CONTEXT_USED")
CONTEXT_BAR=$(build_context_bar "$CONTEXT_USED")

# Define colors
CORAL="\e[38;5;173m"      # Claude branding - for MODEL
CYAN="\e[36m"             # Info - for CWD
YELLOW="\e[33m"           # for BRANCH
GREEN="\e[32m"            # Positive - for COST and LINES_ADDED
RED="\e[31m"              # Negative - for LINES_REMOVED
BLUE="\e[34m"             # Label - for Session
MAGENTA="\e[35m"          # Label - for RLCR and Fast
RESET="\e[0m"

# Shorten CWD: replace $HOME with ~
TILDE='~'
CWD_SHORT="${CWD/#$HOME/$TILDE}"

# Strip ANSI escape sequences to get visible text length
strip_ansi() {
    printf '%b' "$1" | sed 's/\x1b\[[0-9;]*m//g'
}

# Build individual fields: colored (F) and plain-text (P) pairs
F1=$(printf "%b%s%b" "$CORAL" "${MODEL:-?}" "$RESET")
P1="${MODEL:-?}"

F2="$CONTEXT_BAR"
P2=$(strip_ansi "$CONTEXT_BAR")

F3=$(printf "%b\$%s%b @ %s" "$GREEN" "$COST_STR" "$RESET" "$DURATION_STR")
P3=$(printf "\$%s @ %s" "$COST_STR" "$DURATION_STR")

F4=$(printf "%b%s%b [%b%s%b]" "$CYAN" "${CWD_SHORT:-?}" "$RESET" "$YELLOW" "$BRANCH" "$RESET")
P4=$(printf "%s [%s]" "${CWD_SHORT:-?}" "$BRANCH")

F5=$(printf "lines: %b+%s%b, %b-%s%b" "$GREEN" "$LINES_ADDED" "$RESET" "$RED" "$LINES_REMOVED" "$RESET")
P5=$(printf "lines: +%s, -%s" "$LINES_ADDED" "$LINES_REMOVED")

F6=$(printf "%bSession:%b %b%s%b" "$MAGENTA" "$RESET" "$CYAN" "${SESSION_DISPLAY:-?}" "$RESET")
P6=$(printf "Session: %s" "${SESSION_DISPLAY:-?}")

F7=$(printf "%bFast:%b %b%s%b" "$MAGENTA" "$RESET" "$FAST_COLOR" "$FAST_MODE" "$RESET")
P7=$(printf "Fast: %s" "$FAST_MODE")

F8=$(printf "%bRLCR:%b %b%s%b" "$MAGENTA" "$RESET" "$RLCR_COLOR" "$RLCR_STATUS" "$RESET")
P8=$(printf "RLCR: %s" "$RLCR_STATUS")

FIELDS=("$F1" "$F2" "$F3" "$F4" "$F5" "$F6" "$F7" "$F8")
PLAINS=("$P1" "$P2" "$P3" "$P4" "$P5" "$P6" "$P7" "$P8")

# Get terminal width via /dev/tty (stdin is piped, so tput/stty need the real TTY)
TERM_WIDTH=$(stty size < /dev/tty 2>/dev/null | awk '{print $2}')
TERM_WIDTH=${TERM_WIDTH:-$(tput cols 2>/dev/tty || echo 80)}
MAX_WIDTH=$(( TERM_WIDTH * 75 / 100 ))

# Greedily pack fields into lines, wrapping when adding a field exceeds MAX_WIDTH
SEPARATOR=" | "
SEP_WIDTH=${#SEPARATOR}
cur_line=""
cur_plain=""

for i in "${!FIELDS[@]}"; do
    if [[ -z "$cur_line" ]]; then
        cur_line="${FIELDS[$i]}"
        cur_plain="${PLAINS[$i]}"
    elif [[ $(( ${#cur_plain} + SEP_WIDTH + ${#PLAINS[$i]} )) -le $MAX_WIDTH ]]; then
        cur_line="${cur_line}${SEPARATOR}${FIELDS[$i]}"
        cur_plain="${cur_plain}${SEPARATOR}${PLAINS[$i]}"
    else
        printf "%s\n" "$cur_line"
        cur_line="${FIELDS[$i]}"
        cur_plain="${PLAINS[$i]}"
    fi
done
[[ -n "$cur_line" ]] && printf "%s\n" "$cur_line"
