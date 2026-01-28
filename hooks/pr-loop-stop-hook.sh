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
# - Uses APPROVE marker for Codex approval
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

# Note: Bot name mapping functions (map_bot_to_author, map_author_to_bot)
# and helper functions (build_yaml_list, build_bot_mention_string) are
# provided by loop-common.sh which is sourced below.

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
TEMPLATE_DIR="$PLUGIN_ROOT/prompt-template"
source "$PLUGIN_ROOT/scripts/portable-timeout.sh"

# Default timeout for git/gh operations
GIT_TIMEOUT=30
GH_TIMEOUT=60

# Use shared find_active_pr_loop function from loop-common.sh
LOOP_DIR=$(find_active_pr_loop "$LOOP_BASE_DIR")

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

# Declare arrays outside function for macOS Bash 3.2 compatibility
# (declare -g requires Bash 4.2+, which macOS doesn't have by default)
PR_CONFIGURED_BOTS_ARRAY=()
PR_ACTIVE_BOTS_ARRAY=()

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

    # New state fields for Cases 1-5 and force push detection
    PR_STARTUP_CASE=$(echo "$STATE_FRONTMATTER" | grep "^startup_case:" | sed "s/startup_case: *//" | tr -d ' ' || true)
    PR_LATEST_COMMIT_SHA=$(echo "$STATE_FRONTMATTER" | grep "^latest_commit_sha:" | sed "s/latest_commit_sha: *//" | tr -d ' ' || true)
    PR_LATEST_COMMIT_AT=$(echo "$STATE_FRONTMATTER" | grep "^latest_commit_at:" | sed "s/latest_commit_at: *//" || true)
    PR_TRIGGER_COMMENT_ID=$(echo "$STATE_FRONTMATTER" | grep "^trigger_comment_id:" | sed "s/trigger_comment_id: *//" | tr -d ' ' || true)

    # Parse configured_bots and active_bots as YAML lists
    # configured_bots: never changes, used for polling all bots (allows re-add)
    # active_bots: current bots with issues, shrinks as bots approve
    # Arrays are declared outside function for macOS Bash 3.2 compatibility
    PR_CONFIGURED_BOTS_ARRAY=()
    PR_ACTIVE_BOTS_ARRAY=()

    # Parse YAML list helper function
    # NOTE: Avoids 'local -n' (nameref) which requires Bash 4.3+ and fails on macOS Bash 3.2
    # Instead, outputs values to stdout and caller captures into array
    parse_yaml_list() {
        local field_name="$1"
        local in_field=false

        while IFS= read -r line; do
            if [[ "$line" =~ ^${field_name}: ]]; then
                in_field=true
                # Check if it's inline format: field: value
                local inline_value="${line#*: }"
                if [[ -n "$inline_value" && "$inline_value" != "${field_name}:" ]]; then
                    # Old comma-separated format for backwards compatibility
                    echo "$inline_value" | tr ',' '\n' | tr -d ' '
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
                        echo "$bot_name"
                    fi
                elif [[ "$line" =~ ^[a-zA-Z_] ]]; then
                    # New field started, stop parsing
                    in_field=false
                fi
            fi
        done <<< "$STATE_FRONTMATTER"
    }

    # Read parsed values into arrays (macOS Bash 3.2 compatible)
    while IFS= read -r bot; do
        [[ -n "$bot" ]] && PR_CONFIGURED_BOTS_ARRAY+=("$bot")
    done < <(parse_yaml_list "configured_bots")

    while IFS= read -r bot; do
        [[ -n "$bot" ]] && PR_ACTIVE_BOTS_ARRAY+=("$bot")
    done < <(parse_yaml_list "active_bots")

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
PR_BOT_MENTION_STRING=$(build_bot_mention_string "${PR_CONFIGURED_BOTS_ARRAY[@]}")

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
# Resolve PR Base Repository (for fork PRs)
# ========================================
# IMPORTANT: For fork PRs, comments are on the base repository, not the fork.
# gh pr view without --repo fails in forks because the PR number doesn't exist there.
# Strategy: First get current repo, check if PR exists there, then try parent repo for forks.
# NOTE: This MUST be done BEFORE PR state checks, which also need --repo for forks.

# Step 1: Get the current repo (works in both forks and base repos)
CURRENT_REPO=$(run_with_timeout "$GH_TIMEOUT" gh repo view --json owner,name \
    -q '.owner.login + "/" + .name' 2>/dev/null) || CURRENT_REPO=""

# Step 2: Determine the correct repo for PR operations
# Try current repo first - if PR exists there, use it
PR_BASE_REPO=""
PR_LOOKUP_REPO=""  # Repo where PR was found (for subsequent lookups)

if [[ -n "$CURRENT_REPO" ]]; then
    if run_with_timeout "$GH_TIMEOUT" gh pr view "$PR_NUMBER" --repo "$CURRENT_REPO" --json number -q .number >/dev/null 2>&1; then
        PR_BASE_REPO="$CURRENT_REPO"
        PR_LOOKUP_REPO="$CURRENT_REPO"
    fi
fi

if [[ -z "$PR_BASE_REPO" ]]; then
    # PR not found in current repo - check if this is a fork and try parent repo
    PARENT_REPO=$(run_with_timeout "$GH_TIMEOUT" gh repo view --json parent \
        -q '.parent.owner.login + "/" + .parent.name' 2>/dev/null) || PARENT_REPO=""
    if [[ -n "$PARENT_REPO" && "$PARENT_REPO" != "null/" && "$PARENT_REPO" != "/" ]]; then
        if run_with_timeout "$GH_TIMEOUT" gh pr view "$PR_NUMBER" --repo "$PARENT_REPO" --json number -q .number >/dev/null 2>&1; then
            PR_BASE_REPO="$PARENT_REPO"
            PR_LOOKUP_REPO="$PARENT_REPO"
        fi
    fi
fi

if [[ -z "$PR_BASE_REPO" ]]; then
    echo "Warning: Could not resolve PR base repository, using current repo" >&2
    PR_BASE_REPO="$CURRENT_REPO"
    PR_LOOKUP_REPO="$CURRENT_REPO"
fi

# ========================================
# Check PR State (detect CLOSED/MERGED before polling)
# ========================================
# NOTE: Uses PR_LOOKUP_REPO (resolved above) for fork PR support

