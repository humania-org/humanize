#!/bin/bash
#
# Stop Hook for PR loop
#
# Intercepts Claude's exit attempts, polls for remote bot reviews,
# and uses local Codex to validate if bot concerns are addressed.
#
# State directory: .humanize/pr-loop/<timestamp>/
# State file: state.md (current_round, pr_number, active_bots, etc.)
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
DEFAULT_POLL_TIMEOUT=900  # 15 minutes

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

# Default timeout for git operations
GIT_TIMEOUT=30

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

# If no active PR loop, check for RLCR loop and exit accordingly
if [[ -z "$LOOP_DIR" ]]; then
    # No PR loop - let other hooks handle (like RLCR stop hook)
    exit 0
fi

STATE_FILE="$LOOP_DIR/state.md"

if [[ ! -f "$STATE_FILE" ]]; then
    exit 0
fi

# ========================================
# Parse State File
# ========================================

parse_pr_loop_state() {
    local state_file="$1"

    STATE_FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$state_file" 2>/dev/null || echo "")

    PR_CURRENT_ROUND=$(echo "$STATE_FRONTMATTER" | grep "^current_round:" | sed "s/current_round: *//" | tr -d ' ' || true)
    PR_MAX_ITERATIONS=$(echo "$STATE_FRONTMATTER" | grep "^max_iterations:" | sed "s/max_iterations: *//" | tr -d ' ' || true)
    PR_NUMBER=$(echo "$STATE_FRONTMATTER" | grep "^pr_number:" | sed "s/pr_number: *//" | tr -d ' ' || true)
    PR_START_BRANCH=$(echo "$STATE_FRONTMATTER" | grep "^start_branch:" | sed "s/start_branch: *//; s/^\"//; s/\"\$//" || true)
    PR_ACTIVE_BOTS=$(echo "$STATE_FRONTMATTER" | grep "^active_bots:" | sed "s/active_bots: *//" | tr -d ' ' || true)
    PR_CODEX_MODEL=$(echo "$STATE_FRONTMATTER" | grep "^codex_model:" | sed "s/codex_model: *//" | tr -d ' ' || true)
    PR_CODEX_EFFORT=$(echo "$STATE_FRONTMATTER" | grep "^codex_effort:" | sed "s/codex_effort: *//" | tr -d ' ' || true)
    PR_CODEX_TIMEOUT=$(echo "$STATE_FRONTMATTER" | grep "^codex_timeout:" | sed "s/codex_timeout: *//" | tr -d ' ' || true)
    PR_POLL_INTERVAL=$(echo "$STATE_FRONTMATTER" | grep "^poll_interval:" | sed "s/poll_interval: *//" | tr -d ' ' || true)
    PR_POLL_TIMEOUT=$(echo "$STATE_FRONTMATTER" | grep "^poll_timeout:" | sed "s/poll_timeout: *//" | tr -d ' ' || true)
    PR_STARTED_AT=$(echo "$STATE_FRONTMATTER" | grep "^started_at:" | sed "s/started_at: *//" || true)

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

if [[ -z "$PR_ACTIVE_BOTS" ]]; then
    echo "All bots have approved. PR loop complete!" >&2
    mv "$STATE_FILE" "$LOOP_DIR/complete-state.md"
    exit 0
fi

# ========================================
# Poll for New Bot Reviews
# ========================================

echo "Polling for new bot reviews on PR #$PR_NUMBER..." >&2
echo "Active bots: $PR_ACTIVE_BOTS" >&2
echo "Poll interval: ${PR_POLL_INTERVAL}s, Timeout: ${PR_POLL_TIMEOUT}s per bot" >&2

POLL_SCRIPT="$PLUGIN_ROOT/scripts/poll-pr-reviews.sh"
COMMENT_FILE="$LOOP_DIR/round-${PR_CURRENT_ROUND}-pr-comment.md"

# Get current timestamp for filtering
POLL_START_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# If this is not round 0, use the started_at time from state or resolve file timestamp
if [[ "$PR_CURRENT_ROUND" -gt 0 && -f "$RESOLVE_FILE" ]]; then
    # Use the file modification time as the "after" timestamp
    if [[ "$(uname)" == "Darwin" ]]; then
        AFTER_TIMESTAMP=$(stat -f "%Sm" -t "%Y-%m-%dT%H:%M:%SZ" "$RESOLVE_FILE" 2>/dev/null || echo "$POLL_START_TIME")
    else
        AFTER_TIMESTAMP=$(stat -c "%y" "$RESOLVE_FILE" 2>/dev/null | sed 's/ /T/;s/\..*$/Z/' || echo "$POLL_START_TIME")
    fi
else
    # For round 0, use started_at from state
    AFTER_TIMESTAMP="${PR_STARTED_AT:-$POLL_START_TIME}"
fi

# Calculate max poll attempts
MAX_POLL_ATTEMPTS=$((PR_POLL_TIMEOUT / PR_POLL_INTERVAL))
POLL_ATTEMPT=0
NEW_COMMENTS=""

while [[ $POLL_ATTEMPT -lt $MAX_POLL_ATTEMPTS ]]; do
    POLL_ATTEMPT=$((POLL_ATTEMPT + 1))
    echo "Poll attempt $POLL_ATTEMPT/$MAX_POLL_ATTEMPTS..." >&2

    # Poll for new comments
    POLL_RESULT=$("$POLL_SCRIPT" "$PR_NUMBER" --after "$AFTER_TIMESTAMP" --bots "$PR_ACTIVE_BOTS" 2>/dev/null) || {
        echo "Warning: Poll script failed, retrying..." >&2
        sleep "$PR_POLL_INTERVAL"
        continue
    }

    # Check if we got new comments
    HAS_NEW=$(echo "$POLL_RESULT" | jq -r '.has_new_comments' 2>/dev/null || echo "false")

    if [[ "$HAS_NEW" == "true" ]]; then
        NEW_COMMENTS="$POLL_RESULT"
        echo "New bot reviews received!" >&2
        break
    fi

    # Check for cancel signal
    if [[ -f "$LOOP_DIR/.cancel-requested" ]]; then
        echo "Cancel requested, exiting poll loop..." >&2
        exit 0
    fi

    if [[ $POLL_ATTEMPT -lt $MAX_POLL_ATTEMPTS ]]; then
        echo "No new reviews yet, waiting ${PR_POLL_INTERVAL}s..." >&2
        sleep "$PR_POLL_INTERVAL"
    fi
done

# ========================================
# Handle Poll Timeout
# ========================================

if [[ -z "$NEW_COMMENTS" ]]; then
    echo "Poll timeout reached without new bot reviews." >&2

    REASON="# Bot Review Timeout

No new reviews received from bots after ${PR_POLL_TIMEOUT} seconds.

**Active bots waiting for:** $PR_ACTIVE_BOTS

This might mean:
- The bots haven't been triggered (did you comment @bot on the PR?)
- The bots are slow to respond
- The bots are not enabled on this repository

**Options:**
1. Comment on the PR to trigger bot reviews:
   \`\`\`bash
   gh pr comment $PR_NUMBER --body \"@claude @chatgpt-codex-connector please review the latest changes\"
   \`\`\`
2. Wait and try exiting again
3. Cancel the loop: \`/humanize:cancel-pr-loop\`"

    jq -n --arg reason "$REASON" --arg msg "PR Loop: Bot review timeout" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

# ========================================
# Save New Comments
# ========================================

# Extract and save comments
COMMENTS_JSON=$(echo "$NEW_COMMENTS" | jq -r '.comments')
BOTS_RESPONDED=$(echo "$NEW_COMMENTS" | jq -r '.bots_responded | join(", ")')

# Format comments for human reading
NEW_COMMENT_FILE="$LOOP_DIR/round-${PR_CURRENT_ROUND}-new-comments.md"

cat > "$NEW_COMMENT_FILE" << EOF
# New Bot Reviews (Round $PR_CURRENT_ROUND)

Bots that responded: $BOTS_RESPONDED
Fetched at: $(date -u +%Y-%m-%dT%H:%M:%SZ)

---

EOF

echo "$COMMENTS_JSON" | jq -r '
    .[] |
    "## Comment from \(.author)\n\n" +
    "- **Type**: \(.type | gsub("_"; " "))\n" +
    "- **Time**: \(.created_at)\n" +
    (if .path then "- **File**: `\(.path)`\(if .line then " (line \(.line))" else "" end)\n" else "" end) +
    (if .state then "- **Status**: \(.state)\n" else "" end) +
    "\n\(.body)\n\n---\n"
' >> "$NEW_COMMENT_FILE"

echo "New comments saved to: $NEW_COMMENT_FILE" >&2

# ========================================
# Run Local Codex Review of Bot Feedback
# ========================================

CHECK_FILE="$LOOP_DIR/round-${PR_CURRENT_ROUND}-pr-check.md"
FEEDBACK_FILE="$LOOP_DIR/round-${PR_CURRENT_ROUND}-pr-feedback.md"

echo "Running local Codex review of bot feedback..." >&2

# Build Codex prompt
CODEX_PROMPT_FILE="$LOOP_DIR/round-${PR_CURRENT_ROUND}-codex-prompt.md"
BOT_REVIEW_CONTENT=$(cat "$NEW_COMMENT_FILE")

cat > "$CODEX_PROMPT_FILE" << EOF
# PR Review Validation

Analyze the following bot reviews and determine if they indicate approval or issues.

## Bot Reviews
$BOT_REVIEW_CONTENT

## Your Task

1. Analyze each bot's review
2. Determine if the bot is approving or finding issues
3. For approvals, look for phrases like:
   - "Didn't find any major issues"
   - "LGTM"
   - "Approved"
   - "No issues found"
4. For issues, extract the specific problems identified

## Output Format

Write your analysis to $CHECK_FILE with the following structure:

### Bot Analysis
For each bot, state whether they APPROVE or have ISSUES.

### Issues Found (if any)
List specific issues that need to be addressed.

### Recommendation
- If ALL bots approve: End with "ALL_APPROVED" on its own line
- If issues remain: End with "ISSUES_REMAINING" on its own line
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
# Check Codex Result
# ========================================

CHECK_CONTENT=$(cat "$CHECK_FILE")
LAST_LINE=$(echo "$CHECK_CONTENT" | grep -v '^[[:space:]]*$' | tail -1)
LAST_LINE_TRIMMED=$(echo "$LAST_LINE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

if [[ "$LAST_LINE_TRIMMED" == "ALL_APPROVED" ]]; then
    echo "All bots have approved! PR loop complete." >&2
    mv "$STATE_FILE" "$LOOP_DIR/complete-state.md"
    exit 0
fi

# ========================================
# Issues Remaining - Continue Loop
# ========================================

# Update state file for next round
TEMP_FILE="${STATE_FILE}.tmp.$$"
sed "s/^current_round: .*/current_round: $NEXT_ROUND/" "$STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$STATE_FILE"

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
   gh pr comment $PR_NUMBER --body "@claude @chatgpt-codex-connector please review the latest changes"
   \`\`\`
5. Write your resolution summary to: $LOOP_DIR/round-${NEXT_ROUND}-pr-resolve.md

---

Note: You are on round $NEXT_ROUND of $PR_MAX_ITERATIONS.
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
