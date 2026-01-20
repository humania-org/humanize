#!/bin/bash
#
# Fetch PR comments from GitHub
#
# Fetches all types of PR comments:
# - Issue comments (general comments on the PR)
# - Review comments (inline code comments)
# - PR reviews (summary reviews with approval/rejection status)
#
# Usage:
#   fetch-pr-comments.sh <pr_number> <output_file> [--after <timestamp>]
#
# Output: Formatted markdown file with all comments
#

set -euo pipefail

# ========================================
# Parse Arguments
# ========================================

PR_NUMBER=""
OUTPUT_FILE=""
AFTER_TIMESTAMP=""
ACTIVE_BOTS=""  # Comma-separated list of active bots for grouping

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
            ACTIVE_BOTS="$2"
            shift 2
            ;;
        -h|--help)
            cat << 'HELP_EOF'
fetch-pr-comments.sh - Fetch PR comments from GitHub

USAGE:
  fetch-pr-comments.sh <pr_number> <output_file> [OPTIONS]

ARGUMENTS:
  <pr_number>     The PR number to fetch comments from
  <output_file>   Path to write the formatted comments

OPTIONS:
  --after <timestamp>   Only include comments after this ISO 8601 timestamp
  --bots <bot1,bot2>    Comma-separated list of active bots for grouping
  -h, --help            Show this help message

OUTPUT FORMAT:
  The output file contains markdown-formatted comments with:
  - Comment type (issue comment, review comment, PR review)
  - Author (with [bot] indicator for bot accounts)
  - Timestamp
  - Content

  Comments are deduplicated by ID and sorted newest first.
  Human comments come before bot comments.
  If --bots is provided, bot comments are grouped by bot.
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
            elif [[ -z "$OUTPUT_FILE" ]]; then
                OUTPUT_FILE="$1"
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

if [[ -z "$OUTPUT_FILE" ]]; then
    echo "Error: Output file is required" >&2
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
# Strategy: First get current repo, check if PR exists there, then try parent repo for forks

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
# Fetch Comments
# ========================================

# Create temporary files for each comment type
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

ISSUE_COMMENTS_FILE="$TEMP_DIR/issue_comments.json"
REVIEW_COMMENTS_FILE="$TEMP_DIR/review_comments.json"
PR_REVIEWS_FILE="$TEMP_DIR/pr_reviews.json"

# Retry configuration
MAX_RETRIES=3
RETRY_DELAY=2

# Track API failures for strict mode
API_FAILURES=0

# Function to fetch with retries
fetch_with_retry() {
    local endpoint="$1"
    local output_file="$2"
    local description="$3"
    local attempt=1

    while [[ $attempt -le $MAX_RETRIES ]]; do
        if gh api "$endpoint" --paginate > "$output_file" 2>/dev/null; then
            return 0
        fi

        if [[ $attempt -lt $MAX_RETRIES ]]; then
            echo "Warning: Failed to fetch $description (attempt $attempt/$MAX_RETRIES), retrying in ${RETRY_DELAY}s..." >&2
            sleep "$RETRY_DELAY"
        else
            echo "ERROR: Failed to fetch $description after $MAX_RETRIES attempts" >&2
            echo "[]" > "$output_file"
            API_FAILURES=$((API_FAILURES + 1))
            # Return 0 so script continues under set -euo pipefail
            # API_FAILURES counter tracks failures for strict mode if needed
            return 0
        fi
        ((attempt++))
    done
}

# Fetch issue comments (general PR comments)
# claude[bot] typically posts here
fetch_with_retry "repos/$REPO_OWNER/$REPO_NAME/issues/$PR_NUMBER/comments" "$ISSUE_COMMENTS_FILE" "issue comments"

# Fetch PR review comments (inline code comments)
# codex (chatgpt-codex-connector[bot]) typically posts inline comments here
fetch_with_retry "repos/$REPO_OWNER/$REPO_NAME/pulls/$PR_NUMBER/comments" "$REVIEW_COMMENTS_FILE" "PR review comments"

