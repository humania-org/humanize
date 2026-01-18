#!/bin/bash
#
# Stop Hook for PR loop
#
# Intercepts Claude's exit attempts, polls for remote bot reviews,
# and uses local Codex to validate if bot concerns are addressed.
#
# Key features:
# - Polls until ALL active bots respond (per-bot tracking with 15min timeout each)
# - Checks PR state before polling (detects CLOSED/MERGED)
# - Uses APPROVE marker per AC-8
# - Updates active_bots list based on per-bot approval
#
# State directory: .humanize/pr-loop/<timestamp>/
# State file: state.md (current_round, pr_number, active_bots as YAML list, etc.)
# Resolve file: round-N-pr-resolve.md (Claude's resolution summary)
# Comment file: round-N-pr-comment.md (Fetched PR comments)
# Check file: round-N-pr-check.md (Local Codex validation)
# Feedback file: round-N-pr-feedback.md (Feedback for next round)
#

set -euo pipefail

# ========================================
# Default Configuration
# ========================================

DEFAULT_CODEX_MODEL="gpt-5.2-codex"
DEFAULT_CODEX_EFFORT="medium"
DEFAULT_CODEX_TIMEOUT=900
DEFAULT_POLL_INTERVAL=30
DEFAULT_POLL_TIMEOUT=900  # 15 minutes per bot

# ========================================
# Bot Name Mapping
# ========================================

# Map bot names to GitHub comment author names:
# - claude -> claude[bot]
# - codex -> chatgpt-codex-connector[bot]
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
map_author_to_bot() {
    local author="$1"
    # Remove [bot] suffix if present
    local author_clean="${author%\[bot\]}"
    case "$author_clean" in
        chatgpt-codex-connector) echo "codex" ;;
        *) echo "$author_clean" ;;
    esac
}

# ========================================
# Read Hook Input
# ========================================

HOOK_INPUT=$(cat)

# ========================================
# Find Active Loop
# ========================================

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
LOOP_BASE_DIR="$PROJECT_ROOT/.humanize/pr-loop"

# Source shared loop functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib/loop-common.sh"

# Source portable timeout wrapper
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PLUGIN_ROOT/scripts/portable-timeout.sh"

# Default timeout for git/gh operations
GIT_TIMEOUT=30
GH_TIMEOUT=60

