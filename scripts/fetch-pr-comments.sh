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
  -h, --help            Show this help message

OUTPUT FORMAT:
  The output file contains markdown-formatted comments with:
  - Comment type (issue comment, review comment, PR review)
  - Author (with [bot] indicator for bot accounts)
  - Timestamp
  - Content

  Comments are sorted newest first, with human comments before bot comments.
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

REPO_OWNER=$(gh repo view --json owner -q .owner.login 2>/dev/null) || {
    echo "Error: Failed to get repository owner" >&2
    exit 1
}

REPO_NAME=$(gh repo view --json name -q .name 2>/dev/null) || {
    echo "Error: Failed to get repository name" >&2
    exit 1
}

# ========================================
# Fetch Comments
# ========================================

# Create temporary files for each comment type
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

ISSUE_COMMENTS_FILE="$TEMP_DIR/issue_comments.json"
REVIEW_COMMENTS_FILE="$TEMP_DIR/review_comments.json"
PR_REVIEWS_FILE="$TEMP_DIR/pr_reviews.json"

# Fetch issue comments (general PR comments)
# claude[bot] typically posts here
gh api "repos/$REPO_OWNER/$REPO_NAME/issues/$PR_NUMBER/comments" --paginate > "$ISSUE_COMMENTS_FILE" 2>/dev/null || {
    echo "Warning: Failed to fetch issue comments" >&2
    echo "[]" > "$ISSUE_COMMENTS_FILE"
}

# Fetch PR review comments (inline code comments)
# chatgpt-codex-connector[bot] typically posts inline comments here
gh api "repos/$REPO_OWNER/$REPO_NAME/pulls/$PR_NUMBER/comments" --paginate > "$REVIEW_COMMENTS_FILE" 2>/dev/null || {
    echo "Warning: Failed to fetch PR review comments" >&2
    echo "[]" > "$REVIEW_COMMENTS_FILE"
}

# Fetch PR reviews (summary reviews with approval status)
# Both bots may post summary reviews here
gh api "repos/$REPO_OWNER/$REPO_NAME/pulls/$PR_NUMBER/reviews" --paginate > "$PR_REVIEWS_FILE" 2>/dev/null || {
    echo "Warning: Failed to fetch PR reviews" >&2
    echo "[]" > "$PR_REVIEWS_FILE"
}

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
jq -r --arg type "pr_review" '
    if type == "array" then
        .[] | select(.body != null and .body != "") | {
            type: $type,
            id: .id,
            author: .user.login,
            author_type: .user.type,
            created_at: .submitted_at,
            updated_at: .submitted_at,
            body: .body,
            path: null,
            line: null,
            state: .state
        }
    else
        empty
    end
' "$PR_REVIEWS_FILE" > "$TEMP_DIR/reviews_processed.jsonl" 2>/dev/null || true

# Combine all processed comments
cat "$TEMP_DIR/issue_processed.jsonl" "$TEMP_DIR/review_processed.jsonl" "$TEMP_DIR/reviews_processed.jsonl" 2>/dev/null | \
    jq -s '.' > "$ALL_COMMENTS_FILE"

# Filter by timestamp if provided
if [[ -n "$AFTER_TIMESTAMP" ]]; then
    jq --arg after "$AFTER_TIMESTAMP" '
        [.[] | select(.created_at > $after)]
    ' "$ALL_COMMENTS_FILE" > "$TEMP_DIR/filtered.json"
    mv "$TEMP_DIR/filtered.json" "$ALL_COMMENTS_FILE"
fi

# Sort: human comments first, then by timestamp (newest first)
jq '
    sort_by(
        (if .author_type == "Bot" or (.author | test("\\[bot\\]$")) then 1 else 0 end),
        (.created_at | split("T") | .[0] + .[1] | gsub("[:-]"; "")) | tonumber * -1
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
    jq -r '
        .[] | select(.author_type != "Bot" and (.author | test("\\[bot\\]$") | not)) |
        "### Comment from \(.author)\n\n" +
        "- **Type**: \(.type | gsub("_"; " "))\n" +
        "- **Time**: \(.created_at)\n" +
        (if .path then "- **File**: `\(.path)`\(if .line then " (line \(.line))" else "" end)\n" else "" end) +
        (if .state then "- **Status**: \(.state)\n" else "" end) +
        "\n\(.body)\n\n---\n"
    ' "$TEMP_DIR/sorted.json" >> "$OUTPUT_FILE" 2>/dev/null || true

    echo "" >> "$OUTPUT_FILE"
    echo "## Bot Comments" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"

    # Second pass: bot comments
    jq -r '
        .[] | select(.author_type == "Bot" or (.author | test("\\[bot\\]$"))) |
        "### Comment from \(.author) [bot]\n\n" +
        "- **Type**: \(.type | gsub("_"; " "))\n" +
        "- **Time**: \(.created_at)\n" +
        (if .path then "- **File**: `\(.path)`\(if .line then " (line \(.line))" else "" end)\n" else "" end) +
        (if .state then "- **Status**: \(.state)\n" else "" end) +
        "\n\(.body)\n\n---\n"
    ' "$TEMP_DIR/sorted.json" >> "$OUTPUT_FILE" 2>/dev/null || true
fi

echo "" >> "$OUTPUT_FILE"
echo "---" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"
echo "*End of comments*" >> "$OUTPUT_FILE"

exit 0
