#!/bin/bash
#
# Poll for new PR reviews from specified bots
#
# Checks for new comments from specified bots after a given timestamp.
#
# Usage:
#   poll-pr-reviews.sh <pr_number> --after <timestamp> --bots <bot1,bot2>
#
# Output: JSON with new comments from the bots, or empty array if none
#

set -euo pipefail

# ========================================
# Parse Arguments
# ========================================

PR_NUMBER=""
AFTER_TIMESTAMP=""
BOTS=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --after)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --after requires a timestamp argument" >&2
                exit 1
            fi
            AFTER_TIMESTAMP="$2"
            shift 2
            ;;
        --bots)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --bots requires a comma-separated list of bot names" >&2
                exit 1
            fi
            BOTS="$2"
            shift 2
            ;;
        -h|--help)
            cat << 'HELP_EOF'
poll-pr-reviews.sh - Poll for new PR reviews from bots

USAGE:
  poll-pr-reviews.sh <pr_number> --after <timestamp> --bots <bot1,bot2>

ARGUMENTS:
  <pr_number>     The PR number to poll

OPTIONS:
  --after <timestamp>   Only return comments after this ISO 8601 timestamp
  --bots <bot1,bot2>    Comma-separated list of bot names to watch
  -h, --help            Show this help message

OUTPUT:
  JSON object with:
  - comments: Array of new comments from watched bots
  - bots_responded: Array of bot names that have new comments
  - has_new_comments: Boolean indicating if any new comments found

EXAMPLE:
  poll-pr-reviews.sh 123 --after 2026-01-18T12:00:00Z --bots claude,codex
HELP_EOF
            exit 0
            ;;
        -*)
            echo "Error: Unknown option: $1" >&2
            exit 1
            ;;
        *)
            if [[ -z "$PR_NUMBER" ]]; then
                PR_NUMBER="$1"
            else
                echo "Error: Unexpected argument: $1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate arguments
if [[ -z "$PR_NUMBER" ]]; then
    echo "Error: PR number is required" >&2
    exit 1
fi

if [[ -z "$AFTER_TIMESTAMP" ]]; then
    echo "Error: --after timestamp is required" >&2
    exit 1
fi

if [[ -z "$BOTS" ]]; then
    echo "Error: --bots list is required" >&2
    exit 1
fi

if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "Error: Invalid PR number: $PR_NUMBER" >&2
    exit 1
fi

# ========================================
# Check Prerequisites
# ========================================

if ! command -v gh &>/dev/null; then
    echo "Error: GitHub CLI (gh) is required" >&2
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "Error: jq is required for JSON parsing" >&2
    exit 1
fi

# ========================================
# Get Repository Info
# ========================================

# IMPORTANT: For fork PRs, we need to resolve the base (upstream) repository
# gh pr view without --repo fails in forks because the PR number doesn't exist there
# Strategy: First get current repo, then try to get PR's base repo with --repo flag

# Step 1: Get the current repo (works in both forks and base repos)
CURRENT_REPO=$(gh repo view --json owner,name -q '.owner.login + "/" + .name' 2>/dev/null) || {
    echo "Error: Failed to get current repository" >&2
    exit 1
}

# Step 2: Determine the correct repo for PR operations
# Try current repo first - if PR exists there, use it
PR_BASE_REPO=""
if gh pr view "$PR_NUMBER" --repo "$CURRENT_REPO" --json number -q .number >/dev/null 2>&1; then
    PR_BASE_REPO="$CURRENT_REPO"
else
    # PR not found in current repo - check if this is a fork and try parent repo
    PARENT_REPO=$(gh repo view --json parent -q '.parent.owner.login + "/" + .parent.name' 2>/dev/null) || PARENT_REPO=""
    if [[ -n "$PARENT_REPO" && "$PARENT_REPO" != "null/" && "$PARENT_REPO" != "/" ]]; then
        if gh pr view "$PR_NUMBER" --repo "$PARENT_REPO" --json number -q .number >/dev/null 2>&1; then
            PR_BASE_REPO="$PARENT_REPO"
        fi
    fi
fi

if [[ -z "$PR_BASE_REPO" ]]; then
    echo "Error: Failed to find PR #$PR_NUMBER in current or parent repository" >&2
    exit 1
fi

REPO_OWNER="${PR_BASE_REPO%%/*}"
REPO_NAME="${PR_BASE_REPO##*/}"

if [[ -z "$REPO_OWNER" || -z "$REPO_NAME" ]]; then
    echo "Error: Could not parse repository owner/name from: $PR_BASE_REPO" >&2
    exit 1
fi

# ========================================
# Build Bot Filter
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

# Convert comma-separated bots to jq filter pattern
BOT_PATTERNS=""
IFS=',' read -ra BOT_ARRAY <<< "$BOTS"
for bot in "${BOT_ARRAY[@]}"; do
    bot=$(echo "$bot" | tr -d ' ')
    author=$(map_bot_to_author "$bot")
    if [[ -n "$BOT_PATTERNS" ]]; then
        BOT_PATTERNS="$BOT_PATTERNS|"
    fi
    # Escape brackets for regex
    BOT_PATTERNS="${BOT_PATTERNS}${author//\[/\\[}"
    BOT_PATTERNS="${BOT_PATTERNS//\]/\\]}"
