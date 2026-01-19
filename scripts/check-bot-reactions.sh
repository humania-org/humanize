#!/bin/bash
#
# Check bot reactions on PR or comments
#
# Detects:
# - Codex +1 (thumbs-up) reaction on PR body (first round approval)
# - Claude eyes reaction on trigger comments (confirmation of receipt)
#
# Usage:
#   check-bot-reactions.sh codex-thumbsup <pr_number> [--after <timestamp>]
#   check-bot-reactions.sh claude-eyes <comment_id> [--retry <attempts>] [--delay <seconds>]
#
# Exit codes:
#   0 - Reaction found
#   1 - Reaction not found (or timeout after all retries)
#   2 - Error (API failure, missing arguments, etc.)

set -euo pipefail

# ========================================
# Default Configuration
# ========================================

# Timeout for gh operations
GH_TIMEOUT=30

# Default retry settings for claude eyes
DEFAULT_MAX_RETRIES=3
DEFAULT_RETRY_DELAY=5

# Source portable timeout wrapper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/portable-timeout.sh"

# ========================================
# Helper Functions
# ========================================

show_help() {
    cat << 'EOF'
check-bot-reactions.sh - Detect bot reactions on GitHub PRs and comments

USAGE:
  check-bot-reactions.sh codex-thumbsup <pr_number> [--after <timestamp>]
  check-bot-reactions.sh claude-eyes <comment_id> [--retry <attempts>] [--delay <seconds>]

COMMANDS:
  codex-thumbsup    Check for Codex +1 reaction on PR body
                    Returns reaction created_at timestamp if found
                    --after: Only count reaction if created after this timestamp

  claude-eyes       Check for Claude eyes reaction on a specific comment
                    Retries with delay if not found immediately
                    --retry: Number of attempts (default: 3)
                    --delay: Seconds between attempts (default: 5)

EXIT CODES:
  0 - Reaction found (outputs JSON with reaction info)
  1 - Reaction not found
  2 - Error (API failure, etc.)

EXAMPLES:
  # Check if Codex approved PR #123 with thumbs-up
  check-bot-reactions.sh codex-thumbsup 123

  # Check if Codex approved after loop started
  check-bot-reactions.sh codex-thumbsup 123 --after "2026-01-18T10:00:00Z"

  # Wait for Claude eyes reaction on comment (15 seconds total)
  check-bot-reactions.sh claude-eyes 12345678 --retry 3 --delay 5
EOF
    exit 0
}

# ========================================
# Parse Arguments
# ========================================

COMMAND="${1:-}"
shift || true

if [[ -z "$COMMAND" ]] || [[ "$COMMAND" == "-h" ]] || [[ "$COMMAND" == "--help" ]]; then
    show_help
fi

case "$COMMAND" in
    codex-thumbsup)
        # Parse codex-thumbsup arguments
        PR_NUMBER=""
        AFTER_TIMESTAMP=""

        while [[ $# -gt 0 ]]; do
            case $1 in
                --after)
                    AFTER_TIMESTAMP="$2"
                    shift 2
                    ;;
                -*)
                    echo "Error: Unknown option for codex-thumbsup: $1" >&2
                    exit 2
                    ;;
                *)
                    if [[ -z "$PR_NUMBER" ]]; then
                        PR_NUMBER="$1"
                    else
                        echo "Error: Multiple PR numbers specified" >&2
                        exit 2
                    fi
                    shift
                    ;;
            esac
        done

        if [[ -z "$PR_NUMBER" ]]; then
            echo "Error: PR number is required for codex-thumbsup" >&2
            exit 2
        fi

        # Fetch PR reactions
        # The PR body is treated as issue #PR_NUMBER, so we use the issues reactions endpoint
        REACTIONS=$(run_with_timeout "$GH_TIMEOUT" gh api "repos/{owner}/{repo}/issues/$PR_NUMBER/reactions" \
            --jq '[.[] | {user: .user.login, content: .content, created_at: .created_at}]' 2>/dev/null) || {
            echo "Error: Failed to fetch PR reactions" >&2
            exit 2
        }

        # Look for Codex +1 reaction
        # User login: chatgpt-codex-connector[bot]
        CODEX_REACTION=$(echo "$REACTIONS" | jq -r '
            [.[] | select(.user == "chatgpt-codex-connector[bot]" and .content == "+1")] | .[0]
        ')

        if [[ "$CODEX_REACTION" == "null" ]] || [[ -z "$CODEX_REACTION" ]]; then
            # No +1 reaction from Codex
            exit 1
        fi

        REACTION_AT=$(echo "$CODEX_REACTION" | jq -r '.created_at')

        # If --after specified, check timestamp
        if [[ -n "$AFTER_TIMESTAMP" ]]; then
            if [[ "$REACTION_AT" < "$AFTER_TIMESTAMP" ]]; then
                # Reaction exists but is older than specified timestamp
                exit 1
            fi
        fi

        # Output reaction info
        echo "$CODEX_REACTION"
        exit 0
        ;;

    claude-eyes)
        # Parse claude-eyes arguments
        COMMENT_ID=""
        MAX_RETRIES="$DEFAULT_MAX_RETRIES"
        RETRY_DELAY="$DEFAULT_RETRY_DELAY"

        while [[ $# -gt 0 ]]; do
            case $1 in
                --retry)
                    MAX_RETRIES="$2"
                    shift 2
                    ;;
                --delay)
                    RETRY_DELAY="$2"
                    shift 2
                    ;;
                -*)
                    echo "Error: Unknown option for claude-eyes: $1" >&2
                    exit 2
                    ;;
                *)
                    if [[ -z "$COMMENT_ID" ]]; then
                        COMMENT_ID="$1"
                    else
                        echo "Error: Multiple comment IDs specified" >&2
                        exit 2
                    fi
                    shift
                    ;;
            esac
        done

        if [[ -z "$COMMENT_ID" ]]; then
            echo "Error: Comment ID is required for claude-eyes" >&2
            exit 2
        fi

        # Retry loop for eyes reaction
        for attempt in $(seq 1 "$MAX_RETRIES"); do
            # Wait before checking (gives Claude time to react)
            sleep "$RETRY_DELAY"

            # Fetch comment reactions
            REACTIONS=$(run_with_timeout "$GH_TIMEOUT" gh api "repos/{owner}/{repo}/issues/comments/$COMMENT_ID/reactions" \
                --jq '[.[] | {user: .user.login, content: .content, created_at: .created_at}]' 2>/dev/null) || {
                # API error - continue to next attempt
                continue
            }

            # Look for Claude eyes reaction
            # User login: claude[bot]
            CLAUDE_REACTION=$(echo "$REACTIONS" | jq -r '
                [.[] | select(.user == "claude[bot]" and .content == "eyes")] | .[0]
            ')

            if [[ "$CLAUDE_REACTION" != "null" ]] && [[ -n "$CLAUDE_REACTION" ]]; then
                # Found eyes reaction
                echo "$CLAUDE_REACTION"
                exit 0
            fi

            # Not found yet, will retry if attempts remain
            if [[ $attempt -lt $MAX_RETRIES ]]; then
                echo "Attempt $attempt/$MAX_RETRIES: Eyes not found, retrying..." >&2
            fi
        done

        # All attempts exhausted
        echo "No eyes reaction found after $MAX_RETRIES attempts ($(( MAX_RETRIES * RETRY_DELAY )) seconds total)" >&2
        exit 1
        ;;

    *)
        echo "Error: Unknown command: $COMMAND" >&2
        echo "Use --help for usage information" >&2
        exit 2
        ;;
esac
