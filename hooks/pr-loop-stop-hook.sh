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

    # Parse active_bots as YAML list (lines starting with "  - ")
    # Extract lines between "active_bots:" and next field, then parse list items
    declare -g -a PR_ACTIVE_BOTS_ARRAY=()
    local in_active_bots=false
    while IFS= read -r line; do
        if [[ "$line" =~ ^active_bots: ]]; then
            in_active_bots=true
            # Check if it's inline format: active_bots: value
            local inline_value="${line#*: }"
            if [[ -n "$inline_value" && "$inline_value" != "active_bots:" ]]; then
                # Old comma-separated format for backwards compatibility
                IFS=',' read -ra PR_ACTIVE_BOTS_ARRAY <<< "$inline_value"
                in_active_bots=false
            fi
            continue
        fi
        if [[ "$in_active_bots" == "true" ]]; then
            if [[ "$line" =~ ^[[:space:]]+-[[:space:]]+ ]]; then
                # Extract bot name from "  - botname"
                local bot_name="${line#*- }"
                bot_name=$(echo "$bot_name" | tr -d ' ')
                if [[ -n "$bot_name" ]]; then
                    PR_ACTIVE_BOTS_ARRAY+=("$bot_name")
                fi
            elif [[ "$line" =~ ^[a-zA-Z_] ]]; then
                # New field started, stop parsing active_bots
                in_active_bots=false
            fi
        fi
    done <<< "$STATE_FRONTMATTER"

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
PR_BOT_MENTION_STRING=""
for bot in "${PR_ACTIVE_BOTS_ARRAY[@]}"; do
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
# Poll for New Bot Reviews (per-bot tracking)
# ========================================

echo "Polling for new bot reviews on PR #$PR_NUMBER..." >&2
echo "Active bots: $PR_ACTIVE_BOTS_DISPLAY" >&2
echo "Poll interval: ${PR_POLL_INTERVAL}s, Timeout: ${PR_POLL_TIMEOUT}s per bot" >&2

POLL_SCRIPT="$PLUGIN_ROOT/scripts/poll-pr-reviews.sh"

# Use correct file naming: round-N-pr-comment.md
COMMENT_FILE="$LOOP_DIR/round-${PR_CURRENT_ROUND}-pr-comment.md"

# Get timestamp for filtering (use resolve file mtime or started_at)
POLL_START_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if [[ "$PR_CURRENT_ROUND" -gt 0 && -f "$RESOLVE_FILE" ]]; then
    if [[ "$(uname)" == "Darwin" ]]; then
        AFTER_TIMESTAMP=$(stat -f "%Sm" -t "%Y-%m-%dT%H:%M:%SZ" "$RESOLVE_FILE" 2>/dev/null || echo "$POLL_START_TIME")
    else
        AFTER_TIMESTAMP=$(stat -c "%y" "$RESOLVE_FILE" 2>/dev/null | sed 's/ /T/;s/\..*$/Z/' || echo "$POLL_START_TIME")
    fi
else
    AFTER_TIMESTAMP="${PR_STARTED_AT:-$POLL_START_TIME}"
fi

# Track which bots have responded
declare -A BOTS_RESPONDED
for bot in "${PR_ACTIVE_BOTS_ARRAY[@]}"; do
    BOTS_RESPONDED["$bot"]="false"
done

# Collect all new comments
ALL_NEW_COMMENTS="[]"

