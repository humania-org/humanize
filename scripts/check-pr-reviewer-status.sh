#!/bin/bash
#
# Check PR reviewer status for startup case determination
#
# Analyzes reviewer comments on ENTIRE PR (not just after latest commit)
# to determine which startup case applies.
#
# Usage:
#   check-pr-reviewer-status.sh <pr_number> --bots <bot1,bot2>
#
# Output (JSON):
#   {
#     "case": 1-5,
#     "reviewers_commented": ["claude"],
#     "reviewers_missing": ["codex"],
#     "latest_commit_sha": "abc123",
#     "latest_commit_at": "2026-01-18T12:00:00Z",
#     "newest_review_at": "2026-01-18T11:00:00Z",
#     "has_commits_after_reviews": true
#   }
#
# Cases:
#   1 - No reviewer comments at all
#   2 - Some (not all) reviewers commented
#   3 - All reviewers commented, no new commits after
#   4 - All reviewers commented, new commits after (needs re-review)
#   5 - All reviewers commented, new commits after (like case 4, for future distinction)

set -euo pipefail

# ========================================
# Default Configuration
# ========================================

# Timeout for gh operations
GH_TIMEOUT=60

# Source portable timeout wrapper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/portable-timeout.sh"

# ========================================
# Parse Arguments
# ========================================

PR_NUMBER=""
BOT_LIST=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --bots)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --bots requires a comma-separated list of bot names" >&2
                exit 1
            fi
            BOT_LIST="$2"
            shift 2
            ;;
        -*)
            echo "Error: Unknown option: $1" >&2
            exit 1
            ;;
        *)
            if [[ -z "$PR_NUMBER" ]]; then
                PR_NUMBER="$1"
            else
                echo "Error: Multiple PR numbers specified" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$PR_NUMBER" ]]; then
    echo "Error: PR number is required" >&2
    echo "Usage: check-pr-reviewer-status.sh <pr_number> --bots <bot1,bot2>" >&2
    exit 1
fi

if [[ -z "$BOT_LIST" ]]; then
    echo "Error: --bots is required" >&2
    echo "Usage: check-pr-reviewer-status.sh <pr_number> --bots <bot1,bot2>" >&2
    exit 1
fi

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

# ========================================
# Fetch PR Data
# ========================================

# Parse bot list into array
IFS=',' read -ra BOTS <<< "$BOT_LIST"

# IMPORTANT: For fork PRs, we need to resolve the base (upstream) repository
# gh pr view without --repo fails in forks because the PR number doesn't exist there
# Strategy: First get current repo, check if PR exists there, then try parent repo for forks

# Step 1: Get the current repo (works in both forks and base repos)
CURRENT_REPO=$(run_with_timeout "$GH_TIMEOUT" gh repo view --json owner,name \
    -q '.owner.login + "/" + .name' 2>/dev/null) || CURRENT_REPO=""

# Step 2: Determine the correct repo for PR operations
# Try current repo first - if PR exists there, use it
PR_BASE_REPO=""
if [[ -n "$CURRENT_REPO" ]]; then
    if run_with_timeout "$GH_TIMEOUT" gh pr view "$PR_NUMBER" --repo "$CURRENT_REPO" --json number -q .number >/dev/null 2>&1; then
        PR_BASE_REPO="$CURRENT_REPO"
    fi
fi

if [[ -z "$PR_BASE_REPO" ]]; then
    # PR not found in current repo - check if this is a fork and try parent repo
    PARENT_REPO=$(run_with_timeout "$GH_TIMEOUT" gh repo view --json parent \
        -q '.parent.owner.login + "/" + .parent.name' 2>/dev/null) || PARENT_REPO=""
    if [[ -n "$PARENT_REPO" && "$PARENT_REPO" != "null/" && "$PARENT_REPO" != "/" ]]; then
        if run_with_timeout "$GH_TIMEOUT" gh pr view "$PR_NUMBER" --repo "$PARENT_REPO" --json number -q .number >/dev/null 2>&1; then
            PR_BASE_REPO="$PARENT_REPO"
        fi
    fi
fi

if [[ -z "$PR_BASE_REPO" ]]; then
    echo "Warning: Could not resolve PR base repository, using current repo" >&2
    PR_BASE_REPO="$CURRENT_REPO"
fi

# Get latest commit info (use --repo for fork support)
COMMIT_INFO=$(run_with_timeout "$GH_TIMEOUT" gh pr view "$PR_NUMBER" --repo "$PR_BASE_REPO" \
    --json headRefOid,commits \
    --jq '{sha: .headRefOid, date: (.commits | sort_by(.committedDate) | last | .committedDate)}' 2>/dev/null) || {
    echo "Error: Failed to fetch PR commit info" >&2
    exit 1
}

LATEST_COMMIT_SHA=$(echo "$COMMIT_INFO" | jq -r '.sha')
LATEST_COMMIT_AT=$(echo "$COMMIT_INFO" | jq -r '.date')

# Fetch all comments (issue comments, review comments, and PR review submissions)
# Using --paginate to handle PRs with many comments
# IMPORTANT: Use PR_BASE_REPO for fork PR support
ISSUE_COMMENTS=$(run_with_timeout "$GH_TIMEOUT" gh api "repos/$PR_BASE_REPO/issues/$PR_NUMBER/comments" \
    --paginate --jq '[.[] | {author: .user.login, created_at: .created_at, body: .body}]' 2>/dev/null) || ISSUE_COMMENTS="[]"

