#!/bin/bash
#
# Setup script for start-pr-loop
#
# Creates state files for the PR loop that monitors GitHub PR reviews from bots.
#
# Usage:
#   setup-pr-loop.sh --claude|--codex [--max N] [--codex-model MODEL:EFFORT] [--codex-timeout SECONDS]
#

set -euo pipefail

# ========================================
# Default Configuration
# ========================================

# Default Codex model and reasoning effort (different from RLCR - uses medium instead of high)
DEFAULT_CODEX_MODEL="gpt-5.2-codex"
DEFAULT_CODEX_EFFORT="medium"
DEFAULT_CODEX_TIMEOUT=900
DEFAULT_MAX_ITERATIONS=42

# Polling configuration
POLL_INTERVAL=30
POLL_TIMEOUT=900  # 15 minutes per bot

# Default timeout for git operations (30 seconds)
GIT_TIMEOUT=30

# Default timeout for GitHub CLI operations (60 seconds)
GH_TIMEOUT=60

# Source portable timeout wrapper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/portable-timeout.sh"

# Source template loader
HOOKS_LIB_DIR="$(cd "$SCRIPT_DIR/../hooks/lib" && pwd)"
source "$HOOKS_LIB_DIR/template-loader.sh"

# Initialize template directory
TEMPLATE_DIR="${TEMPLATE_DIR:-$(get_template_dir "$HOOKS_LIB_DIR")}"

# ========================================
# Parse Arguments
# ========================================

MAX_ITERATIONS="$DEFAULT_MAX_ITERATIONS"
CODEX_MODEL="$DEFAULT_CODEX_MODEL"
CODEX_EFFORT="$DEFAULT_CODEX_EFFORT"
CODEX_TIMEOUT="$DEFAULT_CODEX_TIMEOUT"

# Bot flags
BOT_CLAUDE="false"
BOT_CODEX="false"

show_help() {
    cat << 'HELP_EOF'
start-pr-loop - PR review loop with remote bot monitoring

USAGE:
  /humanize:start-pr-loop --claude|--codex [OPTIONS]

BOT FLAGS (at least one required):
  --claude   Monitor reviews from claude[bot] (trigger: @claude)
  --codex    Monitor reviews from chatgpt-codex-connector[bot] (trigger: @codex)

OPTIONS:
  --max <N>            Maximum iterations before auto-stop (default: 42)
  --codex-model <MODEL:EFFORT>
                       Codex model and reasoning effort (default: gpt-5.2-codex:medium)
  --codex-timeout <SECONDS>
                       Timeout for each Codex review in seconds (default: 900)
  -h, --help           Show this help message

DESCRIPTION:
  Starts a PR review loop that:

  1. Detects the PR associated with the current branch
  2. Fetches review comments from the specified bot(s)
  3. Analyzes and fixes issues identified by the bot(s)
  4. Pushes changes and triggers re-review by commenting @bot
  5. Waits for bot response (polls every 30s, 15min timeout)
  6. Uses local Codex to verify if remote concerns are valid

  The flow:
  1. Claude analyzes PR comments and fixes issues
  2. Claude pushes changes and comments @bot on PR
  3. Stop Hook polls for new bot reviews
  4. When reviews arrive, local Codex validates them
  5. If issues found, Claude continues fixing
  6. If all bots approve, loop ends

EXAMPLES:
  /humanize:start-pr-loop --claude
  /humanize:start-pr-loop --codex --max 20
  /humanize:start-pr-loop --claude --codex

STOPPING:
  - /humanize:cancel-pr-loop   Cancel the active PR loop
  - Reach --max iterations
  - All bots approve the changes

MONITORING:
  humanize monitor pr
HELP_EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            ;;
        --claude)
            BOT_CLAUDE="true"
            shift
            ;;
        --codex)
            BOT_CODEX="true"
            shift
            ;;
        --max)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --max requires a number argument" >&2
                exit 1
            fi
            if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --max must be a positive integer, got: $2" >&2
                exit 1
            fi
            MAX_ITERATIONS="$2"
            shift 2
            ;;
        --codex-model)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --codex-model requires a MODEL:EFFORT argument" >&2
                exit 1
            fi
            # Parse MODEL:EFFORT format (portable - works in bash and zsh)
            if [[ "$2" == *:* ]]; then
                CODEX_MODEL="${2%%:*}"
                CODEX_EFFORT="${2#*:}"
            else
                CODEX_MODEL="$2"
                CODEX_EFFORT="$DEFAULT_CODEX_EFFORT"
            fi
            shift 2
            ;;
        --codex-timeout)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --codex-timeout requires a number argument (seconds)" >&2
                exit 1
            fi
            if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --codex-timeout must be a positive integer (seconds), got: $2" >&2
                exit 1
            fi
            CODEX_TIMEOUT="$2"
            shift 2
            ;;
        -*)
            echo "Error: Unknown option: $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
        *)
            echo "Error: Unexpected argument: $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
    esac