PR_STATE=$(run_with_timeout "$GH_TIMEOUT" gh pr view "$PR_NUMBER" --repo "$PR_LOOKUP_REPO" --json state -q .state 2>/dev/null) || PR_STATE=""

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

    # Step 6: Check for unpushed commits (PR loop always requires push)
    CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "main")
    AHEAD_COUNT=0
    LOCAL_HEAD=$(git rev-parse HEAD 2>/dev/null) || LOCAL_HEAD=""

    # First try: git status -sb works when upstream is configured
    GIT_AHEAD=$(run_with_timeout "$GIT_TIMEOUT" git status -sb 2>/dev/null | grep -o 'ahead [0-9]*' || true)
    if [[ -n "$GIT_AHEAD" ]]; then
        AHEAD_COUNT=$(echo "$GIT_AHEAD" | grep -o '[0-9]*')
    else
        # Fallback: Check if upstream exists, if not compare with origin/branch or PR head
        if ! git rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
            # No upstream configured - try origin/branch first
            REMOTE_HEAD=$(git rev-parse "origin/$CURRENT_BRANCH" 2>/dev/null) || REMOTE_HEAD=""
            if [[ -n "$LOCAL_HEAD" && -n "$REMOTE_HEAD" && "$LOCAL_HEAD" != "$REMOTE_HEAD" ]]; then
                # Count commits ahead of remote
                AHEAD_COUNT=$(git rev-list --count "origin/$CURRENT_BRANCH..HEAD" 2>/dev/null) || AHEAD_COUNT=0
            elif [[ -z "$REMOTE_HEAD" && -n "$PR_NUMBER" ]]; then
                # No origin/branch exists - compare with PR's headRefOid from GitHub
                # This handles cases where branch was never pushed or remote ref is missing
                # NOTE: Use --repo for fork PR support (PR_BASE_REPO resolved earlier)
                PR_HEAD_SHA=$(run_with_timeout "$GH_TIMEOUT" gh pr view "$PR_NUMBER" --repo "$PR_BASE_REPO" --json headRefOid -q '.headRefOid' 2>/dev/null) || PR_HEAD_SHA=""
                if [[ -z "$PR_HEAD_SHA" ]]; then
                    # Failed to get PR head - fail closed (assume unpushed) for safety
                    echo "Warning: Could not fetch PR head SHA, assuming unpushed commits" >&2
                    AHEAD_COUNT=1
                elif [[ -n "$LOCAL_HEAD" && "$LOCAL_HEAD" != "$PR_HEAD_SHA" ]]; then
                    # Local differs from PR head - count commits since PR head
                    AHEAD_COUNT=$(git rev-list --count "$PR_HEAD_SHA..HEAD" 2>/dev/null) || {
                        # PR head not in local history (force push?) - treat as 1 unpushed
                        AHEAD_COUNT=1
                    }
                fi
            fi
        fi
    fi

    if [[ "$AHEAD_COUNT" -gt 0 ]]; then
        FALLBACK_MSG="# Unpushed Commits Detected

You have $AHEAD_COUNT unpushed commit(s). PR loop requires pushing changes so bots can review them.

Please push: git push origin $CURRENT_BRANCH"
        REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/unpushed-commits.md" "$FALLBACK_MSG" \
            "AHEAD_COUNT=$AHEAD_COUNT" "CURRENT_BRANCH=$CURRENT_BRANCH")
        jq -n --arg reason "$REASON" --arg msg "PR Loop: $AHEAD_COUNT unpushed commit(s)" \
            '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
        exit 0
    fi
fi

# ========================================
# Force Push Detection
# ========================================

# Detect if the remote branch HEAD has changed in a way that indicates force push
# This happens when previous commits are no longer reachable from current HEAD
if [[ -n "$PR_LATEST_COMMIT_SHA" ]]; then
    CURRENT_HEAD=$(run_with_timeout "$GIT_TIMEOUT" git rev-parse HEAD 2>/dev/null) || CURRENT_HEAD=""

    # Check if the stored commit SHA is still reachable from current HEAD
    # If not, a force push (history rewrite) has occurred
    if [[ -n "$CURRENT_HEAD" && "$CURRENT_HEAD" != "$PR_LATEST_COMMIT_SHA" ]]; then
        # Check if old commit is ancestor of current HEAD
        IS_ANCESTOR=$(run_with_timeout "$GIT_TIMEOUT" git merge-base --is-ancestor "$PR_LATEST_COMMIT_SHA" "$CURRENT_HEAD" 2>/dev/null && echo "yes" || echo "no")

        if [[ "$IS_ANCESTOR" == "no" ]]; then
            echo "Force push detected: $PR_LATEST_COMMIT_SHA is no longer reachable from $CURRENT_HEAD" >&2

            # Preserve OLD commit SHA before updating state
            OLD_COMMIT_SHA="$PR_LATEST_COMMIT_SHA"

            # Get the timestamp of the new HEAD commit for trigger validation
            # This ensures detect_trigger_comment only accepts comments AFTER the force push
            # NOTE: Uses PR_LOOKUP_REPO for fork PR support
            NEW_HEAD_COMMIT_AT=$(run_with_timeout "$GH_TIMEOUT" gh pr view "$PR_NUMBER" --repo "$PR_LOOKUP_REPO" --json commits \
                --jq '.commits | sort_by(.committedDate) | last | .committedDate' 2>/dev/null) || NEW_HEAD_COMMIT_AT=""

            if [[ -z "$NEW_HEAD_COMMIT_AT" ]]; then
                # Fallback: use current timestamp
                NEW_HEAD_COMMIT_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            fi

            # Update state file with new commit SHA/timestamp and clear trigger state
            # Clear BOTH last_trigger_at AND trigger_comment_id to prevent stale eyes checks
            TEMP_FILE="${STATE_FILE}.forcepush.$$"
            sed -e "s/^latest_commit_sha:.*/latest_commit_sha: $CURRENT_HEAD/" \
                -e "s/^latest_commit_at:.*/latest_commit_at: $NEW_HEAD_COMMIT_AT/" \
                -e "s/^last_trigger_at:.*/last_trigger_at:/" \
                -e "s/^trigger_comment_id:.*/trigger_comment_id:/" \
                "$STATE_FILE" > "$TEMP_FILE"
            mv "$TEMP_FILE" "$STATE_FILE"

            # Update local variables to reflect the change
            PR_LATEST_COMMIT_SHA="$CURRENT_HEAD"
            PR_LATEST_COMMIT_AT="$NEW_HEAD_COMMIT_AT"
            PR_LAST_TRIGGER_AT=""
            PR_TRIGGER_COMMENT_ID=""

            FALLBACK_MSG="# Force Push Detected

A force push (history rewrite) has been detected. Post a new @bot trigger comment: $PR_BOT_MENTION_STRING"
            REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/force-push-detected.md" "$FALLBACK_MSG" \
                "OLD_COMMIT=$OLD_COMMIT_SHA" "NEW_COMMIT=$CURRENT_HEAD" "BOT_MENTION_STRING=$PR_BOT_MENTION_STRING" \
                "PR_NUMBER=$PR_NUMBER")

            jq -n --arg reason "$REASON" --arg msg "PR Loop: Force push detected - please re-trigger bots" \
                '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
            exit 0
        fi
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
# NOTE: Step 8 (Codex +1 check) has been moved to after trigger detection
# to ensure it uses the correct timestamp that accounts for new commits.