# Fetch PR reviews (summary reviews with approval status)
# Both bots may post summary reviews here
fetch_with_retry "repos/$REPO_OWNER/$REPO_NAME/pulls/$PR_NUMBER/reviews" "$PR_REVIEWS_FILE" "PR reviews"

# ========================================
# Process and Format Comments
# ========================================

# Function to check if user is a bot
is_bot() {
    local user_type="$1"
    local user_login="$2"

    if [[ "$user_type" == "Bot" ]] || [[ "$user_login" == *"[bot]" ]]; then
        echo "true"
    else
        echo "false"
    fi
}

# Function to format timestamp for comparison
format_timestamp() {
    local ts="$1"
    # Remove trailing Z and convert to comparable format
    echo "$ts" | sed 's/Z$//' | tr 'T' ' '
}

# Initialize output file
cat > "$OUTPUT_FILE" << EOF
# PR Comments for #$PR_NUMBER

Fetched at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Repository: $REPO_OWNER/$REPO_NAME

---

EOF

# Process all comments into a unified format
# Create a combined JSON with all comments
ALL_COMMENTS_FILE="$TEMP_DIR/all_comments.json"

# Process issue comments
jq -r --arg type "issue_comment" '
    if type == "array" then
        .[] | {
            type: $type,
            id: .id,
            author: .user.login,
            author_type: .user.type,
            created_at: .created_at,
            updated_at: .updated_at,
            body: .body,
            path: null,
            line: null,
            state: null
        }
    else
        empty
    end
' "$ISSUE_COMMENTS_FILE" > "$TEMP_DIR/issue_processed.jsonl" 2>/dev/null || true