done

# ========================================
# Validate Bot Flags
# ========================================

if [[ "$BOT_CLAUDE" != "true" && "$BOT_CODEX" != "true" ]]; then
    echo "Error: At least one bot flag is required" >&2
    echo "" >&2
    echo "Usage: /humanize:start-pr-loop --claude|--codex [OPTIONS]" >&2
    echo "" >&2
    echo "Bot flags:" >&2
    echo "  --claude   Monitor reviews from claude[bot] (trigger: @claude)" >&2
    echo "  --codex    Monitor reviews from chatgpt-codex-connector[bot] (trigger: @codex)" >&2
    echo "" >&2
    echo "For help: /humanize:start-pr-loop --help" >&2
    exit 1
fi

# Build active_bots list (stored as array for YAML list format)
# Bot names stored in state: claude, codex
# Trigger mentions: @claude, @codex
# Comment authors: claude[bot], chatgpt-codex-connector[bot]
declare -a ACTIVE_BOTS_ARRAY=()
if [[ "$BOT_CLAUDE" == "true" ]]; then
    ACTIVE_BOTS_ARRAY+=("claude")
fi
if [[ "$BOT_CODEX" == "true" ]]; then
    ACTIVE_BOTS_ARRAY+=("codex")
fi

# ========================================
# Validate Prerequisites
# ========================================

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Source loop-common.sh for find_active_loop, find_active_pr_loop, and helper functions
source "$HOOKS_LIB_DIR/loop-common.sh"

# Build dynamic mention string from active bots (using shared helper)
BOT_MENTION_STRING=$(build_bot_mention_string "${ACTIVE_BOTS_ARRAY[@]}")

# ========================================
# Mutual Exclusion Check
# ========================================

# Check for existing active loops (both RLCR and PR loops)
# Only one loop type can be active at a time
RLCR_LOOP_DIR=$(find_active_loop "$PROJECT_ROOT/.humanize/rlcr" 2>/dev/null || echo "")
PR_LOOP_DIR=$(find_active_pr_loop "$PROJECT_ROOT/.humanize/pr-loop" 2>/dev/null || echo "")

if [[ -n "$RLCR_LOOP_DIR" ]]; then
    echo "Error: An RLCR loop is already active" >&2
    echo "  Active loop: $RLCR_LOOP_DIR" >&2
    echo "" >&2
    echo "Only one loop can be active at a time." >&2
    echo "Cancel the RLCR loop first with: /humanize:cancel-rlcr-loop" >&2
    exit 1
fi

if [[ -n "$PR_LOOP_DIR" ]]; then
    echo "Error: A PR loop is already active" >&2
    echo "  Active loop: $PR_LOOP_DIR" >&2
    echo "" >&2
    echo "Only one loop can be active at a time." >&2
    echo "Cancel the PR loop first with: /humanize:cancel-pr-loop" >&2
    exit 1
fi

# Check git repo (with timeout)
if ! run_with_timeout "$GIT_TIMEOUT" git rev-parse --git-dir &>/dev/null; then
    echo "Error: Project must be a git repository (or git command timed out)" >&2
    exit 1
fi

# Check at least one commit (with timeout)
if ! run_with_timeout "$GIT_TIMEOUT" git rev-parse HEAD &>/dev/null 2>&1; then
    echo "Error: Git repository must have at least one commit (or git command timed out)" >&2
    exit 1
fi

# Check gh CLI is installed
if ! command -v gh &>/dev/null; then
    echo "Error: start-pr-loop requires the GitHub CLI (gh) to be installed" >&2
    echo "" >&2
    echo "Please install the GitHub CLI: https://cli.github.com/" >&2
    exit 1
fi

# Check gh CLI is authenticated
if ! gh auth status &>/dev/null 2>&1; then
    echo "Error: GitHub CLI is not authenticated" >&2
    echo "" >&2
    echo "Please run: gh auth login" >&2
    exit 1