if [[ ${#PR_ACTIVE_BOTS_ARRAY[@]} -eq 0 ]]; then
    echo "All bots have approved. PR loop complete!" >&2
    mv "$STATE_FILE" "$LOOP_DIR/approve-state.md"
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
# Returns: "timestamp|comment_id" on success
# This timestamp is used for --after filtering to catch fast bot replies
# NOTE: Uses --paginate to handle PRs with >30 comments
# IMPORTANT: If latest_commit_at is set, only accepts comments AFTER that timestamp
#            This prevents old triggers from being re-used after force push
# IMPORTANT: Uses PR_BASE_REPO (not {owner}/{repo}) for fork PR support
detect_trigger_comment() {
    local pr_num="$1"
    local current_user="$2"
    local after_timestamp="${3:-}"  # Optional: only accept comments after this timestamp

    # Fetch ALL issue comments on the PR (paginated to handle >30 comments)
    # Using --paginate ensures we don't miss the latest @mention on large PRs
    # IMPORTANT: --jq with --paginate runs per-page, so we output objects (not array)
    # and use jq -s to aggregate all pages into a single array before filtering
    # IMPORTANT: Use PR_BASE_REPO for fork PRs - comments are on base repo, not fork
    local comments_json
    comments_json=$(run_with_timeout "$GH_TIMEOUT" gh api "repos/$PR_BASE_REPO/issues/$pr_num/comments" \
        --paginate --jq '.[] | {id: .id, author: .user.login, created_at: .created_at, body: .body}' 2>/dev/null \
        | jq -s '.') || return 1

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
    # comments_json is already aggregated from all pages into a single array
    # If after_timestamp is set, only accept comments created after that timestamp
    # Returns both timestamp and comment ID
    local trigger_info
    if [[ -n "$after_timestamp" ]]; then
        # Filter to only comments AFTER the specified timestamp (force push protection)
        trigger_info=$(echo "$comments_json" | jq -r \
            --arg pattern "$bot_pattern" \
            --arg user "$current_user" \
            --arg after "$after_timestamp" '
            [.[] | select(
                .author == $user and
                (.body | test($pattern; "i")) and
                (.created_at >= $after)
            )] |
            sort_by(.created_at) | reverse | .[0] | "\(.created_at)|\(.id)" // empty
        ')
    else
        trigger_info=$(echo "$comments_json" | jq -r --arg pattern "$bot_pattern" --arg user "$current_user" '
            [.[] | select(.author == $user and (.body | test($pattern; "i")))] |
            sort_by(.created_at) | reverse | .[0] | "\(.created_at)|\(.id)" // empty
        ')
    fi

    if [[ -n "$trigger_info" && "$trigger_info" != "null|null" && "$trigger_info" != "|" ]]; then
        echo "$trigger_info"
        return 0
    fi

    return 1
}

# Get current user for trigger comment filtering
CURRENT_USER=$(get_current_user)
if [[ -z "$CURRENT_USER" ]]; then
    echo "Warning: Could not determine current GitHub user" >&2
fi

# ========================================
# Refresh latest_commit_at from PR Before Trigger Detection
# ========================================
# Ensure trigger validation uses the CURRENT latest commit timestamp,
# not a stale value from state. This prevents old triggers from being accepted
# after new (non-force) commits are pushed.

# NOTE: Uses PR_LOOKUP_REPO for fork PR support
CURRENT_LATEST_COMMIT_AT=$(run_with_timeout "$GH_TIMEOUT" gh pr view "$PR_NUMBER" --repo "$PR_LOOKUP_REPO" --json commits \
    --jq '.commits | sort_by(.committedDate) | last | .committedDate' 2>/dev/null) || CURRENT_LATEST_COMMIT_AT=""

# Track if new commits were detected (used to override REQUIRE_TRIGGER for cases 2/3)
NEW_COMMITS_DETECTED=false

if [[ -n "$CURRENT_LATEST_COMMIT_AT" && "$CURRENT_LATEST_COMMIT_AT" != "$PR_LATEST_COMMIT_AT" ]]; then
    echo "Updating latest_commit_at: $PR_LATEST_COMMIT_AT -> $CURRENT_LATEST_COMMIT_AT" >&2
    echo "  Clearing stale trigger fields (new commits require new @bot mention)" >&2

    # Persist to state file and clear trigger fields to prevent stale polling
    # New commits mean old trigger is invalid - user must post new @bot comment
    TEMP_FILE="${STATE_FILE}.commitrefresh.$$"
    sed -e "s/^latest_commit_at:.*/latest_commit_at: $CURRENT_LATEST_COMMIT_AT/" \
        -e "s/^last_trigger_at:.*/last_trigger_at:/" \
        -e "s/^trigger_comment_id:.*/trigger_comment_id:/" \
        "$STATE_FILE" > "$TEMP_FILE"
    mv "$TEMP_FILE" "$STATE_FILE"

    PR_LATEST_COMMIT_AT="$CURRENT_LATEST_COMMIT_AT"
    PR_LAST_TRIGGER_AT=""
    PR_TRIGGER_COMMENT_ID=""
    NEW_COMMITS_DETECTED=true
fi

# ALWAYS check for newer trigger comments and update last_trigger_at
# This ensures we use the most recent trigger, not a stale one
# IMPORTANT: Pass latest_commit_at to filter out old triggers (force push protection)
# After a force push, we need a NEW trigger comment, not one from before the push
echo "Detecting trigger comment timestamp from user '$CURRENT_USER'..." >&2
if [[ -n "$PR_LATEST_COMMIT_AT" ]]; then
    echo "  (Filtering for comments after: $PR_LATEST_COMMIT_AT)" >&2
fi
DETECTED_TRIGGER_INFO=$(detect_trigger_comment "$PR_NUMBER" "$CURRENT_USER" "$PR_LATEST_COMMIT_AT") || true
DETECTED_TRIGGER_AT=""
DETECTED_TRIGGER_COMMENT_ID=""

if [[ -n "$DETECTED_TRIGGER_INFO" ]]; then
    # Parse timestamp and comment ID from "timestamp|id" format
    DETECTED_TRIGGER_AT="${DETECTED_TRIGGER_INFO%%|*}"
    DETECTED_TRIGGER_COMMENT_ID="${DETECTED_TRIGGER_INFO##*|}"
fi

if [[ -n "$DETECTED_TRIGGER_AT" ]]; then
    # Check if detected trigger is newer than stored one
    if [[ -z "$PR_LAST_TRIGGER_AT" ]] || [[ "$DETECTED_TRIGGER_AT" > "$PR_LAST_TRIGGER_AT" ]]; then
        echo "Found trigger comment at: $DETECTED_TRIGGER_AT (ID: $DETECTED_TRIGGER_COMMENT_ID)" >&2
        if [[ -n "$PR_LAST_TRIGGER_AT" ]]; then
            echo "  (Updating from older trigger: $PR_LAST_TRIGGER_AT)" >&2
        fi
        PR_LAST_TRIGGER_AT="$DETECTED_TRIGGER_AT"
        PR_TRIGGER_COMMENT_ID="$DETECTED_TRIGGER_COMMENT_ID"

        # Persist to state file
        TEMP_FILE="${STATE_FILE}.trigger.$$"
        sed -e "s/^last_trigger_at:.*/last_trigger_at: $DETECTED_TRIGGER_AT/" \
            -e "s/^trigger_comment_id:.*/trigger_comment_id: $DETECTED_TRIGGER_COMMENT_ID/" \
            "$STATE_FILE" > "$TEMP_FILE"
        mv "$TEMP_FILE" "$STATE_FILE"

        # Note: Claude eyes verification is done in the dedicated section below
        # (after trigger detection) to ensure it runs on EVERY exit attempt
    else
        echo "Using existing trigger timestamp: $PR_LAST_TRIGGER_AT" >&2
    fi
fi

# ========================================
# Determine if Trigger is Required (needed for Claude eyes check below)
# ========================================

# Trigger requirement logic:
# - Round 0, startup_case 1: No trigger required (waiting for initial auto-reviews)
# - Round 0, startup_case 2/3: No trigger required (process existing comments)
# - Round 0, startup_case 4/5: Trigger required (new commits after reviews)
# - Round > 0: Always require trigger
# - NEW: If new commits detected during this poll, require trigger (overrides cases 2/3)

REQUIRE_TRIGGER=false
if [[ "$PR_CURRENT_ROUND" -gt 0 ]]; then
    # Subsequent rounds always require a trigger
    REQUIRE_TRIGGER=true
elif [[ "$NEW_COMMITS_DETECTED" == "true" ]]; then
    # New commits detected during this poll - require fresh trigger
    # This overrides cases 2/3 to prevent reusing stale reviews
    REQUIRE_TRIGGER=true
elif [[ "$PR_CURRENT_ROUND" -eq 0 ]]; then
    case "${PR_STARTUP_CASE:-1}" in
        1|2|3)
            # Case 1: No comments yet - wait for initial auto-reviews
            # Case 2/3: Comments exist - process them without requiring new trigger
            REQUIRE_TRIGGER=false
            ;;
        4|5)
            # Case 4/5: All commented but new commits pushed - require re-trigger
            REQUIRE_TRIGGER=true
            ;;
        *)
            # Unknown case, default to not requiring trigger
            REQUIRE_TRIGGER=false
            ;;
    esac
fi

# ========================================
# Step 8: Check for Codex +1 Reaction (After Trigger Detection)
# ========================================
# IMPORTANT: This check runs AFTER trigger detection to ensure:
# 1. We use the correct timestamp that accounts for new commits
# 2. If trigger is required but missing, we don't approve based on old +1

# Check for codex bot in active bots
CODEX_IN_ACTIVE=false
for bot in "${PR_ACTIVE_BOTS_ARRAY[@]}"; do
    if [[ "$bot" == "codex" ]]; then
        CODEX_IN_ACTIVE=true
        break
    fi
done

if [[ "$CODEX_IN_ACTIVE" == "true" ]]; then
    # Skip +1 check if trigger is required but not yet posted
    # (User needs to post @codex comment first)
    if [[ "$REQUIRE_TRIGGER" == "true" && -z "$PR_LAST_TRIGGER_AT" ]]; then
        echo "Skipping Codex +1 check: trigger required but not yet posted" >&2
    else
        echo "Round $PR_CURRENT_ROUND: Checking for Codex +1 reaction on PR..." >&2

        # Determine the timestamp for filtering +1 reactions
        # Use trigger timestamp if available, otherwise fall back to loop start time
        CODEX_REACTION_AFTER="${PR_LAST_TRIGGER_AT:-$PR_STARTED_AT}"
        echo "  (Checking for +1 after: $CODEX_REACTION_AFTER)" >&2

        # Check for +1 reaction from Codex
        CODEX_REACTION=$("$PLUGIN_ROOT/scripts/check-bot-reactions.sh" codex-thumbsup "$PR_NUMBER" --after "$CODEX_REACTION_AFTER" 2>/dev/null) || CODEX_REACTION=""

        if [[ -n "$CODEX_REACTION" && "$CODEX_REACTION" != "null" ]]; then
            REACTION_AT=$(echo "$CODEX_REACTION" | jq -r '.created_at')
            echo "Codex +1 detected at $REACTION_AT - removing codex from active_bots" >&2

            # Remove only codex from active_bots, keep other bots
            declare -a NEW_ACTIVE_BOTS_AFTER_THUMBSUP=()
            for bot in "${PR_ACTIVE_BOTS_ARRAY[@]}"; do
                if [[ "$bot" != "codex" ]]; then
                    NEW_ACTIVE_BOTS_AFTER_THUMBSUP+=("$bot")
                fi
            done

            # If no other bots remain, loop is complete
            if [[ ${#NEW_ACTIVE_BOTS_AFTER_THUMBSUP[@]} -eq 0 ]]; then
                echo "Codex was the only active bot - PR loop approved!" >&2
                mv "$STATE_FILE" "$LOOP_DIR/approve-state.md"
                exit 0
            fi

            # Update active_bots in state file and continue with other bots
            echo "Continuing with remaining bots: ${NEW_ACTIVE_BOTS_AFTER_THUMBSUP[*]}" >&2
            PR_ACTIVE_BOTS_ARRAY=("${NEW_ACTIVE_BOTS_AFTER_THUMBSUP[@]}")

            # Update state file
            NEW_ACTIVE_BOTS_YAML=$(build_yaml_list "${PR_ACTIVE_BOTS_ARRAY[@]}")

            TEMP_FILE="${STATE_FILE}.thumbsup.$$"
            # Replace active_bots section in state file
            awk -v new_bots="$NEW_ACTIVE_BOTS_YAML" '
                /^active_bots:/ {
                    print "active_bots:" new_bots
                    in_bots=1
                    next
                }
                in_bots && /^[[:space:]]+-/ { next }
                in_bots && /^[a-zA-Z]/ { in_bots=0 }
                { print }
            ' "$STATE_FILE" > "$TEMP_FILE"
            mv "$TEMP_FILE" "$STATE_FILE"
        fi
    fi
fi

# ========================================
# Validate Trigger Comment Exists (Based on startup_case and round)
# ========================================

# Validate trigger FIRST, before Claude eyes check
# This ensures we don't waste time checking eyes on a stale trigger_comment_id

if [[ "$REQUIRE_TRIGGER" == "true" && -z "$PR_LAST_TRIGGER_AT" ]]; then
    # Determine startup case description for template
    STARTUP_CASE_DESC="requires trigger comment"
    case "${PR_STARTUP_CASE:-1}" in
        4) STARTUP_CASE_DESC="New commits after all bots reviewed" ;;
        5) STARTUP_CASE_DESC="New commits after partial bot reviews" ;;
        *) STARTUP_CASE_DESC="Subsequent round requires trigger" ;;
    esac

    FALLBACK_MSG="# Missing Trigger Comment

No @bot mention found. Please run: gh pr comment $PR_NUMBER --body \"$PR_BOT_MENTION_STRING please review\""
    REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/no-trigger-comment.md" "$FALLBACK_MSG" \
        "STARTUP_CASE=${PR_STARTUP_CASE:-1}" "STARTUP_CASE_DESC=$STARTUP_CASE_DESC" \
        "CURRENT_ROUND=$PR_CURRENT_ROUND" "BOT_MENTION_STRING=$PR_BOT_MENTION_STRING")

    jq -n --arg reason "$REASON" --arg msg "PR Loop: Missing trigger comment - please @mention bots first" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

# ========================================
# Claude Eyes Verification (AFTER trigger validation)
# ========================================

# Verify Claude eyes ONLY AFTER trigger is confirmed to exist
# This prevents checking eyes on a stale trigger_comment_id
# Conditions:
# 1. Claude is configured AND
# 2. A trigger is actually required (REQUIRE_TRIGGER=true) AND
# 3. A trigger comment ID exists (PR_TRIGGER_COMMENT_ID from confirmed detection above)

CLAUDE_CONFIGURED=false
for bot in "${PR_CONFIGURED_BOTS_ARRAY[@]}"; do
    if [[ "$bot" == "claude" ]]; then
        CLAUDE_CONFIGURED=true
        break
    fi
done

if [[ "$CLAUDE_CONFIGURED" == "true" && "$REQUIRE_TRIGGER" == "true" ]]; then
    # Use the confirmed trigger comment ID (updated by detect_trigger_comment above)
    TRIGGER_ID_TO_CHECK="${PR_TRIGGER_COMMENT_ID:-}"

    if [[ -n "$TRIGGER_ID_TO_CHECK" ]]; then
        echo "Verifying Claude eyes reaction on trigger comment (ID: $TRIGGER_ID_TO_CHECK)..." >&2

        # Check for eyes reaction with 3x5s retry
        # Pass --pr for fork PR support (reactions are on base repo)
        EYES_REACTION=$("$PLUGIN_ROOT/scripts/check-bot-reactions.sh" claude-eyes "$TRIGGER_ID_TO_CHECK" --pr "$PR_NUMBER" --retry 3 --delay 5 2>/dev/null) || EYES_REACTION=""

        if [[ -z "$EYES_REACTION" || "$EYES_REACTION" == "null" ]]; then
            # Claude eyes verification is BLOCKING - error after 3x5s retries
            FALLBACK_MSG="# Claude Bot Not Responding

The Claude bot did not respond with an 'eyes' reaction within 15 seconds (3 x 5s retries).
Please verify the Claude bot is installed and configured for this repository."
            REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/claude-eyes-timeout.md" "$FALLBACK_MSG" \
                "RETRY_COUNT=3" "TOTAL_WAIT_SECONDS=15")

            jq -n --arg reason "$REASON" --arg msg "PR Loop: Claude bot not responding - check bot configuration" \
                '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
            exit 0
        else
            echo "Claude eyes reaction confirmed!" >&2
        fi
    else
        # Trigger exists (PR_LAST_TRIGGER_AT is set) but no ID - should not happen normally
        echo "Warning: Trigger exists but no comment ID for eyes verification" >&2
    fi
elif [[ "$CLAUDE_CONFIGURED" == "true" ]]; then
    echo "Claude is configured but trigger not required (startup_case=${PR_STARTUP_CASE:-1}, round=$PR_CURRENT_ROUND) - skipping eyes verification" >&2
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

# Get timestamp for filtering based on startup_case and round
# - With trigger: use trigger timestamp (most accurate)
# - Round 0, Case 1: use started_at (waiting for new auto-reviews)
# - Round 0, Case 2/3: use epoch 0 to collect ALL existing comments
# - Round 0, Case 4/5: should have trigger (blocked above if missing)
AFTER_TIMESTAMP=""
USE_ALL_COMMENTS=false

if [[ -n "$PR_LAST_TRIGGER_AT" ]]; then
    # Always use trigger timestamp when available
    AFTER_TIMESTAMP="$PR_LAST_TRIGGER_AT"
    echo "Round $PR_CURRENT_ROUND: using trigger timestamp for --after: $AFTER_TIMESTAMP" >&2
elif [[ "$PR_CURRENT_ROUND" -eq 0 ]]; then
    case "${PR_STARTUP_CASE:-1}" in
        1)
            # Case 1: No comments yet - filter by started_at to wait for new reviews
            AFTER_TIMESTAMP="${PR_STARTED_AT}"
            echo "Round 0, Case 1: using started_at for --after: $AFTER_TIMESTAMP" >&2
            ;;
        2|3)
            # Case 2/3: Existing comments - collect ALL of them (no timestamp filter)
            USE_ALL_COMMENTS=true
            AFTER_TIMESTAMP="1970-01-01T00:00:00Z"  # Epoch 0 to include all comments
            echo "Round 0, Case ${PR_STARTUP_CASE}: collecting ALL existing bot comments" >&2
            ;;
        *)
            # Case 4/5 should have been blocked above, use started_at as fallback
            AFTER_TIMESTAMP="${PR_STARTED_AT}"
            echo "Round 0, Case ${PR_STARTUP_CASE}: using started_at for --after: $AFTER_TIMESTAMP" >&2
            ;;
    esac
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
# Special case: when USE_ALL_COMMENTS is true (startup cases 2/3), we're looking at
# ALL historical comments. In this case, anchor timeout to NOW (poll start time)
# rather than PR_STARTED_AT, which could be hours old and cause instant timeout.
if [[ "$USE_ALL_COMMENTS" == "true" ]]; then
    # Use current time as timeout anchor for historical comment review
    TRIGGER_EPOCH=$(date +%s)