# Find newest PR loop directory with state.md
find_pr_loop_dir() {
    local base_dir="$1"
    if [[ ! -d "$base_dir" ]]; then
        echo ""
        return
    fi
    local newest_dir
    newest_dir=$(ls -1d "$base_dir"/*/ 2>/dev/null | sort -r | head -1)
    if [[ -n "$newest_dir" && -f "${newest_dir}state.md" ]]; then
        echo "${newest_dir%/}"
    else
        echo ""
    fi
}

LOOP_DIR=$(find_pr_loop_dir "$LOOP_BASE_DIR")

# If no active PR loop, let other hooks handle
if [[ -z "$LOOP_DIR" ]]; then
    exit 0
fi

STATE_FILE="$LOOP_DIR/state.md"

if [[ ! -f "$STATE_FILE" ]]; then
    exit 0
fi

# ========================================
# Parse State File (YAML list format for active_bots)
# ========================================

parse_pr_loop_state() {
    local state_file="$1"

    STATE_FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$state_file" 2>/dev/null || echo "")

    PR_CURRENT_ROUND=$(echo "$STATE_FRONTMATTER" | grep "^current_round:" | sed "s/current_round: *//" | tr -d ' ' || true)
    PR_MAX_ITERATIONS=$(echo "$STATE_FRONTMATTER" | grep "^max_iterations:" | sed "s/max_iterations: *//" | tr -d ' ' || true)
    PR_NUMBER=$(echo "$STATE_FRONTMATTER" | grep "^pr_number:" | sed "s/pr_number: *//" | tr -d ' ' || true)
    PR_START_BRANCH=$(echo "$STATE_FRONTMATTER" | grep "^start_branch:" | sed "s/start_branch: *//; s/^\"//; s/\"\$//" || true)
    PR_CODEX_MODEL=$(echo "$STATE_FRONTMATTER" | grep "^codex_model:" | sed "s/codex_model: *//" | tr -d ' ' || true)
    PR_CODEX_EFFORT=$(echo "$STATE_FRONTMATTER" | grep "^codex_effort:" | sed "s/codex_effort: *//" | tr -d ' ' || true)
    PR_CODEX_TIMEOUT=$(echo "$STATE_FRONTMATTER" | grep "^codex_timeout:" | sed "s/codex_timeout: *//" | tr -d ' ' || true)
    PR_POLL_INTERVAL=$(echo "$STATE_FRONTMATTER" | grep "^poll_interval:" | sed "s/poll_interval: *//" | tr -d ' ' || true)
    PR_POLL_TIMEOUT=$(echo "$STATE_FRONTMATTER" | grep "^poll_timeout:" | sed "s/poll_timeout: *//" | tr -d ' ' || true)
    PR_STARTED_AT=$(echo "$STATE_FRONTMATTER" | grep "^started_at:" | sed "s/started_at: *//" || true)
    PR_LAST_TRIGGER_AT=$(echo "$STATE_FRONTMATTER" | grep "^last_trigger_at:" | sed "s/last_trigger_at: *//" || true)

    # Parse configured_bots and active_bots as YAML lists
    # configured_bots: never changes, used for polling all bots (allows re-add)
    # active_bots: current bots with issues, shrinks as bots approve
    declare -g -a PR_CONFIGURED_BOTS_ARRAY=()
    declare -g -a PR_ACTIVE_BOTS_ARRAY=()

    # Parse YAML list helper function
    parse_yaml_list() {
        local field_name="$1"
        local -n result_array="$2"
        local in_field=false

        while IFS= read -r line; do
            if [[ "$line" =~ ^${field_name}: ]]; then
                in_field=true
                # Check if it's inline format: field: value
                local inline_value="${line#*: }"
                if [[ -n "$inline_value" && "$inline_value" != "${field_name}:" ]]; then
                    # Old comma-separated format for backwards compatibility
                    IFS=',' read -ra result_array <<< "$inline_value"
                    in_field=false
                fi
                continue
            fi
            if [[ "$in_field" == "true" ]]; then
                if [[ "$line" =~ ^[[:space:]]+-[[:space:]]+ ]]; then
                    # Extract bot name from "  - botname"
                    local bot_name="${line#*- }"
                    bot_name=$(echo "$bot_name" | tr -d ' ')
                    if [[ -n "$bot_name" ]]; then
                        result_array+=("$bot_name")
                    fi
                elif [[ "$line" =~ ^[a-zA-Z_] ]]; then
                    # New field started, stop parsing
                    in_field=false
                fi
            fi
        done <<< "$STATE_FRONTMATTER"
    }

    parse_yaml_list "configured_bots" PR_CONFIGURED_BOTS_ARRAY
    parse_yaml_list "active_bots" PR_ACTIVE_BOTS_ARRAY

    # Backwards compatibility: if configured_bots is empty, use active_bots
    if [[ ${#PR_CONFIGURED_BOTS_ARRAY[@]} -eq 0 ]]; then
        PR_CONFIGURED_BOTS_ARRAY=("${PR_ACTIVE_BOTS_ARRAY[@]}")
    fi

    # Apply defaults
    PR_CURRENT_ROUND="${PR_CURRENT_ROUND:-0}"
    PR_MAX_ITERATIONS="${PR_MAX_ITERATIONS:-42}"
    PR_CODEX_MODEL="${PR_CODEX_MODEL:-$DEFAULT_CODEX_MODEL}"
    PR_CODEX_EFFORT="${PR_CODEX_EFFORT:-$DEFAULT_CODEX_EFFORT}"
    PR_CODEX_TIMEOUT="${PR_CODEX_TIMEOUT:-$DEFAULT_CODEX_TIMEOUT}"
    PR_POLL_INTERVAL="${PR_POLL_INTERVAL:-$DEFAULT_POLL_INTERVAL}"
    PR_POLL_TIMEOUT="${PR_POLL_TIMEOUT:-$DEFAULT_POLL_TIMEOUT}"
}

parse_pr_loop_state "$STATE_FILE"

# Build display string and mention string from active bots array
PR_ACTIVE_BOTS_DISPLAY=$(IFS=', '; echo "${PR_ACTIVE_BOTS_ARRAY[*]}")
PR_CONFIGURED_BOTS_DISPLAY=$(IFS=', '; echo "${PR_CONFIGURED_BOTS_ARRAY[*]}")

# Build mention string from configured bots (for detecting trigger comments)
PR_BOT_MENTION_STRING=""
for bot in "${PR_CONFIGURED_BOTS_ARRAY[@]}"; do
    if [[ -n "$PR_BOT_MENTION_STRING" ]]; then
        PR_BOT_MENTION_STRING="${PR_BOT_MENTION_STRING} @${bot}"
    else
        PR_BOT_MENTION_STRING="@${bot}"
    fi
done

# Validate required fields
if [[ -z "$PR_NUMBER" ]]; then
    echo "Error: PR number not found in state file" >&2
    exit 0
fi

if [[ ! "$PR_CURRENT_ROUND" =~ ^[0-9]+$ ]]; then
    echo "Warning: Invalid current_round in state file" >&2
    exit 0
fi

# ========================================
# Check PR State (detect CLOSED/MERGED before polling)
# ========================================

PR_STATE=$(run_with_timeout "$GH_TIMEOUT" gh pr view "$PR_NUMBER" --json state -q .state 2>/dev/null) || PR_STATE=""

if [[ "$PR_STATE" == "MERGED" ]]; then
    echo "PR #$PR_NUMBER has been merged. Marking loop as complete." >&2
    mv "$STATE_FILE" "$LOOP_DIR/merged-state.md"
    exit 0
fi

if [[ "$PR_STATE" == "CLOSED" ]]; then
    echo "PR #$PR_NUMBER has been closed. Marking loop as closed." >&2
    mv "$STATE_FILE" "$LOOP_DIR/closed-state.md"
    exit 0
fi

# ========================================
# Check Resolution File Exists
# ========================================

RESOLVE_FILE="$LOOP_DIR/round-${PR_CURRENT_ROUND}-pr-resolve.md"

if [[ ! -f "$RESOLVE_FILE" ]]; then
    REASON="# Resolution Summary Missing

Please write your resolution summary to: $RESOLVE_FILE

The summary should include:
- Issues addressed
- Files modified
- Tests added (if any)"

    jq -n --arg reason "$REASON" --arg msg "PR Loop: Resolution summary missing for round $PR_CURRENT_ROUND" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

# ========================================
# Check Git Status
# ========================================

if command -v git &>/dev/null && run_with_timeout "$GIT_TIMEOUT" git rev-parse --git-dir &>/dev/null 2>&1; then
    GIT_STATUS_CACHED=$(run_with_timeout "$GIT_TIMEOUT" git status --porcelain 2>/dev/null) || GIT_EXIT=$?
    GIT_EXIT=${GIT_EXIT:-0}

    if [[ $GIT_EXIT -ne 0 ]]; then
        REASON="# Git Status Failed

Git status operation failed. Please check your repository state and try again."
        jq -n --arg reason "$REASON" --arg msg "PR Loop: Git status failed" \
            '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
        exit 0
    fi

    # Filter out .humanize from status check
    NON_HUMANIZE_STATUS=$(echo "$GIT_STATUS_CACHED" | grep -v '\.humanize' || true)

    if [[ -n "$NON_HUMANIZE_STATUS" ]]; then
        REASON="# Git Not Clean

You have uncommitted changes. Please commit all changes before exiting.

Changes detected:
\`\`\`
$NON_HUMANIZE_STATUS
\`\`\`"
        jq -n --arg reason "$REASON" --arg msg "PR Loop: Uncommitted changes detected" \
            '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
        exit 0
    fi

    # Check for unpushed commits (PR loop always requires push)
    GIT_AHEAD=$(run_with_timeout "$GIT_TIMEOUT" git status -sb 2>/dev/null | grep -o 'ahead [0-9]*' || true)
    if [[ -n "$GIT_AHEAD" ]]; then
        AHEAD_COUNT=$(echo "$GIT_AHEAD" | grep -o '[0-9]*')
        REASON="# Unpushed Commits

You have $AHEAD_COUNT unpushed commit(s). PR loop requires pushing changes so bots can review them.

Please push your changes:
\`\`\`bash
git push
\`\`\`"
        jq -n --arg reason "$REASON" --arg msg "PR Loop: $AHEAD_COUNT unpushed commit(s)" \
            '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
        exit 0
    fi
fi

# ========================================
# Check Max Iterations
# ========================================

NEXT_ROUND=$((PR_CURRENT_ROUND + 1))

if [[ $NEXT_ROUND -gt $PR_MAX_ITERATIONS ]]; then
    echo "PR loop reached max iterations ($PR_MAX_ITERATIONS). Exiting." >&2
    mv "$STATE_FILE" "$LOOP_DIR/maxiter-state.md"
    exit 0
fi

# ========================================
# Check if Active Bots Remain
# ========================================

if [[ ${#PR_ACTIVE_BOTS_ARRAY[@]} -eq 0 ]]; then
    echo "All bots have approved. PR loop complete!" >&2
    mv "$STATE_FILE" "$LOOP_DIR/complete-state.md"
    exit 0
fi

# ========================================
# Detect Trigger Comment and Update last_trigger_at
# ========================================

# Get current GitHub user login for trigger comment filtering
get_current_user() {
    run_with_timeout "$GH_TIMEOUT" gh api user --jq '.login' 2>/dev/null || echo ""
}

# Find the most recent PR comment from CURRENT USER that contains bot mentions
# This timestamp is used for --after filtering to catch fast bot replies
# NOTE: Uses --paginate to handle PRs with >30 comments
detect_trigger_comment() {
    local pr_num="$1"
    local current_user="$2"

    # Fetch ALL issue comments on the PR (paginated to handle >30 comments)
    # Using --paginate ensures we don't miss the latest @mention on large PRs
    local comments_json
    comments_json=$(run_with_timeout "$GH_TIMEOUT" gh api "repos/{owner}/{repo}/issues/$pr_num/comments" \
        --paginate --jq '[.[] | {id: .id, author: .user.login, created_at: .created_at, body: .body}]' 2>/dev/null) || return 1

    if [[ -z "$comments_json" || "$comments_json" == "[]" ]]; then
        return 1
    fi

    # Build pattern to match any @bot mention
    local bot_pattern=""
    for bot in "${PR_CONFIGURED_BOTS_ARRAY[@]}"; do
        if [[ -n "$bot_pattern" ]]; then
            bot_pattern="${bot_pattern}|@${bot}"
        else
            bot_pattern="@${bot}"
        fi
    done

    # Find most recent trigger comment from CURRENT USER (sorted by created_at descending)
    # The jq -s combines paginated results into single array before filtering
    local trigger_timestamp
    trigger_timestamp=$(echo "$comments_json" | jq -s 'add' | jq -r --arg pattern "$bot_pattern" --arg user "$current_user" '
        [.[] | select(.author == $user and (.body | test($pattern; "i")))] |
        sort_by(.created_at) | reverse | .[0].created_at // empty
    ')

    if [[ -n "$trigger_timestamp" && "$trigger_timestamp" != "null" ]]; then
        echo "$trigger_timestamp"
        return 0
    fi

    return 1
}

# Get current user for trigger comment filtering
CURRENT_USER=$(get_current_user)
if [[ -z "$CURRENT_USER" ]]; then
    echo "Warning: Could not determine current GitHub user" >&2
fi

# ALWAYS check for newer trigger comments and update last_trigger_at
# This ensures we use the most recent trigger, not a stale one
echo "Detecting trigger comment timestamp from user '$CURRENT_USER'..." >&2
DETECTED_TRIGGER_AT=$(detect_trigger_comment "$PR_NUMBER" "$CURRENT_USER") || true

if [[ -n "$DETECTED_TRIGGER_AT" ]]; then
    # Check if detected trigger is newer than stored one
    if [[ -z "$PR_LAST_TRIGGER_AT" ]] || [[ "$DETECTED_TRIGGER_AT" > "$PR_LAST_TRIGGER_AT" ]]; then
        echo "Found trigger comment at: $DETECTED_TRIGGER_AT" >&2
        if [[ -n "$PR_LAST_TRIGGER_AT" ]]; then
            echo "  (Updating from older trigger: $PR_LAST_TRIGGER_AT)" >&2
        fi
        PR_LAST_TRIGGER_AT="$DETECTED_TRIGGER_AT"

        # Persist to state file
        TEMP_FILE="${STATE_FILE}.trigger.$$"
        sed "s/^last_trigger_at:.*/last_trigger_at: $DETECTED_TRIGGER_AT/" "$STATE_FILE" > "$TEMP_FILE"
        mv "$TEMP_FILE" "$STATE_FILE"
    else
        echo "Using existing trigger timestamp: $PR_LAST_TRIGGER_AT" >&2
    fi
fi

# ========================================
# Validate Trigger Comment Exists (Required for Rounds > 0)
# ========================================

# For round 0, we use started_at. For subsequent rounds, we REQUIRE a trigger comment.
# This prevents using stale timestamps that could include old bot comments.
if [[ "$PR_CURRENT_ROUND" -gt 0 && -z "$PR_LAST_TRIGGER_AT" ]]; then
    REASON="# Missing Trigger Comment

No @bot mention comment found from you on this PR.

Before the Stop Hook can poll for bot reviews, you must comment on the PR to trigger the bots.

**Please run:**
\`\`\`bash
gh pr comment $PR_NUMBER --body \"$PR_BOT_MENTION_STRING please review the latest changes\"
\`\`\`

Then try exiting again."

    jq -n --arg reason "$REASON" --arg msg "PR Loop: Missing trigger comment - please @mention bots first" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

# ========================================
# Poll for New Bot Reviews (per-bot tracking)
# ========================================

# Poll ALL configured bots, not just active - allows re-adding approved bots if they post new issues
echo "Polling for new bot reviews on PR #$PR_NUMBER..." >&2
echo "Configured bots: $PR_CONFIGURED_BOTS_DISPLAY" >&2
echo "Active bots: $PR_ACTIVE_BOTS_DISPLAY" >&2
echo "Poll interval: ${PR_POLL_INTERVAL}s, Timeout: ${PR_POLL_TIMEOUT}s per bot" >&2

POLL_SCRIPT="$PLUGIN_ROOT/scripts/poll-pr-reviews.sh"

# Consistent file naming: round-N files all refer to round N
COMMENT_FILE="$LOOP_DIR/round-${NEXT_ROUND}-pr-comment.md"

# Get timestamp for filtering - ALWAYS prefer last_trigger_at when available
# This ensures we use the most accurate timestamp regardless of round number
# Fallback to started_at ONLY for round 0 when no trigger comment exists yet
if [[ -n "$PR_LAST_TRIGGER_AT" ]]; then
    # Always use trigger timestamp when available (including round 0)
    AFTER_TIMESTAMP="$PR_LAST_TRIGGER_AT"
    echo "Round $PR_CURRENT_ROUND: using trigger timestamp for --after: $AFTER_TIMESTAMP" >&2
elif [[ "$PR_CURRENT_ROUND" -eq 0 ]]; then
    # Round 0 fallback: use started_at if no trigger comment detected yet
    AFTER_TIMESTAMP="${PR_STARTED_AT}"
    echo "Round 0: using started_at for --after (no trigger yet): $AFTER_TIMESTAMP" >&2
else
    # Round N>0 with no trigger - this should have been blocked earlier
    # but handle defensively by blocking here too
    REASON="# Missing Trigger Comment

No @bot mention comment found from you on this PR.

Before polling for bot reviews, you must comment on the PR to trigger the bots.

**Please run:**
\`\`\`bash
gh pr comment $PR_NUMBER --body \"$PR_BOT_MENTION_STRING please review the latest changes\"
\`\`\`

Then try exiting again."

    jq -n --arg reason "$REASON" --arg msg "PR Loop: Missing trigger comment" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

# Convert trigger timestamp to epoch for timeout anchoring
# Per-bot timeouts are measured from the TRIGGER time, not poll start time
TRIGGER_EPOCH=$(date -d "$AFTER_TIMESTAMP" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$AFTER_TIMESTAMP" +%s 2>/dev/null || date +%s)

# Track which bots have responded and their individual timeouts
# IMPORTANT: Poll ALL configured bots (not just active) so we can detect when
# previously approved bots post new issues and re-add them to active_bots
# IMPORTANT: Timeouts are anchored to TRIGGER_EPOCH, not poll start time
# This ensures the 15-minute window is measured from when the @mention was posted
declare -A BOTS_RESPONDED
declare -A BOTS_TIMEOUT_START
POLL_START_EPOCH=$(date +%s)
echo "Timeout anchor: trigger at epoch $TRIGGER_EPOCH (poll started at $POLL_START_EPOCH)" >&2
for bot in "${PR_CONFIGURED_BOTS_ARRAY[@]}"; do
    BOTS_RESPONDED["$bot"]="false"
    # Use TRIGGER_EPOCH for timeout, not poll start
    BOTS_TIMEOUT_START["$bot"]="$TRIGGER_EPOCH"
done

# Collect all new comments with deduplication by id
declare -A SEEN_COMMENT_IDS
ALL_NEW_COMMENTS="[]"

while true; do
    CURRENT_TIME=$(date +%s)

    # Check if all configured bots have responded OR timed out (per-bot 15min timeout)
    ALL_DONE=true
    WAITING_BOTS=""
    TIMED_OUT_BOTS=""

    for bot in "${PR_CONFIGURED_BOTS_ARRAY[@]}"; do
        if [[ "${BOTS_RESPONDED[$bot]}" == "true" ]]; then
            continue  # Bot already responded
        fi

        # Check per-bot timeout (15 minutes each)
        BOT_ELAPSED=$((CURRENT_TIME - BOTS_TIMEOUT_START[$bot]))
        if [[ $BOT_ELAPSED -ge $PR_POLL_TIMEOUT ]]; then
            echo "Bot '$bot' timed out after ${PR_POLL_TIMEOUT}s" >&2
            if [[ -n "$TIMED_OUT_BOTS" ]]; then
                TIMED_OUT_BOTS="${TIMED_OUT_BOTS}, ${bot}"
            else
                TIMED_OUT_BOTS="$bot"
            fi
            continue  # Mark as done (timed out)
        fi

        # Bot still waiting
        ALL_DONE=false
        if [[ -n "$WAITING_BOTS" ]]; then
            WAITING_BOTS="${WAITING_BOTS},${bot}"
        else
            WAITING_BOTS="$bot"
        fi
    done

    if [[ "$ALL_DONE" == "true" ]]; then
        if [[ -n "$TIMED_OUT_BOTS" ]]; then
            echo "Polling complete. Timed out bots: $TIMED_OUT_BOTS" >&2
        else
            echo "All configured bots have responded!" >&2
        fi
        break
    fi

    # Check for cancel signal
    if [[ -f "$LOOP_DIR/.cancel-requested" ]]; then
        echo "Cancel requested, exiting poll loop..." >&2
        exit 0
    fi

    TOTAL_ELAPSED=$((CURRENT_TIME - POLL_START_EPOCH))
    echo "Poll attempt (elapsed: ${TOTAL_ELAPSED}s, waiting for: $WAITING_BOTS)..." >&2

    # Poll for new comments from bots we're still waiting for
    POLL_RESULT=$("$POLL_SCRIPT" "$PR_NUMBER" --after "$AFTER_TIMESTAMP" --bots "$WAITING_BOTS" 2>/dev/null) || {
        echo "Warning: Poll script failed, retrying..." >&2
        sleep "$PR_POLL_INTERVAL"
        continue
    }

    # Check which bots responded (check all configured bots)
    # Poll script returns author names (e.g., chatgpt-codex-connector[bot])
    # We need to map them back to bot names (e.g., codex)
    RESPONDED_BOTS=$(echo "$POLL_RESULT" | jq -r '.bots_responded[]' 2>/dev/null || true)
    for responded_author in $RESPONDED_BOTS; do
        # Map author name to bot name (e.g., chatgpt-codex-connector[bot] -> codex)
        responded_bot=$(map_author_to_bot "$responded_author")
        for bot in "${PR_CONFIGURED_BOTS_ARRAY[@]}"; do
            if [[ "$responded_bot" == "$bot" ]]; then
                if [[ "${BOTS_RESPONDED[$bot]}" != "true" ]]; then
                    BOTS_RESPONDED["$bot"]="true"
                    echo "Bot '$bot' has responded!" >&2
                fi
            fi
        done
    done

    # Collect new comments WITH DEDUPLICATION by comment id
    NEW_COMMENTS=$(echo "$POLL_RESULT" | jq -r '.comments' 2>/dev/null || echo "[]")
    if [[ "$NEW_COMMENTS" != "[]" && "$NEW_COMMENTS" != "null" ]]; then
        # Deduplicate: only add comments we haven't seen before
        UNIQUE_COMMENTS="[]"
        while IFS= read -r comment_json; do
            [[ -z "$comment_json" || "$comment_json" == "null" ]] && continue
            COMMENT_ID=$(echo "$comment_json" | jq -r '.id // empty')
            if [[ -n "$COMMENT_ID" && -z "${SEEN_COMMENT_IDS[$COMMENT_ID]:-}" ]]; then
                SEEN_COMMENT_IDS["$COMMENT_ID"]="1"
                UNIQUE_COMMENTS=$(echo "$UNIQUE_COMMENTS" | jq --argjson c "$comment_json" '. + [$c]')
            fi
        done < <(echo "$NEW_COMMENTS" | jq -c '.[]')

        if [[ "$UNIQUE_COMMENTS" != "[]" ]]; then
            ALL_NEW_COMMENTS=$(echo "$ALL_NEW_COMMENTS $UNIQUE_COMMENTS" | jq -s 'add')
        fi
    fi

    sleep "$PR_POLL_INTERVAL"
done

# ========================================
# Handle No Responses
# ========================================

COMMENT_COUNT=$(echo "$ALL_NEW_COMMENTS" | jq 'length' 2>/dev/null || echo "0")

if [[ "$COMMENT_COUNT" == "0" ]]; then
    echo "No new bot reviews received." >&2

    # Build list of bots that didn't respond (check all configured bots)
    MISSING_BOTS=""
    for bot in "${PR_CONFIGURED_BOTS_ARRAY[@]}"; do
        if [[ "${BOTS_RESPONDED[$bot]}" != "true" ]]; then
            if [[ -n "$MISSING_BOTS" ]]; then
                MISSING_BOTS="${MISSING_BOTS}, ${bot}"
            else
                MISSING_BOTS="$bot"
            fi
        fi
    done

    REASON="# Bot Review Timeout

No new reviews received from bots after polling.

**Bots that did not respond:** $MISSING_BOTS

This might mean:
- The bots haven't been triggered (did you comment on the PR?)
- The bots are slow to respond
- The bots are not enabled on this repository

**Options:**
1. Comment on the PR to trigger bot reviews:
   \`\`\`bash
   gh pr comment $PR_NUMBER --body \"$PR_BOT_MENTION_STRING please review the latest changes\"
   \`\`\`
2. Wait and try exiting again
3. Cancel the loop: \`/humanize:cancel-pr-loop\`"

    jq -n --arg reason "$REASON" --arg msg "PR Loop: Bot review timeout" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

# ========================================
# Save New Comments (correct file naming)
# ========================================

# Format comments grouped by bot (use configured bots for completeness)
cat > "$COMMENT_FILE" << EOF
# Bot Reviews (Round $NEXT_ROUND)

Fetched at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Configured bots: $PR_CONFIGURED_BOTS_DISPLAY
Currently active: $PR_ACTIVE_BOTS_DISPLAY

---

EOF

# Group comments by ALL configured bots (not just active)
# This allows Codex to see when previously approved bots post new issues
for bot in "${PR_CONFIGURED_BOTS_ARRAY[@]}"; do
    # Map bot name to author name (e.g., codex -> chatgpt-codex-connector[bot])
    author=$(map_bot_to_author "$bot")
    BOT_COMMENTS=$(echo "$ALL_NEW_COMMENTS" | jq -r --arg author "$author" '
        [.[] | select(.author == $author)]
    ')
    BOT_COUNT=$(echo "$BOT_COMMENTS" | jq 'length')

    if [[ "$BOT_COUNT" -gt 0 ]]; then
        echo "## Comments from ${author}" >> "$COMMENT_FILE"
        echo "" >> "$COMMENT_FILE"

        echo "$BOT_COMMENTS" | jq -r '
            .[] |
            "### Comment\n\n" +
            "- **Type**: \(.type | gsub("_"; " "))\n" +
            "- **Time**: \(.created_at)\n" +
            (if .path then "- **File**: `\(.path)`\(if .line then " (line \(.line))" else "" end)\n" else "" end) +
            (if .state then "- **Status**: \(.state)\n" else "" end) +
            "\n\(.body)\n\n---\n"
        ' >> "$COMMENT_FILE"
    else
        echo "## Comments from ${author}" >> "$COMMENT_FILE"
        echo "" >> "$COMMENT_FILE"
        echo "*No new comments from this bot.*" >> "$COMMENT_FILE"
        echo "" >> "$COMMENT_FILE"
        echo "---" >> "$COMMENT_FILE"
        echo "" >> "$COMMENT_FILE"
    fi
done

echo "Comments saved to: $COMMENT_FILE" >&2

# ========================================
# Run Local Codex Review of Bot Feedback
# ========================================

# Consistent file naming: all round-N files refer to round N
CHECK_FILE="$LOOP_DIR/round-${NEXT_ROUND}-pr-check.md"
FEEDBACK_FILE="$LOOP_DIR/round-${NEXT_ROUND}-pr-feedback.md"

echo "Running local Codex review of bot feedback..." >&2

# Build Codex prompt with per-bot analysis
CODEX_PROMPT_FILE="$LOOP_DIR/round-${NEXT_ROUND}-codex-prompt.md"
BOT_REVIEW_CONTENT=$(cat "$COMMENT_FILE")

# Build list of expected bots for Codex (all configured bots)
EXPECTED_BOTS_LIST=""
for bot in "${PR_CONFIGURED_BOTS_ARRAY[@]}"; do
    EXPECTED_BOTS_LIST="${EXPECTED_BOTS_LIST}- ${bot}\n"
done

cat > "$CODEX_PROMPT_FILE" << EOF
# PR Review Validation (Per-Bot Analysis)

Analyze the following bot reviews and determine approval status FOR EACH BOT.

## Expected Bots
$(echo -e "$EXPECTED_BOTS_LIST")

## Bot Reviews
$BOT_REVIEW_CONTENT

## Your Task

1. For EACH expected bot, analyze their review (if present)
2. Determine if each bot is:
   - **APPROVE**: Bot explicitly approves or says "no issues found", "LGTM", "Didn't find any major issues", etc.
   - **ISSUES**: Bot identifies specific problems that need fixing
   - **NO_RESPONSE**: Bot did not post any new comments

3. Output your analysis to $CHECK_FILE with this EXACT structure:

### Per-Bot Status
| Bot | Status | Summary |
|-----|--------|---------|
| <bot_name> | APPROVE/ISSUES/NO_RESPONSE | <brief summary> |

### Issues Found (if any)
List ALL specific issues from bots that have ISSUES status.

### Approved Bots (to remove from active_bots)
List bots that should be removed from active tracking (those with APPROVE status).

### Final Recommendation
- If ALL bots have APPROVE status: End with "APPROVE" on its own line
- If any bot has ISSUES status: End with "ISSUES_REMAINING" on its own line
- If any bot has NO_RESPONSE status: End with "WAITING_FOR_BOTS" on its own line
EOF

# Check if codex is available
if ! command -v codex &>/dev/null; then
    REASON="# Codex Not Found

The 'codex' command is not installed or not in PATH.
PR loop requires Codex CLI to validate bot reviews.

**To fix:**
1. Install Codex CLI
2. Retry the exit

Or use \`/humanize:cancel-pr-loop\` to cancel the loop."

    jq -n --arg reason "$REASON" --arg msg "PR Loop: Codex not found" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

# Run Codex
CODEX_ARGS=("-m" "$PR_CODEX_MODEL")
if [[ -n "$PR_CODEX_EFFORT" ]]; then
    CODEX_ARGS+=("-c" "model_reasoning_effort=${PR_CODEX_EFFORT}")
fi
CODEX_ARGS+=("--full-auto" "-C" "$PROJECT_ROOT")

CODEX_PROMPT_CONTENT=$(cat "$CODEX_PROMPT_FILE")
CODEX_EXIT_CODE=0

printf '%s' "$CODEX_PROMPT_CONTENT" | run_with_timeout "$PR_CODEX_TIMEOUT" codex exec "${CODEX_ARGS[@]}" - \
    > "$CHECK_FILE" 2>/dev/null || CODEX_EXIT_CODE=$?

if [[ $CODEX_EXIT_CODE -ne 0 ]]; then
    REASON="# Codex Review Failed

Codex failed to validate bot reviews (exit code: $CODEX_EXIT_CODE).

Please retry or cancel the loop."

    jq -n --arg reason "$REASON" --arg msg "PR Loop: Codex review failed" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

if [[ ! -s "$CHECK_FILE" ]]; then
    REASON="# Codex Review Empty

Codex produced no output when validating bot reviews.

Please retry or cancel the loop."

    jq -n --arg reason "$REASON" --arg msg "PR Loop: Codex review empty" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

# ========================================
# Check Codex Result and Update active_bots
# ========================================

CHECK_CONTENT=$(cat "$CHECK_FILE")
LAST_LINE=$(echo "$CHECK_CONTENT" | grep -v '^[[:space:]]*$' | tail -1)
LAST_LINE_TRIMMED=$(echo "$LAST_LINE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

# Per AC-8: Use "APPROVE" marker
if [[ "$LAST_LINE_TRIMMED" == "APPROVE" ]]; then
    echo "All bots have approved! PR loop complete." >&2
    mv "$STATE_FILE" "$LOOP_DIR/complete-state.md"
    exit 0
fi

# Handle WAITING_FOR_BOTS - block exit but don't advance round
if [[ "$LAST_LINE_TRIMMED" == "WAITING_FOR_BOTS" ]]; then
    echo "Some bots haven't responded yet. Blocking exit." >&2

    REASON="# Waiting for Bot Responses

Some bots haven't posted their reviews yet.

**Options:**
1. Wait and try exiting again (bots may still be processing)
2. Comment on the PR to trigger bot reviews:
   \`\`\`bash
   gh pr comment $PR_NUMBER --body \"$PR_BOT_MENTION_STRING please review the latest changes\"
   \`\`\`
3. Cancel the loop: \`/humanize:cancel-pr-loop\`

**Note:** The round counter will NOT advance until all expected bots respond."

    jq -n --arg reason "$REASON" --arg msg "PR Loop: Waiting for bot responses" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

# ========================================
# Update active_bots in state file
# ========================================

# Extract approved bots from Codex output and remove them from active_bots
# Look for "### Approved Bots" section
APPROVED_SECTION=$(sed -n '/### Approved Bots/,/^###/p' "$CHECK_FILE" | grep -v '^###' || true)

# Extract bots with issues from Codex output (for re-add logic)
# Look for "### Per-Bot Status" table and find bots with ISSUES status
ISSUES_SECTION=$(sed -n '/### Per-Bot Status/,/^###/p' "$CHECK_FILE" || true)

# Build new active_bots array with re-add logic
# IMPORTANT: Process ALL configured bots, not just currently active ones
# This allows re-adding bots that were previously approved but now have new issues
declare -a NEW_ACTIVE_BOTS=()
declare -A BOTS_WITH_ISSUES=()
declare -A BOTS_APPROVED=()

# First, identify bots with issues from Codex output
while IFS= read -r line; do
    if echo "$line" | grep -qiE '\|[[:space:]]*ISSUES[[:space:]]*\|'; then
        # Extract bot name from table row: | botname | ISSUES | summary |
        BOT_WITH_ISSUE=$(echo "$line" | sed 's/|/\n/g' | sed -n '2p' | tr -d ' ')
        if [[ -n "$BOT_WITH_ISSUE" ]]; then
            BOTS_WITH_ISSUES["$BOT_WITH_ISSUE"]="true"
        fi
    fi
    if echo "$line" | grep -qiE '\|[[:space:]]*APPROVE[[:space:]]*\|'; then
        # Extract bot name from table row: | botname | APPROVE | summary |
        BOT_APPROVED=$(echo "$line" | sed 's/|/\n/g' | sed -n '2p' | tr -d ' ')
        if [[ -n "$BOT_APPROVED" ]]; then
            BOTS_APPROVED["$BOT_APPROVED"]="true"
        fi
    fi
done <<< "$ISSUES_SECTION"

# Process ALL configured bots (not just currently active)
# This allows re-adding previously approved bots if they post new issues
for bot in "${PR_CONFIGURED_BOTS_ARRAY[@]}"; do
    if [[ "${BOTS_WITH_ISSUES[$bot]:-}" == "true" ]]; then
        # Bot has issues - add to active list
        if [[ "${BOTS_APPROVED[$bot]:-}" == "true" ]]; then
            echo "Bot '$bot' was previously approved but has new issues - re-adding to active" >&2
        else
            echo "Bot '$bot' has issues - keeping active" >&2
        fi
        NEW_ACTIVE_BOTS+=("$bot")
    elif [[ "${BOTS_APPROVED[$bot]:-}" == "true" ]]; then
        # Bot approved with no new issues - remove from active
        echo "Removing '$bot' from active_bots (approved)" >&2
    elif echo "$APPROVED_SECTION" | grep -qi "$bot"; then
        # Bot mentioned in approved section - remove
        echo "Removing '$bot' from active_bots (in approved section)" >&2
    else
        # Bot not mentioned in ISSUES or APPROVE - check if was active
        WAS_ACTIVE=false
        for active_bot in "${PR_ACTIVE_BOTS_ARRAY[@]}"; do
            if [[ "$bot" == "$active_bot" ]]; then
                WAS_ACTIVE=true
                break
            fi
        done
        if [[ "$WAS_ACTIVE" == "true" ]]; then
            # Was active, not mentioned - keep active (NO_RESPONSE case)
            echo "Bot '$bot' not mentioned - keeping active" >&2
            NEW_ACTIVE_BOTS+=("$bot")
        fi
    fi
done

# Update state file with new active_bots and incremented round
TEMP_FILE="${STATE_FILE}.tmp.$$"

# Build new YAML list for active_bots
NEW_ACTIVE_BOTS_YAML=""
for bot in "${NEW_ACTIVE_BOTS[@]}"; do
    NEW_ACTIVE_BOTS_YAML="${NEW_ACTIVE_BOTS_YAML}
  - ${bot}"
done

# Build YAML list for configured_bots (never changes)
CONFIGURED_BOTS_YAML=""
for bot in "${PR_CONFIGURED_BOTS_ARRAY[@]}"; do
    CONFIGURED_BOTS_YAML="${CONFIGURED_BOTS_YAML}
  - ${bot}"
done

# Create updated state file (with last_trigger_at cleared - will be set when next @mention posted)
{
    echo "---"
    echo "current_round: $NEXT_ROUND"
    echo "max_iterations: $PR_MAX_ITERATIONS"
    echo "pr_number: $PR_NUMBER"
    echo "start_branch: $PR_START_BRANCH"
    echo "configured_bots:${CONFIGURED_BOTS_YAML}"
    echo "active_bots:${NEW_ACTIVE_BOTS_YAML}"
    echo "codex_model: $PR_CODEX_MODEL"
    echo "codex_effort: $PR_CODEX_EFFORT"
    echo "codex_timeout: $PR_CODEX_TIMEOUT"
    echo "poll_interval: $PR_POLL_INTERVAL"
    echo "poll_timeout: $PR_POLL_TIMEOUT"
    echo "started_at: $PR_STARTED_AT"
    echo "last_trigger_at:"
    echo "---"
} > "$TEMP_FILE"
mv "$TEMP_FILE" "$STATE_FILE"

# Check if all bots are now approved
if [[ ${#NEW_ACTIVE_BOTS[@]} -eq 0 ]]; then
    echo "All bots have now approved! PR loop complete." >&2
    mv "$STATE_FILE" "$LOOP_DIR/complete-state.md"
    exit 0
fi

# ========================================
# Issues Remaining - Continue Loop
# ========================================

# Build new bot mention string
NEW_BOT_MENTION_STRING=""
for bot in "${NEW_ACTIVE_BOTS[@]}"; do
    if [[ -n "$NEW_BOT_MENTION_STRING" ]]; then
        NEW_BOT_MENTION_STRING="${NEW_BOT_MENTION_STRING} @${bot}"
    else
        NEW_BOT_MENTION_STRING="@${bot}"
    fi
done

# Create feedback file for next round
cat > "$FEEDBACK_FILE" << EOF
# PR Loop Feedback (Round $NEXT_ROUND)

## Bot Review Analysis

$CHECK_CONTENT

---

## Your Task

Address the issues identified above:

1. Read and understand each issue
2. Make the necessary code changes
3. Commit and push your changes
4. Comment on the PR to trigger re-review:
   \`\`\`bash
   gh pr comment $PR_NUMBER --body "$NEW_BOT_MENTION_STRING please review the latest changes"
   \`\`\`
5. Write your resolution summary to: $LOOP_DIR/round-${NEXT_ROUND}-pr-resolve.md

---

**Remaining active bots:** $(IFS=', '; echo "${NEW_ACTIVE_BOTS[*]}")
**Round:** $NEXT_ROUND of $PR_MAX_ITERATIONS
EOF

SYSTEM_MSG="PR Loop: Round $NEXT_ROUND/$PR_MAX_ITERATIONS - Bot reviews identified issues"

jq -n \
    --arg reason "$(cat "$FEEDBACK_FILE")" \
    --arg msg "$SYSTEM_MSG" \
    '{
        "decision": "block",
        "reason": $reason,
        "systemMessage": $msg
    }'

exit 0