done

# ========================================
# Fetch and Filter Comments
# ========================================

# Create temporary files
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

ALL_COMMENTS_FILE="$TEMP_DIR/all_comments.json"
FILTERED_FILE="$TEMP_DIR/filtered.json"

# Retry configuration
MAX_RETRIES=3
RETRY_DELAY=2

# Track API failures (for diagnostics, not script termination)
API_FAILURES=0

# Function to fetch with retries
# Returns 0 even on failure to prevent script termination under set -euo pipefail
# On failure, outputs empty array "[]" so jq processing continues gracefully
fetch_with_retry() {
    local endpoint="$1"
    local attempt=1
    local result=""

    while [[ $attempt -le $MAX_RETRIES ]]; do
        result=$(gh api "$endpoint" --paginate 2>/dev/null) && {
            echo "$result"
            return 0
        }

        if [[ $attempt -lt $MAX_RETRIES ]]; then
            echo "Warning: API fetch failed (attempt $attempt/$MAX_RETRIES), retrying..." >&2
            sleep "$RETRY_DELAY"
        else
            echo "Warning: API fetch failed after $MAX_RETRIES attempts for $endpoint" >&2
            API_FAILURES=$((API_FAILURES + 1))
        fi
        ((attempt++))
    done

    # Return empty array and success (0) to allow polling to continue
    # Partial API outages shouldn't terminate the entire poll loop
    echo "[]"
    return 0
}

# Initialize empty array
echo "[]" > "$ALL_COMMENTS_FILE"

# Fetch issue comments
ISSUE_COMMENTS=$(fetch_with_retry "repos/$REPO_OWNER/$REPO_NAME/issues/$PR_NUMBER/comments")
echo "$ISSUE_COMMENTS" | jq -r --arg type "issue_comment" '
    if type == "array" then
        [.[] | {
            type: $type,
            id: .id,
            author: .user.login,
            author_type: .user.type,
            created_at: .created_at,
            body: .body
        }]
    else
        []
    end
' > "$TEMP_DIR/issue.json"

# Fetch review comments
REVIEW_COMMENTS=$(fetch_with_retry "repos/$REPO_OWNER/$REPO_NAME/pulls/$PR_NUMBER/comments")
echo "$REVIEW_COMMENTS" | jq -r --arg type "review_comment" '
    if type == "array" then
        [.[] | {
            type: $type,
            id: .id,
            author: .user.login,
            author_type: .user.type,
            created_at: .created_at,
            body: .body,
            path: .path,
            line: (.line // .original_line)
        }]
    else
        []
    end
' > "$TEMP_DIR/review.json"

# Fetch PR reviews
# Note: Include all reviews, even those with empty body (e.g. approval-only reviews)
# For empty body reviews, use a placeholder indicating the state
PR_REVIEWS=$(fetch_with_retry "repos/$REPO_OWNER/$REPO_NAME/pulls/$PR_NUMBER/reviews")
echo "$PR_REVIEWS" | jq -r --arg type "pr_review" '
    if type == "array" then
        [.[] | {
            type: $type,
            id: .id,
            author: .user.login,
            author_type: .user.type,
            created_at: .submitted_at,
            body: (if .body == null or .body == "" then "[Review state: \(.state)]" else .body end),
            state: .state
        }]
    else
        []
    end
' > "$TEMP_DIR/reviews.json"

# Combine all comments
jq -s 'add' "$TEMP_DIR/issue.json" "$TEMP_DIR/review.json" "$TEMP_DIR/reviews.json" > "$ALL_COMMENTS_FILE"

# Filter: after timestamp AND from watched bots
jq --arg after "$AFTER_TIMESTAMP" --arg pattern "$BOT_PATTERNS" '
    [.[] | select(
        .created_at >= $after and
        (.author | test($pattern; "i"))
    )]
' "$ALL_COMMENTS_FILE" > "$FILTERED_FILE"

# ========================================
# Build Output
# ========================================

COMMENT_COUNT=$(jq 'length' "$FILTERED_FILE")

# Get list of bots that responded
BOTS_RESPONDED=$(jq -r '[.[] | .author] | unique | join(",")' "$FILTERED_FILE")

# Build final output
jq -n \
    --argjson comments "$(cat "$FILTERED_FILE")" \
    --arg bots_responded "$BOTS_RESPONDED" \
    --argjson has_new $(if [[ "$COMMENT_COUNT" -gt 0 ]]; then echo "true"; else echo "false"; fi) \
    '{
        comments: $comments,
        bots_responded: ($bots_responded | split(",") | map(select(length > 0))),
        has_new_comments: $has_new,
        comment_count: ($comments | length)
    }'

exit 0