REVIEW_COMMENTS=$(run_with_timeout "$GH_TIMEOUT" gh api "repos/$PR_BASE_REPO/pulls/$PR_NUMBER/comments" \
    --paginate --jq '[.[] | {author: .user.login, created_at: .created_at, body: .body}]' 2>/dev/null) || REVIEW_COMMENTS="[]"

# Also fetch PR review submissions (APPROVE, REQUEST_CHANGES, COMMENT reviews)
# These are different from inline review comments and may be the only feedback from some bots
PR_REVIEWS=$(run_with_timeout "$GH_TIMEOUT" gh api "repos/$PR_BASE_REPO/pulls/$PR_NUMBER/reviews" \
    --paginate --jq '[.[] | {author: .user.login, created_at: .submitted_at, body: .body, state: .state}]' 2>/dev/null) || PR_REVIEWS="[]"

# Combine all comments and reviews
ALL_COMMENTS=$(echo "$ISSUE_COMMENTS $REVIEW_COMMENTS $PR_REVIEWS" | jq -s 'add // []')

# ========================================
# Analyze Comments by Bot
# ========================================

declare -a REVIEWERS_COMMENTED=()
declare -a REVIEWERS_MISSING=()
declare -a REVIEWERS_STALE=()  # Bots whose latest review is before latest commit
NEWEST_REVIEW_AT=""

for bot in "${BOTS[@]}"; do
    author=$(map_bot_to_author "$bot")

    # Check if this bot has any comments
    BOT_COMMENTS=$(echo "$ALL_COMMENTS" | jq --arg author "$author" '[.[] | select(.author == $author)]')
    BOT_COUNT=$(echo "$BOT_COMMENTS" | jq 'length')

    if [[ "$BOT_COUNT" -gt 0 ]]; then
        REVIEWERS_COMMENTED+=("$bot")

        # Track this bot's newest review timestamp
        BOT_NEWEST=$(echo "$BOT_COMMENTS" | jq -r 'sort_by(.created_at) | reverse | .[0].created_at')

        # Check if this bot's review is stale (before latest commit)
        # This is per-bot, not global - a bot's review can be stale even if another bot reviewed later
        if [[ -n "$LATEST_COMMIT_AT" && -n "$BOT_NEWEST" && "$LATEST_COMMIT_AT" > "$BOT_NEWEST" ]]; then
            REVIEWERS_STALE+=("$bot")
        fi

        # Track global newest for output (still useful for debugging)
        if [[ -z "$NEWEST_REVIEW_AT" ]] || [[ "$BOT_NEWEST" > "$NEWEST_REVIEW_AT" ]]; then
            NEWEST_REVIEW_AT="$BOT_NEWEST"
        fi
    else
        REVIEWERS_MISSING+=("$bot")
    fi
done

# ========================================
# Determine Case
# ========================================

CASE=0
HAS_COMMITS_AFTER_REVIEWS=false

# Count how many bots have commented
COMMENTED_COUNT=${#REVIEWERS_COMMENTED[@]}
MISSING_COUNT=${#REVIEWERS_MISSING[@]}
STALE_COUNT=${#REVIEWERS_STALE[@]}
TOTAL_BOTS=${#BOTS[@]}

if [[ $COMMENTED_COUNT -eq 0 ]]; then
    # Case 1: No reviewer comments at all
    CASE=1
elif [[ $MISSING_COUNT -gt 0 ]]; then
    # Some (not all) reviewers commented
    # Check if ANY bot that commented has a stale review (per-bot check)
    if [[ $STALE_COUNT -gt 0 ]]; then
        # Case 5: Some reviewers commented, but at least one has stale review
        HAS_COMMITS_AFTER_REVIEWS=true
        CASE=5
    else
        # Case 2: Some reviewers commented, all reviews are fresh
        CASE=2
    fi
else
    # All reviewers have commented
    # Check if ANY bot has a stale review (per-bot check, not global newest)
    if [[ $STALE_COUNT -gt 0 ]]; then
        # Case 4: All reviewers commented, but at least one has stale review
        HAS_COMMITS_AFTER_REVIEWS=true
        CASE=4
    else
        # Case 3: All commented, all reviews are fresh
        CASE=3
    fi
fi

# ========================================
# Output JSON
# ========================================

# Build JSON arrays
COMMENTED_JSON=$(printf '%s\n' "${REVIEWERS_COMMENTED[@]}" | jq -R . | jq -s .)
MISSING_JSON=$(printf '%s\n' "${REVIEWERS_MISSING[@]}" | jq -R . | jq -s .)

# Handle empty arrays
[[ ${#REVIEWERS_COMMENTED[@]} -eq 0 ]] && COMMENTED_JSON="[]"
[[ ${#REVIEWERS_MISSING[@]} -eq 0 ]] && MISSING_JSON="[]"

jq -n \
    --argjson case "$CASE" \
    --argjson reviewers_commented "$COMMENTED_JSON" \
    --argjson reviewers_missing "$MISSING_JSON" \
    --arg latest_commit_sha "$LATEST_COMMIT_SHA" \
    --arg latest_commit_at "$LATEST_COMMIT_AT" \
    --arg newest_review_at "${NEWEST_REVIEW_AT:-null}" \
    --argjson has_commits_after_reviews "$HAS_COMMITS_AFTER_REVIEWS" \
    '{
        case: $case,
        reviewers_commented: $reviewers_commented,
        reviewers_missing: $reviewers_missing,
        latest_commit_sha: $latest_commit_sha,
        latest_commit_at: $latest_commit_at,
        newest_review_at: (if $newest_review_at == "null" then null else $newest_review_at end),
        has_commits_after_reviews: $has_commits_after_reviews
    }'