# Poll until ALL active bots respond (with per-bot timeout)
TOTAL_POLL_START=$(date +%s)
MAX_TOTAL_TIMEOUT=$((PR_POLL_TIMEOUT * ${#PR_ACTIVE_BOTS_ARRAY[@]}))

while true; do
    # Check if all bots have responded
    ALL_RESPONDED=true
    for bot in "${PR_ACTIVE_BOTS_ARRAY[@]}"; do
        if [[ "${BOTS_RESPONDED[$bot]}" != "true" ]]; then
            ALL_RESPONDED=false
            break
        fi
    done

    if [[ "$ALL_RESPONDED" == "true" ]]; then
        echo "All active bots have responded!" >&2
        break
    fi

    # Check total timeout
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - TOTAL_POLL_START))
    if [[ $ELAPSED -ge $MAX_TOTAL_TIMEOUT ]]; then
        echo "Total poll timeout reached ($MAX_TOTAL_TIMEOUT seconds)." >&2
        break
    fi

    # Check for cancel signal
    if [[ -f "$LOOP_DIR/.cancel-requested" ]]; then
        echo "Cancel requested, exiting poll loop..." >&2
        exit 0
    fi

    echo "Poll attempt (elapsed: ${ELAPSED}s / ${MAX_TOTAL_TIMEOUT}s)..." >&2

    # Build comma-separated list of bots we're still waiting for
    WAITING_BOTS=""
    for bot in "${PR_ACTIVE_BOTS_ARRAY[@]}"; do
        if [[ "${BOTS_RESPONDED[$bot]}" != "true" ]]; then
            if [[ -n "$WAITING_BOTS" ]]; then
                WAITING_BOTS="${WAITING_BOTS},${bot}"
            else
                WAITING_BOTS="$bot"
            fi
        fi
    done

    # Poll for new comments from bots we're waiting for
    POLL_RESULT=$("$POLL_SCRIPT" "$PR_NUMBER" --after "$AFTER_TIMESTAMP" --bots "$WAITING_BOTS" 2>/dev/null) || {
        echo "Warning: Poll script failed, retrying..." >&2
        sleep "$PR_POLL_INTERVAL"
        continue
    }

    # Check which bots responded
    RESPONDED_BOTS=$(echo "$POLL_RESULT" | jq -r '.bots_responded[]' 2>/dev/null || true)
    for responded_bot in $RESPONDED_BOTS; do
        # Normalize bot name (remove [bot] suffix if present)
        responded_bot_clean=$(echo "$responded_bot" | sed 's/\[bot\]$//')
        for bot in "${PR_ACTIVE_BOTS_ARRAY[@]}"; do
            if [[ "$responded_bot_clean" == "$bot" || "$responded_bot" == "${bot}[bot]" ]]; then
                BOTS_RESPONDED["$bot"]="true"
                echo "Bot '$bot' has responded!" >&2
            fi
        done
    done

    # Collect new comments
    NEW_COMMENTS=$(echo "$POLL_RESULT" | jq -r '.comments' 2>/dev/null || echo "[]")
    if [[ "$NEW_COMMENTS" != "[]" && "$NEW_COMMENTS" != "null" ]]; then
        ALL_NEW_COMMENTS=$(echo "$ALL_NEW_COMMENTS $NEW_COMMENTS" | jq -s 'add')
    fi

    sleep "$PR_POLL_INTERVAL"
done

# ========================================
# Handle No Responses
# ========================================

COMMENT_COUNT=$(echo "$ALL_NEW_COMMENTS" | jq 'length' 2>/dev/null || echo "0")

if [[ "$COMMENT_COUNT" == "0" ]]; then
    echo "No new bot reviews received." >&2

    # Build list of bots that didn't respond
    MISSING_BOTS=""
    for bot in "${PR_ACTIVE_BOTS_ARRAY[@]}"; do
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

# Format comments grouped by bot
cat > "$COMMENT_FILE" << EOF
# Bot Reviews (Round $PR_CURRENT_ROUND)

Fetched at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Bots expected: $PR_ACTIVE_BOTS_DISPLAY

---

EOF

# Group comments by bot
for bot in "${PR_ACTIVE_BOTS_ARRAY[@]}"; do
    BOT_COMMENTS=$(echo "$ALL_NEW_COMMENTS" | jq -r --arg bot "$bot" --arg botfull "${bot}[bot]" '
        [.[] | select(.author == $bot or .author == $botfull)]
    ')
    BOT_COUNT=$(echo "$BOT_COMMENTS" | jq 'length')

    if [[ "$BOT_COUNT" -gt 0 ]]; then
        echo "## Comments from ${bot}[bot]" >> "$COMMENT_FILE"
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
        echo "## Comments from ${bot}[bot]" >> "$COMMENT_FILE"
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

CHECK_FILE="$LOOP_DIR/round-${PR_CURRENT_ROUND}-pr-check.md"
FEEDBACK_FILE="$LOOP_DIR/round-${PR_CURRENT_ROUND}-pr-feedback.md"

echo "Running local Codex review of bot feedback..." >&2

# Build Codex prompt with per-bot analysis
CODEX_PROMPT_FILE="$LOOP_DIR/round-${PR_CURRENT_ROUND}-codex-prompt.md"
BOT_REVIEW_CONTENT=$(cat "$COMMENT_FILE")

# Build list of expected bots for Codex
EXPECTED_BOTS_LIST=""
for bot in "${PR_ACTIVE_BOTS_ARRAY[@]}"; do
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

# ========================================
# Update active_bots in state file
# ========================================

# Extract approved bots from Codex output and remove them from active_bots
# Look for "### Approved Bots" section
APPROVED_SECTION=$(sed -n '/### Approved Bots/,/^###/p' "$CHECK_FILE" | grep -v '^###' || true)

# Build new active_bots array
declare -a NEW_ACTIVE_BOTS=()
for bot in "${PR_ACTIVE_BOTS_ARRAY[@]}"; do
    # Check if this bot is in the approved list
    if echo "$APPROVED_SECTION" | grep -qi "$bot"; then
        echo "Removing '$bot' from active_bots (approved)" >&2
    else
        NEW_ACTIVE_BOTS+=("$bot")
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

# Create updated state file
{
    echo "---"
    echo "current_round: $NEXT_ROUND"
    echo "max_iterations: $PR_MAX_ITERATIONS"
    echo "pr_number: $PR_NUMBER"
    echo "start_branch: $PR_START_BRANCH"
    echo "active_bots:${NEW_ACTIVE_BOTS_YAML}"
    echo "codex_model: $PR_CODEX_MODEL"
    echo "codex_effort: $PR_CODEX_EFFORT"
    echo "codex_timeout: $PR_CODEX_TIMEOUT"
    echo "poll_interval: $PR_POLL_INTERVAL"
    echo "poll_timeout: $PR_POLL_TIMEOUT"
    echo "started_at: $PR_STARTED_AT"
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
