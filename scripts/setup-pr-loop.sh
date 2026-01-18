#!/bin/bash
#
# Setup script for start-pr-loop
#
# Creates state files for the PR loop that monitors GitHub PR reviews from bots.
#
# Usage:
#   setup-pr-loop.sh --claude|--chatgpt-codex-connector [--max N] [--codex-model MODEL:EFFORT] [--codex-timeout SECONDS]
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

# Source portable timeout wrapper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/portable-timeout.sh"

# ========================================
# Parse Arguments
# ========================================

MAX_ITERATIONS="$DEFAULT_MAX_ITERATIONS"
CODEX_MODEL="$DEFAULT_CODEX_MODEL"
CODEX_EFFORT="$DEFAULT_CODEX_EFFORT"
CODEX_TIMEOUT="$DEFAULT_CODEX_TIMEOUT"

# Bot flags
BOT_CLAUDE="false"
BOT_CHATGPT_CODEX_CONNECTOR="false"

show_help() {
    cat << 'HELP_EOF'
start-pr-loop - PR review loop with remote bot monitoring

USAGE:
  /humanize:start-pr-loop --claude|--chatgpt-codex-connector [OPTIONS]

BOT FLAGS (at least one required):
  --claude                    Monitor reviews from claude[bot]
  --chatgpt-codex-connector   Monitor reviews from chatgpt-codex-connector[bot]

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
  /humanize:start-pr-loop --chatgpt-codex-connector --max 20
  /humanize:start-pr-loop --claude --chatgpt-codex-connector

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
        --chatgpt-codex-connector)
            BOT_CHATGPT_CODEX_CONNECTOR="true"
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

if [[ "$BOT_CLAUDE" != "true" && "$BOT_CHATGPT_CODEX_CONNECTOR" != "true" ]]; then
    echo "Error: At least one bot flag is required" >&2
    echo "" >&2
    echo "Usage: /humanize:start-pr-loop --claude|--chatgpt-codex-connector [OPTIONS]" >&2
    echo "" >&2
    echo "Bot flags:" >&2
    echo "  --claude                    Monitor reviews from claude[bot]" >&2
    echo "  --chatgpt-codex-connector   Monitor reviews from chatgpt-codex-connector[bot]" >&2
    echo "" >&2
    echo "For help: /humanize:start-pr-loop --help" >&2
    exit 1
fi

# Build active_bots list (stored as array for YAML list format)
declare -a ACTIVE_BOTS_ARRAY=()
if [[ "$BOT_CLAUDE" == "true" ]]; then
    ACTIVE_BOTS_ARRAY+=("claude")
fi
if [[ "$BOT_CHATGPT_CODEX_CONNECTOR" == "true" ]]; then
    ACTIVE_BOTS_ARRAY+=("chatgpt-codex-connector")
fi

# Build dynamic mention string from active bots (no hardcoded bot names)
BOT_MENTION_STRING=""
for bot in "${ACTIVE_BOTS_ARRAY[@]}"; do
    if [[ -n "$BOT_MENTION_STRING" ]]; then
        BOT_MENTION_STRING="${BOT_MENTION_STRING} @${bot}"
    else
        BOT_MENTION_STRING="@${bot}"
    fi
done

# ========================================
# Validate Prerequisites
# ========================================

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"

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

# Check for associated PR
PR_NUMBER=$(gh pr view --json number -q .number 2>/dev/null) || true
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

# Get PR state
PR_STATE=$(gh pr view --json state -q .state 2>/dev/null) || true
if [[ "$PR_STATE" == "MERGED" ]]; then
    echo "Error: PR #$PR_NUMBER has already been merged" >&2
    exit 1
fi
if [[ "$PR_STATE" == "CLOSED" ]]; then
    echo "Error: PR #$PR_NUMBER has been closed" >&2
    exit 1
fi

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
# Create State File
# ========================================

# Build YAML list for active_bots
ACTIVE_BOTS_YAML=""
for bot in "${ACTIVE_BOTS_ARRAY[@]}"; do
    ACTIVE_BOTS_YAML="${ACTIVE_BOTS_YAML}
  - ${bot}"
done

cat > "$LOOP_DIR/state.md" << EOF
---
current_round: 0
max_iterations: $MAX_ITERATIONS
pr_number: $PR_NUMBER
start_branch: $START_BRANCH
active_bots:${ACTIVE_BOTS_YAML}
codex_model: $CODEX_MODEL
codex_effort: $CODEX_EFFORT
codex_timeout: $CODEX_TIMEOUT
poll_interval: $POLL_INTERVAL
poll_timeout: $POLL_TIMEOUT
started_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
---
EOF

# ========================================
# Create Initial Prompt
# ========================================

RESOLVE_PATH="$LOOP_DIR/round-0-pr-resolve.md"

# Build display string for active bots
ACTIVE_BOTS_DISPLAY=$(IFS=', '; echo "${ACTIVE_BOTS_ARRAY[*]}")

cat > "$LOOP_DIR/round-0-prompt.md" << EOF
Read and execute below with ultrathink

## PR Review Loop (Round 0)

You are in a PR review loop monitoring feedback from remote review bots.

**PR Information:**
- PR Number: #$PR_NUMBER
- Branch: $START_BRANCH
- Active Bots: $ACTIVE_BOTS_DISPLAY

## Review Comments

The following comments have been fetched from the PR:

EOF

# Append the fetched comments
cat "$COMMENT_FILE" >> "$LOOP_DIR/round-0-prompt.md"

cat >> "$LOOP_DIR/round-0-prompt.md" << EOF

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
     gh pr comment $PR_NUMBER --body "$BOT_MENTION_STRING please review the latest changes"
     \`\`\`

4. **Write your resolution summary** to: @$RESOLVE_PATH
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
3. If issues remain, you'll receive feedback and continue
4. If all bots approve, the loop ends
EOF

# ========================================
# Output Setup Message
# ========================================

# All important work is done. If output fails due to SIGPIPE (pipe closed), exit cleanly.
trap 'exit 0' PIPE

COMMENT_COUNT=$(grep -c '^## Comment' "$COMMENT_FILE" 2>/dev/null || echo "0")

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

echo ""
echo "==========================================="
echo "CRITICAL - Work Completion Requirements"
echo "==========================================="
echo ""
echo "When you complete your work, you MUST:"
echo ""
echo "1. COMMIT and PUSH your changes:"
echo "   - Create a commit with descriptive message"
echo "   - Push to the remote repository"
echo ""
echo "2. Comment on the PR to trigger re-review:"
echo "   gh pr comment $PR_NUMBER --body \"$BOT_MENTION_STRING please review\""
echo ""
echo "3. Write your resolution summary to:"
echo "   $RESOLVE_PATH"
echo ""
echo "   The summary should include:"
echo "   - Issues addressed"
echo "   - Files modified"
echo "   - Tests added (if any)"
echo ""
echo "The Stop Hook will then poll for bot reviews."
echo "==========================================="

# Explicit exit 0 to ensure clean exit code even if final output fails
exit 0