# Process review comments (inline)
jq -r --arg type "review_comment" '
    if type == "array" then
        .[] | {
            type: $type,
            id: .id,
            author: .user.login,
            author_type: .user.type,
            created_at: .created_at,
            updated_at: .updated_at,
            body: .body,
            path: .path,
            line: (.line // .original_line),
            state: null
        }
    else
        empty
    end
' "$REVIEW_COMMENTS_FILE" > "$TEMP_DIR/review_processed.jsonl" 2>/dev/null || true

# Process PR reviews
# Note: Include all reviews, even those with empty body (e.g. approval-only reviews)
# For empty body reviews, use a placeholder indicating the state
jq -r --arg type "pr_review" '
    if type == "array" then
        .[] | {
            type: $type,
            id: .id,
            author: .user.login,
            author_type: .user.type,
            created_at: .submitted_at,
            updated_at: .submitted_at,
            body: (if .body == null or .body == "" then "[Review state: \(.state)]" else .body end),
            path: null,
            line: null,
            state: .state
        }
    else
        empty
    end
' "$PR_REVIEWS_FILE" > "$TEMP_DIR/reviews_processed.jsonl" 2>/dev/null || true

# Combine all processed comments and deduplicate by id
cat "$TEMP_DIR/issue_processed.jsonl" "$TEMP_DIR/review_processed.jsonl" "$TEMP_DIR/reviews_processed.jsonl" 2>/dev/null | \
    jq -s 'unique_by(.id)' > "$ALL_COMMENTS_FILE"

# Filter by timestamp if provided
if [[ -n "$AFTER_TIMESTAMP" ]]; then
    jq --arg after "$AFTER_TIMESTAMP" '
        [.[] | select(.created_at > $after)]
    ' "$ALL_COMMENTS_FILE" > "$TEMP_DIR/filtered.json"
    mv "$TEMP_DIR/filtered.json" "$ALL_COMMENTS_FILE"
fi

# Sort: human comments first, then by timestamp (newest first)
# Uses fromdateiso8601 for proper ISO 8601 timestamp parsing
# Filter out entries with null created_at to avoid fromdateiso8601 errors
jq '
    [.[] | select(.created_at != null)] |
    sort_by(
        (if .author_type == "Bot" or (.author | test("\\[bot\\]$")) then 1 else 0 end),
        -(.created_at | fromdateiso8601)
    )
' "$ALL_COMMENTS_FILE" > "$TEMP_DIR/sorted.json"

# Format comments into markdown
COMMENT_COUNT=$(jq 'length' "$TEMP_DIR/sorted.json")

if [[ "$COMMENT_COUNT" == "0" ]]; then
    cat >> "$OUTPUT_FILE" << EOF
*No comments found.*

---

This PR has no review comments yet from the monitored bots.
EOF
else
    # Add section headers
    echo "## Human Comments" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"

    # First pass: human comments
    HUMAN_COMMENTS=$(jq -r '
        .[] | select(.author_type != "Bot" and (.author | test("\\[bot\\]$") | not)) |
        "### Comment from \(.author)\n\n" +
        "- **Type**: \(.type | gsub("_"; " "))\n" +
        "- **Time**: \(.created_at)\n" +
        (if .path then "- **File**: `\(.path)`\(if .line then " (line \(.line))" else "" end)\n" else "" end) +
        (if .state then "- **Status**: \(.state)\n" else "" end) +
        "\n\(.body)\n\n---\n"
    ' "$TEMP_DIR/sorted.json" 2>/dev/null || true)

    if [[ -n "$HUMAN_COMMENTS" ]]; then
        echo "$HUMAN_COMMENTS" >> "$OUTPUT_FILE"
    else
        echo "*No human comments.*" >> "$OUTPUT_FILE"
        echo "" >> "$OUTPUT_FILE"
    fi

    echo "" >> "$OUTPUT_FILE"

    # Second pass: bot comments
    if [[ -n "$ACTIVE_BOTS" ]]; then
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

        # Group bot comments by active bots
        echo "## Bot Comments (Grouped by Bot)" >> "$OUTPUT_FILE"
        echo "" >> "$OUTPUT_FILE"

        IFS=',' read -ra BOT_ARRAY <<< "$ACTIVE_BOTS"
        for bot in "${BOT_ARRAY[@]}"; do
            bot=$(echo "$bot" | tr -d ' ')
            author=$(map_bot_to_author "$bot")
            echo "### Comments from ${author}" >> "$OUTPUT_FILE"
            echo "" >> "$OUTPUT_FILE"

            BOT_COMMENTS=$(jq -r --arg author "$author" '
                [.[] | select(.author == $author)] |
                if length == 0 then
                    "*No comments from this bot.*\n"
                else
                    .[] |
                    "#### Comment\n\n" +
                    "- **Type**: \(.type | gsub("_"; " "))\n" +
                    "- **Time**: \(.created_at)\n" +
                    (if .path then "- **File**: `\(.path)`\(if .line then " (line \(.line))" else "" end)\n" else "" end) +
                    (if .state then "- **Status**: \(.state)\n" else "" end) +
                    "\n\(.body)\n\n---\n"
                end
            ' "$TEMP_DIR/sorted.json" 2>/dev/null || echo "*Error reading comments.*")

            echo "$BOT_COMMENTS" >> "$OUTPUT_FILE"
            echo "" >> "$OUTPUT_FILE"
        done
    else
        # Default: all bot comments together
        echo "## Bot Comments" >> "$OUTPUT_FILE"
        echo "" >> "$OUTPUT_FILE"

        jq -r '
            .[] | select(.author_type == "Bot" or (.author | test("\\[bot\\]$"))) |
            "### Comment from \(.author)\n\n" +
            "- **Type**: \(.type | gsub("_"; " "))\n" +
            "- **Time**: \(.created_at)\n" +
            (if .path then "- **File**: `\(.path)`\(if .line then " (line \(.line))" else "" end)\n" else "" end) +
            (if .state then "- **Status**: \(.state)\n" else "" end) +
            "\n\(.body)\n\n---\n"
        ' "$TEMP_DIR/sorted.json" >> "$OUTPUT_FILE" 2>/dev/null || true
    fi
fi

echo "" >> "$OUTPUT_FILE"
echo "---" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"
echo "*End of comments*" >> "$OUTPUT_FILE"

# Report API failures (non-fatal but logged)
if [[ $API_FAILURES -gt 0 ]]; then
    echo "WARNING: $API_FAILURES API endpoint(s) failed after retries. Some comments may be missing." >&2
    echo "" >> "$OUTPUT_FILE"
    echo "**Warning:** Some API calls failed. Comments may be incomplete." >> "$OUTPUT_FILE"
fi

exit 0