fi

# Check codex is available
if ! command -v codex &>/dev/null; then
    echo "Error: start-pr-loop requires codex to run" >&2
    echo "" >&2
    echo "Please install Codex CLI: https://openai.com/codex" >&2
    exit 1
fi

# ========================================
# Detect PR
# ========================================

START_BRANCH=$(run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)
if [[ -z "$START_BRANCH" ]]; then
    echo "Error: Failed to get current branch (git command timed out or failed)" >&2
    exit 1
fi

# ========================================
# Resolve Repository Context (for fork PR support)
# ========================================
# IMPORTANT: For fork PRs, the PR lives in the upstream (parent) repo, not the fork.
# We must resolve the correct repo BEFORE attempting to get PR number/state.

# Step 1: Get current repo
CURRENT_REPO=$(run_with_timeout "$GH_TIMEOUT" gh repo view --json owner,name \
    -q '.owner.login + "/" + .name' 2>/dev/null) || CURRENT_REPO=""

# Step 2: Check if current repo is a fork and get parent repo
PARENT_REPO=$(run_with_timeout "$GH_TIMEOUT" gh repo view --json parent \
    -q '.parent.owner.login + "/" + .parent.name' 2>/dev/null) || PARENT_REPO=""

# Step 3: Determine which repo to use for PR lookups
# Try current repo first, then parent (for fork case)
PR_LOOKUP_REPO=""
PR_NUMBER=""