else
    TRIGGER_EPOCH=$(date -d "$AFTER_TIMESTAMP" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$AFTER_TIMESTAMP" +%s 2>/dev/null || date +%s)
fi

# Track which bots have responded and their individual timeouts
# IMPORTANT: Poll ALL configured bots (not just active) so we can detect when
# previously approved bots post new issues and re-add them to active_bots
# IMPORTANT: Timeouts are anchored to TRIGGER_EPOCH, not poll start time
# This ensures the 15-minute window is measured from when the @mention was posted
#
# NOTE: Using dynamic variable names instead of associative arrays (declare -A)
# for macOS Bash 3.2 compatibility. Associative arrays require Bash 4.0+.
# Helper functions to get/set values:
_sanitize_key() { echo "$1" | tr -c 'a-zA-Z0-9_' '_'; }
_map_get() { local var="$1_$(_sanitize_key "$2")"; echo "${!var}"; }
_map_set() { local var="$1_$(_sanitize_key "$2")"; eval "$var=\"$3\""; }
_map_isset() { local var="$1_$(_sanitize_key "$2")"; [[ -n "${!var+x}" ]]; }

POLL_START_EPOCH=$(date +%s)
echo "Timeout anchor: trigger at epoch $TRIGGER_EPOCH (poll started at $POLL_START_EPOCH)" >&2
for bot in "${PR_CONFIGURED_BOTS_ARRAY[@]}"; do
    _map_set "BOTS_RESPONDED" "$bot" "false"
    _map_set "BOTS_TIMED_OUT" "$bot" "false"
    # Use TRIGGER_EPOCH for timeout, not poll start
    _map_set "BOTS_TIMEOUT_START" "$bot" "$TRIGGER_EPOCH"
done

# Collect all new comments with deduplication by id
# Using dynamic variables: SEEN_ID_<sanitized_id>=1
ALL_NEW_COMMENTS="[]"

while true; do
    CURRENT_TIME=$(date +%s)

    # Check if all configured bots have responded OR timed out (per-bot 15min timeout)
    ALL_DONE=true
    WAITING_BOTS=""
    TIMED_OUT_BOTS=""

    for bot in "${PR_CONFIGURED_BOTS_ARRAY[@]}"; do
        if [[ "$(_map_get BOTS_RESPONDED "$bot")" == "true" ]]; then
            continue  # Bot already responded
        fi

        # Check per-bot timeout (15 minutes each) - auto-remove after timeout
        BOT_ELAPSED=$((CURRENT_TIME - $(_map_get BOTS_TIMEOUT_START "$bot")))
        if [[ $BOT_ELAPSED -ge $PR_POLL_TIMEOUT ]]; then
            echo "Bot '$bot' timed out after ${PR_POLL_TIMEOUT}s - will be removed from active_bots" >&2
            _map_set "BOTS_TIMED_OUT" "$bot" "true"  # Mark as timed out for later removal
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
                if [[ "$(_map_get BOTS_RESPONDED "$bot")" != "true" ]]; then
                    _map_set "BOTS_RESPONDED" "$bot" "true"
                    echo "Bot '$bot' has responded!" >&2
                fi
            fi
        done
    done

    # Check for Codex +1 reaction during polling (any round)
    # Codex may give +1 instead of commenting if no issues found
    if [[ "$(_map_get BOTS_RESPONDED codex)" != "true" ]]; then
        # Check if codex is a configured bot
        CODEX_CONFIGURED=false
        for bot in "${PR_CONFIGURED_BOTS_ARRAY[@]}"; do
            [[ "$bot" == "codex" ]] && CODEX_CONFIGURED=true && break
        done

        if [[ "$CODEX_CONFIGURED" == "true" ]]; then
            # Determine timestamp for filtering - use trigger if available, else loop start
            POLL_REACTION_AFTER="${PR_LAST_TRIGGER_AT:-$PR_STARTED_AT}"

            # Check for +1 reaction
            THUMBSUP_RESULT=$("$PLUGIN_ROOT/scripts/check-bot-reactions.sh" codex-thumbsup "$PR_NUMBER" --after "$POLL_REACTION_AFTER" 2>/dev/null) || THUMBSUP_RESULT=""

            if [[ -n "$THUMBSUP_RESULT" && "$THUMBSUP_RESULT" != "null" ]]; then
                # +1 found - codex approved without issues
                echo "Codex +1 reaction detected during polling - treating as approval!" >&2
                _map_set "BOTS_RESPONDED" "codex" "true"

                # Remove codex from active_bots
                declare -a NEW_ACTIVE_BOTS_THUMBSUP=()
                for bot in "${PR_ACTIVE_BOTS_ARRAY[@]}"; do
                    if [[ "$bot" != "codex" ]]; then
                        NEW_ACTIVE_BOTS_THUMBSUP+=("$bot")
                    else
                        echo "Removing 'codex' from active_bots (approved via +1)" >&2
                    fi
                done
                PR_ACTIVE_BOTS_ARRAY=("${NEW_ACTIVE_BOTS_THUMBSUP[@]}")

                # Update active_bots in state file
                if [[ ${#PR_ACTIVE_BOTS_ARRAY[@]} -eq 0 ]]; then
                    echo "All bots have approved (codex via +1) - PR loop complete!" >&2
                    mv "$STATE_FILE" "$LOOP_DIR/approve-state.md"
                    exit 0
                else
                    # Update state file with remaining bots
                    ACTIVE_BOTS_YAML=$(build_yaml_list "${PR_ACTIVE_BOTS_ARRAY[@]}")
                    # Use awk to replace active_bots section (portable across GNU/BSD)
                    TEMP_FILE="${STATE_FILE}.thumbsup.$$"
                    awk -v bots="$ACTIVE_BOTS_YAML" '
                        /^active_bots:$/ {
                            print "active_bots:" bots
                            skip = 1
                            next
                        }
                        skip && /^[a-z_]+:/ { skip = 0 }
                        skip && /^  - / { next }
                        !skip { print }
                    ' "$STATE_FILE" > "$TEMP_FILE"
                    mv "$TEMP_FILE" "$STATE_FILE"
                fi
            fi
        fi
    fi

    # Collect new comments WITH DEDUPLICATION by comment id
    NEW_COMMENTS=$(echo "$POLL_RESULT" | jq -r '.comments' 2>/dev/null || echo "[]")
    if [[ "$NEW_COMMENTS" != "[]" && "$NEW_COMMENTS" != "null" ]]; then
        # Deduplicate: only add comments we haven't seen before
        UNIQUE_COMMENTS="[]"
        while IFS= read -r comment_json; do
            [[ -z "$comment_json" || "$comment_json" == "null" ]] && continue
            COMMENT_ID=$(echo "$comment_json" | jq -r '.id // empty')
            if [[ -n "$COMMENT_ID" ]] && ! _map_isset "SEEN_COMMENT_IDS" "$COMMENT_ID"; then
                _map_set "SEEN_COMMENT_IDS" "$COMMENT_ID" "1"
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
# Handle No Responses (auto-remove timed-out bots)
# ========================================

COMMENT_COUNT=$(echo "$ALL_NEW_COMMENTS" | jq 'length' 2>/dev/null || echo "0")

if [[ "$COMMENT_COUNT" == "0" ]]; then
    echo "No new bot reviews received." >&2

    # Always remove timed-out bots from active_bots (per-bot timeout behavior)
    # Don't wait for ALL bots to timeout - remove each bot as it times out
    TIMED_OUT_COUNT=0
    WAITING_COUNT=0
    declare -a NEW_ACTIVE_BOTS_TIMEOUT=()

    for bot in "${PR_ACTIVE_BOTS_ARRAY[@]}"; do
        if [[ "$(_map_get BOTS_TIMED_OUT "$bot")" == "true" ]]; then
            TIMED_OUT_COUNT=$((TIMED_OUT_COUNT + 1))
            echo "Removing '$bot' from active_bots (timed out after ${PR_POLL_TIMEOUT}s)" >&2
            # Don't add to NEW_ACTIVE_BOTS_TIMEOUT
        elif [[ "$(_map_get BOTS_RESPONDED "$bot")" != "true" ]]; then
            WAITING_COUNT=$((WAITING_COUNT + 1))
            NEW_ACTIVE_BOTS_TIMEOUT+=("$bot")
        else
            # Bot responded - keep in active (will be processed if comments come in)
            NEW_ACTIVE_BOTS_TIMEOUT+=("$bot")
        fi
    done

    # If any bots timed out, update the state file with remaining active bots
    if [[ $TIMED_OUT_COUNT -gt 0 ]]; then
        PR_ACTIVE_BOTS_ARRAY=("${NEW_ACTIVE_BOTS_TIMEOUT[@]}")

        # If no bots remain, loop is complete
        if [[ ${#PR_ACTIVE_BOTS_ARRAY[@]} -eq 0 ]]; then
            echo "All bots removed (timed out) - PR loop approved!" >&2
            # Build configured_bots YAML
            TIMEOUT_CONFIGURED_BOTS_YAML=$(build_yaml_list "${PR_CONFIGURED_BOTS_ARRAY[@]}")
            # Write updated state with empty active_bots before moving to approve-state.md
            {
                echo "---"
                echo "current_round: $PR_CURRENT_ROUND"
                echo "max_iterations: $PR_MAX_ITERATIONS"
                echo "pr_number: $PR_NUMBER"
                echo "start_branch: $PR_START_BRANCH"
                echo "configured_bots:${TIMEOUT_CONFIGURED_BOTS_YAML}"
                echo "active_bots:"
                echo "codex_model: $PR_CODEX_MODEL"
                echo "codex_effort: $PR_CODEX_EFFORT"
                echo "codex_timeout: $PR_CODEX_TIMEOUT"
                echo "poll_interval: $PR_POLL_INTERVAL"
                echo "poll_timeout: $PR_POLL_TIMEOUT"
                echo "started_at: $PR_STARTED_AT"
                echo "startup_case: ${PR_STARTUP_CASE:-1}"
                echo "latest_commit_sha: ${PR_LATEST_COMMIT_SHA:-}"
                echo "latest_commit_at: ${PR_LATEST_COMMIT_AT:-}"
                echo "last_trigger_at: ${PR_LAST_TRIGGER_AT:-}"
                echo "trigger_comment_id: ${PR_TRIGGER_COMMENT_ID:-}"
                echo "---"
            } > "$LOOP_DIR/approve-state.md"
            rm -f "$STATE_FILE"
            exit 0
        fi

        # Persist updated active_bots to state file (some bots timed out, others still waiting)
        echo "Updating state file with ${#PR_ACTIVE_BOTS_ARRAY[@]} remaining active bots" >&2
        TIMEOUT_ACTIVE_BOTS_YAML=$(build_yaml_list "${PR_ACTIVE_BOTS_ARRAY[@]}")
        TEMP_FILE="${STATE_FILE}.timeout.$$"
        awk -v bots="$TIMEOUT_ACTIVE_BOTS_YAML" '
            /^active_bots:$/ {
                print "active_bots:" bots
                skip = 1
                next
            }
            skip && /^[a-z_]+:/ { skip = 0 }
            skip && /^  - / { next }
            !skip { print }
        ' "$STATE_FILE" > "$TEMP_FILE"
        mv "$TEMP_FILE" "$STATE_FILE"
    fi

    # Build list of bots that didn't respond (only non-timed-out bots that are still waiting)
    MISSING_BOTS=""
    for bot in "${PR_ACTIVE_BOTS_ARRAY[@]}"; do
        if [[ "$(_map_get BOTS_RESPONDED "$bot")" != "true" ]]; then
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

# Load goal tracker update template (with fallback)
GOAL_TRACKER_FILE="$LOOP_DIR/goal-tracker.md"
GOAL_TRACKER_TEMPLATE_VARS=(
    "GOAL_TRACKER_FILE=$GOAL_TRACKER_FILE"
    "NEXT_ROUND=$NEXT_ROUND"
)
GOAL_TRACKER_UPDATE_FALLBACK="## Goal Tracker Update
After analysis, update the goal tracker at $GOAL_TRACKER_FILE with current status."

GOAL_TRACKER_UPDATE_INSTRUCTIONS=$(load_and_render_safe "$TEMPLATE_DIR" "pr-loop/codex-goal-tracker-update.md" "$GOAL_TRACKER_UPDATE_FALLBACK" "${GOAL_TRACKER_TEMPLATE_VARS[@]}")

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
- If any bot response indicates usage/rate limits hit (e.g., "usage limits", "rate limit", "quota exceeded"): End with "USAGE_LIMIT_HIT" on its own line

$GOAL_TRACKER_UPDATE_INSTRUCTIONS
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

# Determine automation flag based on environment variable
# Default: Use --full-auto (safe mode with sandbox)
# If HUMANIZE_CODEX_BYPASS_SANDBOX is "true" or "1": Use --dangerously-bypass-approvals-and-sandbox
CODEX_AUTO_FLAG="--full-auto"
if [[ "${HUMANIZE_CODEX_BYPASS_SANDBOX:-}" == "true" ]] || [[ "${HUMANIZE_CODEX_BYPASS_SANDBOX:-}" == "1" ]]; then
    CODEX_AUTO_FLAG="--dangerously-bypass-approvals-and-sandbox"
fi

CODEX_ARGS+=("$CODEX_AUTO_FLAG" "-C" "$PROJECT_ROOT")

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

# Use "APPROVE" marker to indicate all bots approved
if [[ "$LAST_LINE_TRIMMED" == "APPROVE" ]]; then
    echo "All bots have approved! PR loop complete." >&2

    # Update goal tracker BEFORE exit (idempotent - won't duplicate if Codex already updated)
    if [[ -f "$GOAL_TRACKER_FILE" ]]; then
        # For APPROVE, we record 0 new issues
        update_pr_goal_tracker "$GOAL_TRACKER_FILE" "$NEXT_ROUND" '{"issues": 0, "resolved": 0, "bot": "All"}' || true
    fi

    mv "$STATE_FILE" "$LOOP_DIR/approve-state.md"
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

# Handle USAGE_LIMIT_HIT - terminate loop gracefully (service limitation, not code issue)
if [[ "$LAST_LINE_TRIMMED" == "USAGE_LIMIT_HIT" ]]; then
    echo "Bot usage/rate limits detected. Terminating PR loop." >&2

    # Move state file to indicate usage limit termination
    mv "$STATE_FILE" "$LOOP_DIR/usage-limit-state.md"

    # Let exit proceed without blocking - the loop is over due to external limitation
    exit 0
fi

# ========================================
# Update active_bots in state file
# ========================================

# Extract approved bots from Codex output and remove them from active_bots
# Look for "### Approved Bots" section
# NOTE: Use awk for more robust extraction that handles:
#   - Section at end of file (no following ###)
#   - Section immediately followed by ### (empty section)
APPROVED_SECTION=$(awk '/^### Approved Bots/{found=1; next} found && /^###/{exit} found{print}' "$CHECK_FILE" || true)

# Extract bots with issues from Codex output (for re-add logic)
# Look for "### Per-Bot Status" table and find bots with ISSUES status
# NOTE: Use awk for more robust extraction
ISSUES_SECTION=$(awk '/^### Per-Bot Status/{found=1; next} found && /^###/{exit} found{print}' "$CHECK_FILE" || true)

# Build new active_bots array with re-add logic
# IMPORTANT: Process ALL configured bots, not just currently active ones
# This allows re-adding bots that were previously approved but now have new issues
declare -a NEW_ACTIVE_BOTS=()
# NOTE: Using _map_set/get instead of declare -A for macOS Bash 3.2 compatibility

# First, identify bots with issues from Codex output
while IFS= read -r line; do
    if echo "$line" | grep -qiE '\|[[:space:]]*ISSUES[[:space:]]*\|'; then
        # Extract bot name from table row: | botname | ISSUES | summary |
        BOT_WITH_ISSUE=$(echo "$line" | sed 's/|/\n/g' | sed -n '2p' | tr -d ' ')
        if [[ -n "$BOT_WITH_ISSUE" ]]; then
            _map_set "BOTS_WITH_ISSUES" "$BOT_WITH_ISSUE" "true"
        fi
    fi
    if echo "$line" | grep -qiE '\|[[:space:]]*APPROVE[[:space:]]*\|'; then
        # Extract bot name from table row: | botname | APPROVE | summary |
        BOT_APPROVED=$(echo "$line" | sed 's/|/\n/g' | sed -n '2p' | tr -d ' ')
        if [[ -n "$BOT_APPROVED" ]]; then
            _map_set "BOTS_APPROVED" "$BOT_APPROVED" "true"
        fi
    fi
done <<< "$ISSUES_SECTION"

# Process ALL configured bots (not just currently active)
# This allows re-adding previously approved bots if they post new issues
# Also handle timed-out bots by removing them from active_bots
for bot in "${PR_CONFIGURED_BOTS_ARRAY[@]}"; do
    # Check if bot timed out - remove from active_bots
    if [[ "$(_map_get BOTS_TIMED_OUT "$bot")" == "true" ]]; then
        echo "Removing '$bot' from active_bots (timed out after ${PR_POLL_TIMEOUT}s)" >&2
        continue  # Don't add to NEW_ACTIVE_BOTS
    fi

    if [[ "$(_map_get BOTS_WITH_ISSUES "$bot")" == "true" ]]; then
        # Bot has issues - add to active list
        if [[ "$(_map_get BOTS_APPROVED "$bot")" == "true" ]]; then
            echo "Bot '$bot' was previously approved but has new issues - re-adding to active" >&2
        else
            echo "Bot '$bot' has issues - keeping active" >&2
        fi
        NEW_ACTIVE_BOTS+=("$bot")
    elif [[ "$(_map_get BOTS_APPROVED "$bot")" == "true" ]]; then
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
NEW_ACTIVE_BOTS_YAML=$(build_yaml_list "${NEW_ACTIVE_BOTS[@]}")

# ========================================
# Update PR Goal Tracker
# ========================================
# Extract issue counts from Codex output and update goal tracker
# Count issues by looking at the Issues Found section
ISSUES_FOUND_COUNT=0
ISSUES_RESOLVED_COUNT=0

# Count issues in the "### Issues Found" section
if grep -q "### Issues Found" "$CHECK_FILE" 2>/dev/null; then
    # Count list items: numbered (1., 2.) or bullet (-, *) in Issues Found section
    # NOTE: Use awk for robust extraction (handles section at end of file)
    ISSUES_FOUND_COUNT=$(awk '/^### Issues Found/{found=1; next} found && /^###/{exit} found{print}' "$CHECK_FILE" \
        | grep -cE '^[0-9]+\.|^- |^\* ' 2>/dev/null || echo "0")
fi

# Count resolved issues: issues are only resolved when ALL bots approve
# NOTE: If we reach this point, not all bots have approved (full APPROVE case
# already triggered early exit above), so issues found in this round are NOT
# resolved yet. Setting resolved=0 prevents inflating the resolved count when
# only some bots approve while others report issues.
# ISSUES_RESOLVED_COUNT stays 0 - issues will be marked resolved in a future
# round when all bots approve and the early exit path records the resolution.

# Call update_pr_goal_tracker if goal tracker exists
if [[ -f "$GOAL_TRACKER_FILE" ]]; then
    # NOTE: Use lowercase "codex" to match configured bot names and avoid duplicate rows
    # (Codex itself writes rows with lowercase names in goal tracker)
    BOT_RESULTS_JSON="{\"bot\": \"codex\", \"issues\": $ISSUES_FOUND_COUNT, \"resolved\": $ISSUES_RESOLVED_COUNT}"
    update_pr_goal_tracker "$GOAL_TRACKER_FILE" "$NEXT_ROUND" "$BOT_RESULTS_JSON" || true
fi

# Build YAML list for configured_bots (never changes)
CONFIGURED_BOTS_YAML=$(build_yaml_list "${PR_CONFIGURED_BOTS_ARRAY[@]}")

# Update latest_commit_sha to current HEAD (for force push detection in next round)
NEW_LATEST_COMMIT_SHA=$(run_with_timeout "$GIT_TIMEOUT" git rev-parse HEAD 2>/dev/null) || NEW_LATEST_COMMIT_SHA="$PR_LATEST_COMMIT_SHA"
# NOTE: Sort by committedDate before selecting last - API order is not guaranteed
# NOTE: Uses PR_LOOKUP_REPO for fork PR support
NEW_LATEST_COMMIT_AT=$(run_with_timeout "$GH_TIMEOUT" gh pr view "$PR_NUMBER" --repo "$PR_LOOKUP_REPO" --json commits \
    --jq '.commits | sort_by(.committedDate) | last | .committedDate' 2>/dev/null) || NEW_LATEST_COMMIT_AT="$PR_LATEST_COMMIT_AT"

# Re-evaluate startup_case dynamically
# This allows case to change as bot comments arrive
BOTS_COMMA_LIST=$(IFS=','; echo "${PR_CONFIGURED_BOTS_ARRAY[*]}")
NEW_REVIEWER_STATUS=$("$PLUGIN_ROOT/scripts/check-pr-reviewer-status.sh" "$PR_NUMBER" --bots "$BOTS_COMMA_LIST" 2>/dev/null) || NEW_REVIEWER_STATUS=""
if [[ -n "$NEW_REVIEWER_STATUS" ]]; then
    NEW_STARTUP_CASE=$(echo "$NEW_REVIEWER_STATUS" | jq -r '.case')
    if [[ -n "$NEW_STARTUP_CASE" && "$NEW_STARTUP_CASE" != "null" ]]; then
        if [[ "$NEW_STARTUP_CASE" != "${PR_STARTUP_CASE:-1}" ]]; then
            echo "Startup case changed: ${PR_STARTUP_CASE:-1} -> $NEW_STARTUP_CASE" >&2
        fi
        PR_STARTUP_CASE="$NEW_STARTUP_CASE"
    fi
fi

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
    echo "startup_case: ${PR_STARTUP_CASE:-1}"
    echo "latest_commit_sha: $NEW_LATEST_COMMIT_SHA"
    echo "latest_commit_at: ${NEW_LATEST_COMMIT_AT:-}"
    echo "last_trigger_at:"
    echo "trigger_comment_id: ${PR_TRIGGER_COMMENT_ID:-}"
    echo "---"
} > "$TEMP_FILE"
mv "$TEMP_FILE" "$STATE_FILE"

# Check if all bots are now approved
if [[ ${#NEW_ACTIVE_BOTS[@]} -eq 0 ]]; then
    echo "All bots have now approved! PR loop complete." >&2
    mv "$STATE_FILE" "$LOOP_DIR/approve-state.md"
    exit 0
fi

# ========================================
# Issues Remaining - Continue Loop
# ========================================

# Build new bot mention string
NEW_BOT_MENTION_STRING=$(build_bot_mention_string "${NEW_ACTIVE_BOTS[@]}")

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