# Try to find PR using gh's auto-detection (no --repo flag)
# This handles cases where local branch name differs from PR head (e.g., renamed branch)
# IMPORTANT: gh pr view can auto-resolve to upstream repo when in a fork, so we must
# extract the actual repo from the PR URL rather than assuming it's CURRENT_REPO
PR_INFO=$(run_with_timeout "$GH_TIMEOUT" gh pr view --json number,url -q '.number,.url' 2>/dev/null) || PR_INFO=""
if [[ -n "$PR_INFO" ]]; then
    # Parse number and URL from newline-separated output (jq outputs each field on separate line)
    PR_NUMBER=$(echo "$PR_INFO" | head -1)
    PR_URL=$(echo "$PR_INFO" | tail -1)
    # Validate PR_NUMBER is numeric
    if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid PR number from gh CLI: $PR_INFO" >&2
        PR_NUMBER=""
        PR_URL=""
    else
        # Extract repo from URL: https://HOST/OWNER/REPO/pull/NUMBER -> OWNER/REPO
        # Works with github.com and GitHub Enterprise (any host)
        if [[ "$PR_URL" =~ https?://[^/]+/([^/]+/[^/]+)/pull/ ]]; then
            PR_LOOKUP_REPO="${BASH_REMATCH[1]}"
        else
            # Fallback to current repo if URL parsing fails
            PR_LOOKUP_REPO="$CURRENT_REPO"
        fi
    fi
fi

# If not found in current repo and we have a parent (fork case), try parent
# IMPORTANT: For fork PRs, the head branch lives in the fork, so we must use
# the fork-qualified format (FORK_OWNER:BRANCH) when looking up in parent repo
if [[ -z "$PR_NUMBER" && -n "$PARENT_REPO" && "$PARENT_REPO" != "null/" && "$PARENT_REPO" != "/" ]]; then
    echo "Checking parent repo for PR (fork detected)..." >&2
    # Extract fork owner from CURRENT_REPO (format: owner/repo)
    FORK_OWNER="${CURRENT_REPO%%/*}"
    # Use fork-qualified branch name: FORK_OWNER:BRANCH
    QUALIFIED_BRANCH="${FORK_OWNER}:${START_BRANCH}"
    echo "  Using qualified branch: $QUALIFIED_BRANCH" >&2
    PR_NUMBER=$(run_with_timeout "$GH_TIMEOUT" gh pr view --repo "$PARENT_REPO" "$QUALIFIED_BRANCH" --json number -q .number 2>/dev/null) || PR_NUMBER=""
    if [[ -n "$PR_NUMBER" ]]; then
        PR_LOOKUP_REPO="$PARENT_REPO"
        echo "Found PR #$PR_NUMBER in parent repo: $PARENT_REPO" >&2
    fi
fi

if [[ -z "$PR_NUMBER" ]]; then
    echo "Error: No pull request found for branch '$START_BRANCH'" >&2
    echo "" >&2
    echo "Please create a pull request first:" >&2
    echo "  gh pr create" >&2
    exit 1
fi

# Validate PR_NUMBER is numeric
if ! [[ "$PR_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "Error: Invalid PR number from gh CLI: $PR_NUMBER" >&2
    exit 1
fi

# Get PR state (using resolved repo for fork support)
PR_STATE=$(run_with_timeout "$GH_TIMEOUT" gh pr view "$PR_NUMBER" --repo "$PR_LOOKUP_REPO" --json state -q .state 2>/dev/null) || PR_STATE=""
if [[ "$PR_STATE" == "MERGED" ]]; then
    echo "Error: PR #$PR_NUMBER has already been merged" >&2
    exit 1
fi
if [[ "$PR_STATE" == "CLOSED" ]]; then
    echo "Error: PR #$PR_NUMBER has been closed" >&2
    exit 1
fi

# IMPORTANT: Use the PR's lookup repository for API calls
# Since PR_LOOKUP_REPO was already validated to contain this PR, we can use it directly
PR_BASE_REPO="$PR_LOOKUP_REPO"

# ========================================
# Validate YAML Safety
# ========================================

# Validate branch name for YAML safety (prevents injection in state.md)
if [[ "$START_BRANCH" == *[:\#\"\'\`]* ]] || [[ "$START_BRANCH" =~ $'\n' ]]; then
    echo "Error: Branch name contains YAML-unsafe characters" >&2
    echo "  Branch: $START_BRANCH" >&2
    echo "  Characters not allowed: : # \" ' \` newline" >&2
    echo "  Please checkout a branch with a simpler name" >&2
    exit 1
fi

# Validate codex model for YAML safety
if [[ ! "$CODEX_MODEL" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "Error: Codex model contains invalid characters" >&2
    echo "  Model: $CODEX_MODEL" >&2
    echo "  Only alphanumeric, hyphen, underscore, dot allowed" >&2
    exit 1
fi

# Validate codex effort for YAML safety
if [[ ! "$CODEX_EFFORT" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: Codex effort contains invalid characters" >&2
    echo "  Effort: $CODEX_EFFORT" >&2
    echo "  Only alphanumeric, hyphen, underscore allowed" >&2
    exit 1
fi

# ========================================
# Setup State Directory
# ========================================

LOOP_BASE_DIR="$PROJECT_ROOT/.humanize/pr-loop"

# Create timestamp for this loop session
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
LOOP_DIR="$LOOP_BASE_DIR/$TIMESTAMP"

mkdir -p "$LOOP_DIR"

# ========================================
# Fetch Initial Comments
# ========================================

COMMENT_FILE="$LOOP_DIR/round-0-pr-comment.md"

# Build comma-separated bot list for fetch script
BOTS_COMMA_LIST=$(IFS=','; echo "${ACTIVE_BOTS_ARRAY[*]}")

# Call fetch-pr-comments.sh to get all comments, grouped by active bots
"$SCRIPT_DIR/fetch-pr-comments.sh" "$PR_NUMBER" "$COMMENT_FILE" --bots "$BOTS_COMMA_LIST"

# ========================================
# Determine Startup Case
# ========================================

# Call check-pr-reviewer-status.sh to analyze PR state
REVIEWER_STATUS=$("$SCRIPT_DIR/check-pr-reviewer-status.sh" "$PR_NUMBER" --bots "$BOTS_COMMA_LIST" 2>/dev/null) || {
    echo "Warning: Failed to check reviewer status, defaulting to Case 1" >&2
    REVIEWER_STATUS='{"case":1,"reviewers_commented":[],"reviewers_missing":[],"latest_commit_sha":"","latest_commit_at":"","newest_review_at":null,"has_commits_after_reviews":false}'
}

# Parse reviewer status JSON
STARTUP_CASE=$(echo "$REVIEWER_STATUS" | jq -r '.case')
LATEST_COMMIT_SHA=$(echo "$REVIEWER_STATUS" | jq -r '.latest_commit_sha')
LATEST_COMMIT_AT=$(echo "$REVIEWER_STATUS" | jq -r '.latest_commit_at')
HAS_COMMITS_AFTER=$(echo "$REVIEWER_STATUS" | jq -r '.has_commits_after_reviews')

# Fallback to git HEAD if API didn't return commit SHA
if [[ -z "$LATEST_COMMIT_SHA" ]] || [[ "$LATEST_COMMIT_SHA" == "null" ]]; then
    LATEST_COMMIT_SHA=$(run_with_timeout "$GIT_TIMEOUT" git rev-parse HEAD)
fi

echo "Startup Case: $STARTUP_CASE" >&2
echo "Latest Commit: $LATEST_COMMIT_SHA" >&2

# Handle Case 4/5: All reviewers commented but new commits exist
# Need to trigger re-review by posting @bot comment
LAST_TRIGGER_AT=""
TRIGGER_COMMENT_ID=""

if [[ "$STARTUP_CASE" -eq 4 ]] || [[ "$STARTUP_CASE" -eq 5 ]]; then
    echo "Case $STARTUP_CASE: Posting trigger comment for re-review..." >&2

    # Post trigger comment (abort on failure to prevent orphaned state)
    # NOTE: Uses --repo for fork PR support (comments go to base repo, not fork)
    TRIGGER_BODY="$BOT_MENTION_STRING please review the latest changes (new commits since last review)"
    TRIGGER_RESULT=$(run_with_timeout "$GH_TIMEOUT" gh pr comment "$PR_NUMBER" --repo "$PR_BASE_REPO" --body "$TRIGGER_BODY" 2>&1) || {
        echo "Error: Failed to post trigger comment: $TRIGGER_RESULT" >&2
        echo "" >&2
        echo "Cannot proceed without a trigger comment - bots would not be notified." >&2
        echo "Please check:" >&2
        echo "  - GitHub API rate limits" >&2
        echo "  - Network connectivity" >&2
        echo "  - Repository permissions" >&2
        rm -rf "$LOOP_DIR"
        exit 1
    }

    # Get the comment ID and use GitHub's timestamp to avoid clock skew
    # Fetch the latest comment from current user
    CURRENT_USER=$(run_with_timeout "$GH_TIMEOUT" gh api user --jq '.login' 2>/dev/null) || CURRENT_USER=""
    if [[ -n "$CURRENT_USER" ]]; then
        # Fetch both ID and created_at from the comment we just posted
        # IMPORTANT: --jq with --paginate runs per-page, so aggregate first then filter
        # IMPORTANT: Use PR_BASE_REPO for fork PR support
        COMMENT_DATA=$(run_with_timeout "$GH_TIMEOUT" gh api "repos/$PR_BASE_REPO/issues/$PR_NUMBER/comments" \
            --paginate --jq ".[] | select(.user.login == \"$CURRENT_USER\") | {id: .id, created_at: .created_at}" 2>/dev/null \
            | jq -s 'sort_by(.created_at) | reverse | .[0]') || COMMENT_DATA=""

        if [[ -n "$COMMENT_DATA" && "$COMMENT_DATA" != "null" ]]; then
            TRIGGER_COMMENT_ID=$(echo "$COMMENT_DATA" | jq -r '.id // empty')
            # Use GitHub's timestamp instead of local time to avoid clock skew
            LAST_TRIGGER_AT=$(echo "$COMMENT_DATA" | jq -r '.created_at // empty')
        fi
    fi

    # NOTE: Do NOT fall back to local time if GitHub timestamp fetch failed.
    # Local clock skew could set a future timestamp, causing stop hook to filter
    # out all comments. The stop hook has its own trigger detection logic that
    # will find the trigger comment if LAST_TRIGGER_AT is empty.

    # If --claude is specified, verify eyes reaction (MANDATORY per plan)
    if [[ "$BOT_CLAUDE" == "true" ]]; then
        echo "Verifying Claude eyes reaction (3 attempts x 5 seconds)..." >&2

        if [[ -z "$TRIGGER_COMMENT_ID" ]]; then
            # Fail if trigger comment ID not found (can't verify eyes without it)
            echo "Error: Could not find trigger comment ID for eyes verification" >&2
            echo "" >&2
            echo "The trigger comment was posted but its ID could not be retrieved." >&2
            echo "This prevents verification of Claude's eyes reaction." >&2
            echo "" >&2
            echo "Please try:" >&2
            echo "  1. Wait a moment and try again" >&2
            echo "  2. Check GitHub rate limits" >&2
            echo "  3. Verify the comment was posted successfully" >&2

            # Clean up the loop directory since we're failing
            rm -rf "$LOOP_DIR"
            exit 1
        fi

        # Check for eyes reaction with retry
        # Pass --pr for fork PR support (reactions are on base repo)
        if ! "$SCRIPT_DIR/check-bot-reactions.sh" claude-eyes "$TRIGGER_COMMENT_ID" --pr "$PR_NUMBER" --retry 3 --delay 5 >/dev/null 2>&1; then
            echo "Error: Claude bot did not respond with eyes reaction" >&2
            echo "" >&2
            echo "This may indicate:" >&2
            echo "  - Claude bot is not configured on this repository" >&2
            echo "  - Network issues preventing Claude from seeing the mention" >&2
            echo "" >&2
            echo "Please verify Claude bot is set up correctly on this repository." >&2

            # Clean up the loop directory since we're failing
            rm -rf "$LOOP_DIR"
            exit 1
        fi
        echo "Claude eyes reaction confirmed!" >&2
    fi
fi

# ========================================
# Create State File
# ========================================

# Build YAML list for active_bots and configured_bots (using shared helper)
ACTIVE_BOTS_YAML=$(build_yaml_list "${ACTIVE_BOTS_ARRAY[@]}")

# configured_bots is identical to active_bots at start, but never changes
# This allows re-polling previously approved bots if they post new issues
CONFIGURED_BOTS_YAML="$ACTIVE_BOTS_YAML"

cat > "$LOOP_DIR/state.md" << EOF
---
current_round: 0
max_iterations: $MAX_ITERATIONS
pr_number: $PR_NUMBER
start_branch: $START_BRANCH
configured_bots:${CONFIGURED_BOTS_YAML}
active_bots:${ACTIVE_BOTS_YAML}
codex_model: $CODEX_MODEL
codex_effort: $CODEX_EFFORT
codex_timeout: $CODEX_TIMEOUT
poll_interval: $POLL_INTERVAL
poll_timeout: $POLL_TIMEOUT
started_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
startup_case: $STARTUP_CASE
latest_commit_sha: $LATEST_COMMIT_SHA
latest_commit_at: ${LATEST_COMMIT_AT:-}
last_trigger_at: ${LAST_TRIGGER_AT:-}
trigger_comment_id: ${TRIGGER_COMMENT_ID:-}
---
EOF

# ========================================
# Create Goal Tracker
# ========================================

GOAL_TRACKER_FILE="$LOOP_DIR/goal-tracker.md"

# Build display string for active bots
ACTIVE_BOTS_DISPLAY=$(IFS=', '; echo "${ACTIVE_BOTS_ARRAY[*]}")

# Build acceptance criteria rows for each bot
BOT_AC_ROWS=""
AC_NUM=1
for bot in "${ACTIVE_BOTS_ARRAY[@]}"; do
    BOT_AC_ROWS="${BOT_AC_ROWS}| AC-${AC_NUM} | Get approval from ${bot} | ${bot} | pending |
"
    AC_NUM=$((AC_NUM + 1))
done

# Current timestamp for log
STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Goal tracker template variables
GOAL_TRACKER_VARS=(
    "PR_NUMBER=$PR_NUMBER"
    "START_BRANCH=$START_BRANCH"
    "ACTIVE_BOTS_DISPLAY=$ACTIVE_BOTS_DISPLAY"
    "STARTUP_CASE=$STARTUP_CASE"
    "BOT_AC_ROWS=$BOT_AC_ROWS"
    "STARTED_AT=$STARTED_AT"
)

FALLBACK_GOAL_TRACKER="# PR Loop Goal Tracker

## PR Information

- **PR Number:** #$PR_NUMBER
- **Branch:** $START_BRANCH
- **Monitored Bots:** $ACTIVE_BOTS_DISPLAY
- **Startup Case:** $STARTUP_CASE

## Ultimate Goal

Get all monitored bot reviewers ($ACTIVE_BOTS_DISPLAY) to approve this PR.

## Acceptance Criteria

| AC | Description | Bot | Status |
|----|-------------|-----|--------|
${BOT_AC_ROWS}
## Current Status

### Round 0: Initialization

- **Phase:** Waiting for initial bot reviews
- **Active Bots:** $ACTIVE_BOTS_DISPLAY
- **Approved Bots:** (none yet)

### Open Issues

| Round | Bot | Issue | Status |
|-------|-----|-------|--------|
| - | - | (awaiting initial reviews) | pending |

### Addressed Issues

| Round | Bot | Issue | Resolution |
|-------|-----|-------|------------|

## Log

| Round | Timestamp | Event |
|-------|-----------|-------|
| 0 | $STARTED_AT | PR loop initialized (Case $STARTUP_CASE) |
"

GOAL_TRACKER_CONTENT=$(load_and_render_safe "$TEMPLATE_DIR" "pr-loop/goal-tracker-initial.md" "$FALLBACK_GOAL_TRACKER" "${GOAL_TRACKER_VARS[@]}")
echo "$GOAL_TRACKER_CONTENT" > "$GOAL_TRACKER_FILE"

echo "Goal tracker created: $GOAL_TRACKER_FILE" >&2

# ========================================
# Create Initial Prompt
# ========================================

RESOLVE_PATH="$LOOP_DIR/round-0-pr-resolve.md"

# Detect if comments exist by checking for the "No comments found" sentinel
# fetch-pr-comments.sh outputs "*No comments found.*" only when there are zero comments
if grep -q '^\*No comments found\.\*$' "$COMMENT_FILE" 2>/dev/null; then
    COMMENT_COUNT=0
else
    COMMENT_COUNT=1  # Non-zero indicates comments exist
fi

# Template variables for rendering
TEMPLATE_VARS=(
    "PR_NUMBER=$PR_NUMBER"
    "START_BRANCH=$START_BRANCH"
    "ACTIVE_BOTS_DISPLAY=$ACTIVE_BOTS_DISPLAY"
    "RESOLVE_PATH=$RESOLVE_PATH"
    "BOT_MENTION_STRING=$BOT_MENTION_STRING"
)

# Fallback header (used if template fails to load)
FALLBACK_HEADER="Read and execute below with ultrathink

## PR Review Loop (Round 0)

You are in a PR review loop monitoring feedback from remote review bots.

**PR Information:**
- PR Number: #{{PR_NUMBER}}
- Branch: {{START_BRANCH}}
- Active Bots: {{ACTIVE_BOTS_DISPLAY}}

## Review Comments

The following comments have been fetched from the PR:
"

# Load and render header template
HEADER_CONTENT=$(load_and_render_safe "$TEMPLATE_DIR" "pr-loop/round-0-header.md" "$FALLBACK_HEADER" "${TEMPLATE_VARS[@]}")

# Write header to prompt file
echo "$HEADER_CONTENT" > "$LOOP_DIR/round-0-prompt.md"

# Append the fetched comments
cat "$COMMENT_FILE" >> "$LOOP_DIR/round-0-prompt.md"

# Select task template based on whether there are comments
if [[ "$COMMENT_COUNT" -eq 0 ]]; then
    # No comments yet - this is a fresh PR, bots will review automatically
    FALLBACK_TASK="
---

## Your Task

This PR has no review comments yet. The monitored bots ({{ACTIVE_BOTS_DISPLAY}}) will automatically review the PR - you do NOT need to comment to trigger the first review.

1. **Wait for automatic bot reviews**:
   - Simply write your summary and try to exit
   - The Stop Hook will poll for the first bot reviews

2. **Write your initial summary** to: @{{RESOLVE_PATH}}
   - Note that this is Round 0 awaiting initial bot reviews
   - No issues to address yet

---

## Important Rules

1. **Do not comment to trigger review**: First reviews are automatic
2. **Do not modify state files**: The .humanize/pr-loop/ files are managed by the system
3. **Trust the process**: The Stop Hook manages polling and Codex validation

---

Note: After you write your summary and try to exit, the Stop Hook will:
1. Poll for bot reviews (every 30 seconds, up to 15 minutes per bot)
2. When reviews arrive, local Codex will validate if they indicate approval
3. If issues are found, you will receive feedback and continue
4. If all bots approve, the loop ends
"
    TASK_CONTENT=$(load_and_render_safe "$TEMPLATE_DIR" "pr-loop/round-0-task-no-comments.md" "$FALLBACK_TASK" "${TEMPLATE_VARS[@]}")
else
    # Has comments - normal flow with issues to address
    FALLBACK_TASK="
---

## Your Task

1. **Analyze the comments above**, prioritizing:
   - Human comments first (they take precedence)
   - Bot comments (newest first)

2. **Fix any issues** identified by the reviewers:
   - Read the relevant code files
   - Make necessary changes
   - Create appropriate tests if needed

3. **After fixing issues**:
   - Commit your changes with a descriptive message
   - Push to the remote repository
   - Comment on the PR to trigger re-review:
     \`\`\`bash
     gh pr comment {{PR_NUMBER}} --body \"{{BOT_MENTION_STRING}} please review the latest changes\"
     \`\`\`

4. **Write your resolution summary** to: @{{RESOLVE_PATH}}
   - List what issues were addressed
   - Files modified
   - Tests added (if any)

---

## Important Rules

1. **Do not modify state files**: The .humanize/pr-loop/ files are managed by the system
2. **Always push changes**: Your fixes must be pushed for bots to review them
3. **Use the correct comment format**: Tag the bots to trigger their reviews
4. **Be thorough**: Address all valid concerns from the reviewers

---

Note: After you write your summary and try to exit, the Stop Hook will:
1. Poll for new bot reviews (every 30 seconds, up to 15 minutes per bot)
2. When reviews arrive, local Codex will validate if they indicate approval
3. If issues remain, you will receive feedback and continue
4. If all bots approve, the loop ends
"
    TASK_CONTENT=$(load_and_render_safe "$TEMPLATE_DIR" "pr-loop/round-0-task-has-comments.md" "$FALLBACK_TASK" "${TEMPLATE_VARS[@]}")
fi

# Append task section to prompt file
echo "$TASK_CONTENT" >> "$LOOP_DIR/round-0-prompt.md"

# ========================================
# Output Setup Message
# ========================================

# All important work is done. If output fails due to SIGPIPE (pipe closed), exit cleanly.
trap 'exit 0' PIPE

cat << EOF
=== start-pr-loop activated ===

PR Number: #$PR_NUMBER
Branch: $START_BRANCH
Active Bots: $ACTIVE_BOTS_DISPLAY
Comments Fetched: $COMMENT_COUNT
Max Iterations: $MAX_ITERATIONS
Codex Model: $CODEX_MODEL
Codex Effort: $CODEX_EFFORT
Codex Timeout: ${CODEX_TIMEOUT}s
Poll Interval: ${POLL_INTERVAL}s
Poll Timeout: ${POLL_TIMEOUT}s (per bot)
Loop Directory: $LOOP_DIR

The PR loop is now active. When you try to exit:
1. Stop Hook polls for new bot reviews (every 30s)
2. When reviews arrive, local Codex validates them
3. If issues remain, you'll receive feedback and continue
4. If all bots approve, the loop ends

To cancel: /humanize:cancel-pr-loop

---

EOF

# Output the initial prompt
cat "$LOOP_DIR/round-0-prompt.md"

# Output critical requirements based on whether there are comments
echo ""
if [[ "$COMMENT_COUNT" -eq 0 ]]; then
    FALLBACK_CRITICAL="
===========================================
CRITICAL - Work Completion Requirements
===========================================

When you complete your work, you MUST:

1. Write your resolution summary to:
   {{RESOLVE_PATH}}

   The summary should note:
   - This is Round 0 awaiting initial bot reviews
   - No issues to address yet

2. Try to exit - the Stop Hook will poll for bot reviews

DO NOT comment on the PR to trigger review - the bots will
review automatically since this is a new PR.

The Stop Hook will poll for bot reviews.
==========================================="
    CRITICAL_CONTENT=$(load_and_render_safe "$TEMPLATE_DIR" "pr-loop/critical-requirements-no-comments.md" "$FALLBACK_CRITICAL" "${TEMPLATE_VARS[@]}")
else
    FALLBACK_CRITICAL="
===========================================
CRITICAL - Work Completion Requirements
===========================================

When you complete your work, you MUST:

1. COMMIT and PUSH your changes:
   - Create a commit with descriptive message
   - Push to the remote repository

2. Comment on the PR to trigger re-review:
   gh pr comment {{PR_NUMBER}} --body \"{{BOT_MENTION_STRING}} please review\"

3. Write your resolution summary to:
   {{RESOLVE_PATH}}

   The summary should include:
   - Issues addressed
   - Files modified
   - Tests added (if any)

The Stop Hook will then poll for bot reviews.
==========================================="
    CRITICAL_CONTENT=$(load_and_render_safe "$TEMPLATE_DIR" "pr-loop/critical-requirements-has-comments.md" "$FALLBACK_CRITICAL" "${TEMPLATE_VARS[@]}")
fi
echo "$CRITICAL_CONTENT"

# Explicit exit 0 to ensure clean exit code even if final output fails
exit 0
