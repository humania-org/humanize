#!/bin/bash
#
# Stop Hook for RLCR loop
#
# Intercepts Claude's exit attempts and uses Codex to review work.
# If Codex doesn't confirm completion, blocks exit and feeds review back.
#
# State directory: .humanize/rlcr/<timestamp>/
# State file: state.md (current_round, max_iterations, codex config)
# Summary file: round-N-summary.md (Claude's work summary)
# Review prompt: round-N-review-prompt.md (prompt sent to Codex)
# Review result: round-N-review-result.md (Codex's review)
#

set -euo pipefail

# ========================================
# Default Configuration
# ========================================

DEFAULT_CODEX_MODEL="gpt-5.2-codex"
DEFAULT_CODEX_EFFORT="high"
DEFAULT_CODEX_TIMEOUT=5400

# ========================================
# Read Hook Input
# ========================================

HOOK_INPUT=$(cat)

# NOTE: We intentionally do NOT check stop_hook_active here.
# For iterative loops, stop_hook_active will be true when Claude is continuing
# from a previous blocked stop. We WANT to run Codex review each iteration.
# Loop termination is controlled by:
# - No active loop directory (no state.md) -> exit early below
# - Codex outputs MARKER_COMPLETE -> allow exit
# - current_round >= max_iterations -> allow exit

# ========================================
# Find Active Loop
# ========================================

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
LOOP_BASE_DIR="$PROJECT_ROOT/.humanize/rlcr"

# Source shared loop functions and template loader
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib/loop-common.sh"

# Source portable timeout wrapper for git operations
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$PLUGIN_ROOT/scripts/portable-timeout.sh"

# Default timeout for git operations (30 seconds)
GIT_TIMEOUT=30

# Template directory is set by loop-common.sh via template-loader.sh

LOOP_DIR=$(find_active_loop "$LOOP_BASE_DIR")

# If no active loop, allow exit
if [[ -z "$LOOP_DIR" ]]; then
    exit 0
fi

STATE_FILE="$LOOP_DIR/state.md"

# ========================================
# Parse State File (using shared function)
# ========================================

if [[ ! -f "$STATE_FILE" ]]; then
    exit 0
fi

# Use shared parsing function from loop-common.sh
parse_state_file "$STATE_FILE"

# Map STATE_* variables to local names for backward compatibility
PLAN_TRACKED="$STATE_PLAN_TRACKED"
START_BRANCH="$STATE_START_BRANCH"
PLAN_FILE="$STATE_PLAN_FILE"
CURRENT_ROUND="$STATE_CURRENT_ROUND"
MAX_ITERATIONS="$STATE_MAX_ITERATIONS"
PUSH_EVERY_ROUND="$STATE_PUSH_EVERY_ROUND"
CODEX_MODEL="${STATE_CODEX_MODEL:-$DEFAULT_CODEX_MODEL}"
CODEX_EFFORT="${STATE_CODEX_EFFORT:-$DEFAULT_CODEX_EFFORT}"
CODEX_TIMEOUT="${STATE_CODEX_TIMEOUT:-${CODEX_TIMEOUT:-$DEFAULT_CODEX_TIMEOUT}}"

# Re-validate Codex Model and Effort for YAML safety (in case state.md was manually edited)
# Use same validation patterns as setup-rlcr-loop.sh
if [[ ! "$CODEX_MODEL" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "Error: Invalid codex_model in state file: $CODEX_MODEL" >&2
    end_loop "$LOOP_DIR" "$STATE_FILE" "$EXIT_UNEXPECTED"
    exit 0
fi
if [[ ! "$CODEX_EFFORT" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: Invalid codex_effort in state file: $CODEX_EFFORT" >&2
    end_loop "$LOOP_DIR" "$STATE_FILE" "$EXIT_UNEXPECTED"
    exit 0
fi

# Validate numeric fields early
if [[ ! "$CURRENT_ROUND" =~ ^[0-9]+$ ]]; then
    echo "Warning: State file corrupted (current_round), stopping loop" >&2
    end_loop "$LOOP_DIR" "$STATE_FILE" "$EXIT_UNEXPECTED"
    exit 0
fi

if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
    MAX_ITERATIONS=42
fi

# ========================================
# Quick-check 0: Schema Validation (v1.1.2+ fields)
# ========================================
# If schema is outdated, terminate loop as unexpected

if [[ -z "$PLAN_TRACKED" || -z "$START_BRANCH" ]]; then
    REASON="RLCR loop state file is missing required fields (plan_tracked or start_branch).

This indicates the loop was started with an older version of humanize.

**Options:**
1. Cancel the loop: \`/humanize:cancel-rlcr-loop\`
2. Update humanize plugin to version 1.1.2+
3. Restart the RLCR loop with the updated plugin"
    jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - state schema outdated" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

# ========================================
# Quick-check 0.5: Branch Consistency
# ========================================

# Use || GIT_EXIT_CODE=$? to prevent set -e from aborting on non-zero exit
CURRENT_BRANCH=$(run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null) || GIT_EXIT_CODE=$?
GIT_EXIT_CODE=${GIT_EXIT_CODE:-0}
if [[ $GIT_EXIT_CODE -ne 0 || -z "$CURRENT_BRANCH" ]]; then
    REASON="Git operation failed or timed out.

Cannot verify branch consistency. This may indicate:
- Git is not responding
- Repository is in an invalid state
- Network issues (if remote operations are involved)

Please check git status manually and try again."
    jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - git operation failed" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

if [[ -n "$START_BRANCH" && "$CURRENT_BRANCH" != "$START_BRANCH" ]]; then
    REASON="Git branch changed during RLCR loop.

Started on: $START_BRANCH
Current: $CURRENT_BRANCH

Branch switching is not allowed. Switch back to $START_BRANCH or cancel the loop."
    jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - branch changed" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

# ========================================
# Quick-check 0.6: Plan File Integrity
# ========================================

BACKUP_PLAN="$LOOP_DIR/plan.md"
FULL_PLAN_PATH="$PROJECT_ROOT/$PLAN_FILE"

# Check backup exists
if [[ ! -f "$BACKUP_PLAN" ]]; then
    REASON="Plan file backup not found in loop directory.

Please copy the plan file to the loop directory:
  cp \"$FULL_PLAN_PATH\" \"$BACKUP_PLAN\"

This backup is required for plan integrity verification."
    jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - plan backup missing" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

# Check original plan file still matches backup
if [[ ! -f "$FULL_PLAN_PATH" ]]; then
    REASON="Project plan file has been deleted.

Original: $PLAN_FILE
Backup available at: $BACKUP_PLAN

You can restore from backup if needed. Plan file modifications are not allowed during RLCR loop."
    jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - plan file deleted" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

# Check plan file integrity
# For tracked files: check both git status (uncommitted) AND content diff (committed changes)
# For gitignored files: check content diff only
if [[ "$PLAN_TRACKED" == "true" ]]; then
    # Tracked file: first check git status for uncommitted changes
    PLAN_GIT_STATUS=$(run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" status --porcelain "$PLAN_FILE" 2>/dev/null || echo "")
    if [[ -n "$PLAN_GIT_STATUS" ]]; then
        REASON="Plan file has uncommitted modifications.

File: $PLAN_FILE
Status: $PLAN_GIT_STATUS

This RLCR loop was started with --track-plan-file. Plan file modifications are not allowed during the loop."
        jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - plan file modified (uncommitted)" \
            '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
        exit 0
    fi
fi

# Always verify content matches backup (catches committed changes for tracked files)
if ! diff -q "$FULL_PLAN_PATH" "$BACKUP_PLAN" &>/dev/null; then
    FALLBACK="# Plan File Modified

The plan file \`$PLAN_FILE\` has been modified since the RLCR loop started.

**Modifying plan files is forbidden during an active RLCR loop.**

If you need to change the plan:
1. Cancel the current loop: \`/humanize:cancel-rlcr-loop\`
2. Update the plan file
3. Start a new loop: \`/humanize:start-rlcr-loop $PLAN_FILE\`

Backup available at: \`$BACKUP_PLAN\`"
    REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/plan-file-modified.md" "$FALLBACK" \
        "PLAN_FILE=$PLAN_FILE" \
        "BACKUP_PATH=$BACKUP_PLAN")
    jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - plan file modified" \
        '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
    exit 0
fi

# ========================================
# Quick Check: Are All Todos Completed?
# ========================================
# Before running expensive Codex review, check if Claude still has
# incomplete todos. If yes, block immediately and tell Claude to finish.

TODO_CHECKER="$SCRIPT_DIR/check-todos-from-transcript.py"

if [[ -f "$TODO_CHECKER" ]]; then
    # Pass hook input to the todo checker
    TODO_RESULT=$(echo "$HOOK_INPUT" | python3 "$TODO_CHECKER" 2>&1) || TODO_EXIT=$?
    TODO_EXIT=${TODO_EXIT:-0}

    if [[ "$TODO_EXIT" -eq 2 ]]; then
        # Parse error - block and surface the error
        REASON="Todo checker encountered a parse error.

Error: $TODO_RESULT

This may indicate an issue with the hook input or transcript format.
Please try again or cancel the loop if this persists."
        jq -n \
            --arg reason "$REASON" \
            --arg msg "Loop: Blocked - todo checker parse error" \
            '{
                "decision": "block",
                "reason": $reason,
                "systemMessage": $msg
            }'
        exit 0
    fi

    if [[ "$TODO_EXIT" -eq 1 ]]; then
        # Incomplete todos found - block immediately without Codex review
        # Extract the incomplete todo list from the result
        INCOMPLETE_LIST=$(echo "$TODO_RESULT" | tail -n +2)

        FALLBACK="# Incomplete Todos

Complete these tasks before exiting:

{{INCOMPLETE_LIST}}"
        REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/incomplete-todos.md" "$FALLBACK" \
            "INCOMPLETE_LIST=$INCOMPLETE_LIST")

        jq -n \
            --arg reason "$REASON" \
            --arg msg "Loop: Blocked - incomplete todos detected, please finish all tasks first" \
            '{
                "decision": "block",
                "reason": $reason,
                "systemMessage": $msg
            }'
        exit 0
    fi
fi

# ========================================
# Cache Git Status Output
# ========================================
# Cache git status output to avoid calling it multiple times.
# Used by both large file check and git clean check below.
# IMPORTANT: Fail-closed on git failures to prevent bypassing checks.

GIT_STATUS_CACHED=""
GIT_IS_REPO=false

if command -v git &>/dev/null && run_with_timeout "$GIT_TIMEOUT" git rev-parse --git-dir &>/dev/null 2>&1; then
    GIT_IS_REPO=true
    # Capture exit code to detect timeout/failure - do NOT use || echo "" which would fail-open
    GIT_STATUS_EXIT=0
    GIT_STATUS_CACHED=$(run_with_timeout "$GIT_TIMEOUT" git status --porcelain 2>/dev/null) || GIT_STATUS_EXIT=$?

    if [[ $GIT_STATUS_EXIT -ne 0 ]]; then
        # Git status failed or timed out - fail-closed by blocking exit
        FALLBACK="# Git Status Failed

Git status operation failed or timed out (exit code {{GIT_STATUS_EXIT}}).

Cannot verify repository state. Please check git status manually and try again."
        REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/git-status-failed.md" "$FALLBACK" \
            "GIT_STATUS_EXIT=$GIT_STATUS_EXIT")
        jq -n --arg reason "$REASON" --arg msg "Loop: Blocked - git status failed (exit $GIT_STATUS_EXIT)" \
            '{"decision": "block", "reason": $reason, "systemMessage": $msg}'
        exit 0
    fi
fi

# ========================================
# Quick Check: Large File Detection
# ========================================
# Check if any tracked or new files exceed the line limit.
# Large files should be split into smaller modules.

MAX_LINES=2000

if [[ "$GIT_IS_REPO" == "true" ]]; then
    LARGE_FILES=""

    while IFS= read -r line; do
        # Skip empty lines
        if [ -z "$line" ]; then
            continue
        fi

        # Extract filename (skip first 3 chars: "XY ")
        filename="${line#???}"

        # Handle renames: "old -> new" format
        case "$filename" in
            *" -> "*) filename="${filename##* -> }" ;;
        esac

        # Skip deleted files
        if [ ! -f "$filename" ]; then
            continue
        fi

        # Get file extension and convert to lowercase
        ext="${filename##*.}"
        ext_lower=$(to_lower "$ext")

        # Determine file type based on extension
        case "$ext_lower" in
            py|js|ts|tsx|jsx|java|c|cpp|cc|cxx|h|hpp|cs|go|rs|rb|php|swift|kt|kts|scala|sh|bash|zsh)
                file_type="code"
                ;;
            md|rst|txt|adoc|asciidoc)
                file_type="documentation"
                ;;
            *)
                continue
                ;;
        esac

        # Count lines and trim whitespace (portable across shells)
        line_count=$(wc -l < "$filename" 2>/dev/null | tr -d ' ') || continue

        # Validate line_count is numeric before comparison
        [[ "$line_count" =~ ^[0-9]+$ ]] || continue

        if [ "$line_count" -gt "$MAX_LINES" ]; then
            LARGE_FILES="${LARGE_FILES}
- \`${filename}\`: ${line_count} lines (${file_type} file)"
        fi
    done <<< "$GIT_STATUS_CACHED"

    if [ -n "$LARGE_FILES" ]; then
        FALLBACK="# Large Files Detected

Files exceeding {{MAX_LINES}} lines:

{{LARGE_FILES}}

Split these into smaller modules before continuing."
        REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/large-files.md" "$FALLBACK" \
            "MAX_LINES=$MAX_LINES" \
            "LARGE_FILES=$LARGE_FILES")

        jq -n \
            --arg reason "$REASON" \
            --arg msg "Loop: Blocked - large files detected (>${MAX_LINES} lines), please split into smaller modules" \
            '{
                "decision": "block",
                "reason": $reason,
                "systemMessage": $msg
            }'
        exit 0
    fi
fi

# ========================================
# Quick Check: Git Clean and Pushed?
# ========================================
# Before running expensive Codex review, check if all changes have been
# committed and pushed. This ensures work is properly saved.

# Use cached git status from above
if [[ "$GIT_IS_REPO" == "true" ]]; then
    GIT_ISSUES=""
    SPECIAL_NOTES=""

    # Check for uncommitted changes (staged or unstaged) using cached status
    if [[ -n "$GIT_STATUS_CACHED" ]]; then
        GIT_ISSUES="uncommitted changes"

        # Check for special cases in untracked files
        UNTRACKED=$(echo "$GIT_STATUS_CACHED" | grep '^??' || true)

        # Check if .humanize* directories are untracked (includes .humanize/ and any legacy .humanize-* dirs)
        if echo "$UNTRACKED" | grep -q '\.humanize'; then
            HUMANIZE_LOCAL_NOTE=$(load_template "$TEMPLATE_DIR" "block/git-not-clean-humanize-local.md" 2>/dev/null)
            if [[ -z "$HUMANIZE_LOCAL_NOTE" ]]; then
                HUMANIZE_LOCAL_NOTE="Note: .humanize* directories are intentionally untracked."
            fi
            SPECIAL_NOTES="$SPECIAL_NOTES$HUMANIZE_LOCAL_NOTE"
        fi

        # Check for other untracked files (potential artifacts)
        OTHER_UNTRACKED=$(echo "$UNTRACKED" | grep -v '\.humanize' || true)
        if [[ -n "$OTHER_UNTRACKED" ]]; then
            UNTRACKED_NOTE=$(load_template "$TEMPLATE_DIR" "block/git-not-clean-untracked.md" 2>/dev/null)
            if [[ -z "$UNTRACKED_NOTE" ]]; then
                UNTRACKED_NOTE="Review untracked files - add to .gitignore or commit them."
            fi
            SPECIAL_NOTES="$SPECIAL_NOTES$UNTRACKED_NOTE"
        fi
    fi

    # Block if there are uncommitted changes
    if [[ -n "$GIT_ISSUES" ]]; then
        # Git has uncommitted changes - block and remind Claude to commit
        FALLBACK="# Git Not Clean

Detected: {{GIT_ISSUES}}

Please commit all changes before exiting.
{{SPECIAL_NOTES}}"
        REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/git-not-clean.md" "$FALLBACK" \
            "GIT_ISSUES=$GIT_ISSUES" \
            "SPECIAL_NOTES=$SPECIAL_NOTES")

        jq -n \
            --arg reason "$REASON" \
            --arg msg "Loop: Blocked - $GIT_ISSUES detected, please commit first" \
            '{
                "decision": "block",
                "reason": $reason,
                "systemMessage": $msg
            }'
        exit 0
    fi

    # ========================================
    # Check Unpushed Commits (only when push_every_round is true)
    # ========================================

    if [[ "$PUSH_EVERY_ROUND" == "true" ]]; then
        # Check if local branch is ahead of remote (unpushed commits)
        GIT_AHEAD=$(run_with_timeout "$GIT_TIMEOUT" git status -sb 2>/dev/null | grep -o 'ahead [0-9]*' || true)
        if [[ -n "$GIT_AHEAD" ]]; then
            AHEAD_COUNT=$(echo "$GIT_AHEAD" | grep -o '[0-9]*')
            CURRENT_BRANCH=$(run_with_timeout "$GIT_TIMEOUT" git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

            FALLBACK="# Unpushed Commits

You have {{AHEAD_COUNT}} unpushed commit(s) on branch {{CURRENT_BRANCH}}.

Please push before exiting."
            REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/unpushed-commits.md" "$FALLBACK" \
                "AHEAD_COUNT=$AHEAD_COUNT" \
                "CURRENT_BRANCH=$CURRENT_BRANCH")

            jq -n \
                --arg reason "$REASON" \
                --arg msg "Loop: Blocked - $AHEAD_COUNT unpushed commit(s) detected, please push first" \
                '{
                    "decision": "block",
                    "reason": $reason,
                    "systemMessage": $msg
                }'
            exit 0
        fi
    fi
fi

# ========================================
# Check Summary File Exists
# ========================================

SUMMARY_FILE="$LOOP_DIR/round-${CURRENT_ROUND}-summary.md"

if [[ ! -f "$SUMMARY_FILE" ]]; then
    # Summary file doesn't exist - Claude didn't write it
    # Block exit and remind Claude to write summary

    FALLBACK="# Work Summary Missing

Please write your work summary to: {{SUMMARY_FILE}}"
    REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/work-summary-missing.md" "$FALLBACK" \
        "SUMMARY_FILE=$SUMMARY_FILE")

    jq -n \
        --arg reason "$REASON" \
        --arg msg "Loop: Summary file missing for round $CURRENT_ROUND" \
        '{
            "decision": "block",
            "reason": $reason,
            "systemMessage": $msg
        }'
    exit 0
fi

# ========================================
# Check Goal Tracker Initialization (Round 0 only)
# ========================================

GOAL_TRACKER_FILE="$LOOP_DIR/goal-tracker.md"

if [[ "$CURRENT_ROUND" -eq 0 ]] && [[ -f "$GOAL_TRACKER_FILE" ]]; then
    # Check if goal-tracker.md still contains placeholder text
    # Extract each section and check for generic placeholder pattern within that section
    # This avoids coupling to specific placeholder wording and prevents false positives
    # from stray mentions of placeholder text elsewhere in the file

    HAS_GOAL_PLACEHOLDER=false
    HAS_AC_PLACEHOLDER=false
    HAS_TASKS_PLACEHOLDER=false

    # Extract Ultimate Goal section (### Ultimate Goal to next heading)
    # Use awk to extract lines between start and end patterns, excluding end pattern
    GOAL_SECTION=$(awk '/^### Ultimate Goal/{found=1; next} /^##/{found=0} found' "$GOAL_TRACKER_FILE" 2>/dev/null)
    # Check for generic placeholder pattern "[To be " within this section
    if echo "$GOAL_SECTION" | grep -qE '\[To be [a-z]'; then
        HAS_GOAL_PLACEHOLDER=true
    fi

    # Extract Acceptance Criteria section (### Acceptance Criteria to next heading)
    AC_SECTION=$(awk '/^### Acceptance Criteria/{found=1; next} /^##/{found=0} found' "$GOAL_TRACKER_FILE" 2>/dev/null)
    # Check for generic placeholder pattern "[To be " within this section
    if echo "$AC_SECTION" | grep -qE '\[To be [a-z]'; then
        HAS_AC_PLACEHOLDER=true
    fi

    # Extract Active Tasks section (#### Active Tasks to next heading or EOF)
    # Active Tasks is a level-4 heading, so match any ## or higher
    TASKS_SECTION=$(awk '/^#### Active Tasks/{found=1; next} /^##/{found=0} found' "$GOAL_TRACKER_FILE" 2>/dev/null)
    # Check for generic placeholder pattern "[To be " within this section
    if echo "$TASKS_SECTION" | grep -qE '\[To be [a-z]'; then
        HAS_TASKS_PLACEHOLDER=true
    fi

    # Build list of missing items
    MISSING_ITEMS=""
    if [[ "$HAS_GOAL_PLACEHOLDER" == "true" ]]; then
        MISSING_ITEMS="$MISSING_ITEMS
- **Ultimate Goal**: Still contains placeholder text"
    fi
    if [[ "$HAS_AC_PLACEHOLDER" == "true" ]]; then
        MISSING_ITEMS="$MISSING_ITEMS
- **Acceptance Criteria**: Still contains placeholder text"
    fi
    if [[ "$HAS_TASKS_PLACEHOLDER" == "true" ]]; then
        MISSING_ITEMS="$MISSING_ITEMS
- **Active Tasks**: Still contains placeholder text"
    fi

    if [[ -n "$MISSING_ITEMS" ]]; then
        FALLBACK="# Goal Tracker Not Initialized

Please fill in the Goal Tracker ({{GOAL_TRACKER_FILE}}):
{{MISSING_ITEMS}}"
        REASON=$(load_and_render_safe "$TEMPLATE_DIR" "block/goal-tracker-not-initialized.md" "$FALLBACK" \
            "GOAL_TRACKER_FILE=$GOAL_TRACKER_FILE" \
            "MISSING_ITEMS=$MISSING_ITEMS")

        jq -n \
            --arg reason "$REASON" \
            --arg msg "Loop: Goal Tracker not initialized in Round 0" \
            '{
                "decision": "block",
                "reason": $reason,
                "systemMessage": $msg
            }'
        exit 0
    fi
fi

# ========================================
# Check Max Iterations
# ========================================

NEXT_ROUND=$((CURRENT_ROUND + 1))

if [[ $NEXT_ROUND -gt $MAX_ITERATIONS ]]; then
    echo "RLCR loop did not complete, but reached max iterations ($MAX_ITERATIONS). Exiting." >&2
    end_loop "$LOOP_DIR" "$STATE_FILE" "$EXIT_MAXITER"
    exit 0
fi

# ========================================
# Get Docs Path from Config
# ========================================

PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DOCS_PATH="docs"

# ========================================
# Build Codex Review Prompt
# ========================================

PROMPT_FILE="$LOOP_DIR/round-${CURRENT_ROUND}-prompt.md"
REVIEW_PROMPT_FILE="$LOOP_DIR/round-${CURRENT_ROUND}-review-prompt.md"
REVIEW_RESULT_FILE="$LOOP_DIR/round-${CURRENT_ROUND}-review-result.md"

SUMMARY_CONTENT=$(cat "$SUMMARY_FILE")

# Shared prompt section for Goal Tracker Update Requests (used in both Full Alignment and Regular reviews)
GOAL_TRACKER_SECTION_FALLBACK="## Goal Tracker Updates
If Claude's summary includes a Goal Tracker Update Request section, apply the requested changes to {{GOAL_TRACKER_FILE}}."
GOAL_TRACKER_UPDATE_SECTION=$(load_and_render_safe "$TEMPLATE_DIR" "codex/goal-tracker-update-section.md" "$GOAL_TRACKER_SECTION_FALLBACK" \
    "GOAL_TRACKER_FILE=$GOAL_TRACKER_FILE")

# Determine if this is a Full Alignment Check round (every 5 rounds)
FULL_ALIGNMENT_CHECK=false
if [[ $((CURRENT_ROUND % 5)) -eq 4 ]]; then
    FULL_ALIGNMENT_CHECK=true
fi

# Calculate derived values for templates
LOOP_TIMESTAMP=$(basename "$LOOP_DIR")
COMPLETED_ITERATIONS=$((CURRENT_ROUND + 1))
PREV_ROUND=$((CURRENT_ROUND - 1))
PREV_PREV_ROUND=$((CURRENT_ROUND - 2))

# Build the review prompt
FULL_ALIGNMENT_FALLBACK="# Full Alignment Review (Round {{CURRENT_ROUND}})

Review Claude's work against the plan and goal tracker. Check all goals are being met.

## Claude's Summary
{{SUMMARY_CONTENT}}

{{GOAL_TRACKER_UPDATE_SECTION}}

Write your review to {{REVIEW_RESULT_FILE}}. End with COMPLETE if done, or list issues."

REGULAR_REVIEW_FALLBACK="# Code Review (Round {{CURRENT_ROUND}})

Review Claude's work for this round.

## Claude's Summary
{{SUMMARY_CONTENT}}

{{GOAL_TRACKER_UPDATE_SECTION}}

Write your review to {{REVIEW_RESULT_FILE}}. End with COMPLETE if done, or list issues."

if [[ "$FULL_ALIGNMENT_CHECK" == "true" ]]; then
    # Full Alignment Check prompt
    load_and_render_safe "$TEMPLATE_DIR" "codex/full-alignment-review.md" "$FULL_ALIGNMENT_FALLBACK" \
        "CURRENT_ROUND=$CURRENT_ROUND" \
        "PLAN_FILE=$PLAN_FILE" \
        "SUMMARY_CONTENT=$SUMMARY_CONTENT" \
        "GOAL_TRACKER_FILE=$GOAL_TRACKER_FILE" \
        "DOCS_PATH=$DOCS_PATH" \
        "GOAL_TRACKER_UPDATE_SECTION=$GOAL_TRACKER_UPDATE_SECTION" \
        "COMPLETED_ITERATIONS=$COMPLETED_ITERATIONS" \
        "LOOP_TIMESTAMP=$LOOP_TIMESTAMP" \
        "PREV_ROUND=$PREV_ROUND" \
        "PREV_PREV_ROUND=$PREV_PREV_ROUND" \
        "REVIEW_RESULT_FILE=$REVIEW_RESULT_FILE" > "$REVIEW_PROMPT_FILE"

else
    # Regular review prompt with goal alignment section
    # Note: Pass all derived variables for consistency with full alignment template
    load_and_render_safe "$TEMPLATE_DIR" "codex/regular-review.md" "$REGULAR_REVIEW_FALLBACK" \
        "CURRENT_ROUND=$CURRENT_ROUND" \
        "PLAN_FILE=$PLAN_FILE" \
        "PROMPT_FILE=$PROMPT_FILE" \
        "SUMMARY_CONTENT=$SUMMARY_CONTENT" \
        "GOAL_TRACKER_FILE=$GOAL_TRACKER_FILE" \
        "DOCS_PATH=$DOCS_PATH" \
        "GOAL_TRACKER_UPDATE_SECTION=$GOAL_TRACKER_UPDATE_SECTION" \
        "COMPLETED_ITERATIONS=$COMPLETED_ITERATIONS" \
        "LOOP_TIMESTAMP=$LOOP_TIMESTAMP" \
        "PREV_ROUND=$PREV_ROUND" \
        "PREV_PREV_ROUND=$PREV_PREV_ROUND" \
        "REVIEW_RESULT_FILE=$REVIEW_RESULT_FILE" > "$REVIEW_PROMPT_FILE"
fi

# ========================================
# Run Codex Review
# ========================================

# First, check if codex command exists
if ! command -v codex &>/dev/null; then
    REASON="# Codex Not Found

The 'codex' command is not installed or not in PATH.
RLCR loop requires Codex CLI to perform code reviews.

**To fix:**
1. Install Codex CLI: https://github.com/openai/codex
2. Retry the exit

Or use \`/cancel-rlcr-loop\` to end the loop."

    cat <<EOF
{
    "decision": "block",
    "reason": $(echo "$REASON" | jq -Rs .)
}
EOF
    exit 0
fi

echo "Running Codex review for round $CURRENT_ROUND..." >&2

# Debug log files go to $HOME/.cache/humanize/<project-path>/<timestamp>/ to avoid polluting project dir
# This prevents Claude and Codex from reading these debug files during their work
# The project path is sanitized to replace problematic characters with '-'
LOOP_TIMESTAMP=$(basename "$LOOP_DIR")
# Sanitize project root path: replace / and other problematic chars with -
# This matches Claude Code's convention (e.g., /home/sihao/github.com/foo -> -home-sihao-github-com-foo)
SANITIZED_PROJECT_PATH=$(echo "$PROJECT_ROOT" | sed 's/[^a-zA-Z0-9._-]/-/g' | sed 's/--*/-/g')
CACHE_DIR="$HOME/.cache/humanize/$SANITIZED_PROJECT_PATH/$LOOP_TIMESTAMP"
mkdir -p "$CACHE_DIR"

CODEX_CMD_FILE="$CACHE_DIR/round-${CURRENT_ROUND}-codex-run.cmd"
CODEX_STDOUT_FILE="$CACHE_DIR/round-${CURRENT_ROUND}-codex-run.out"
CODEX_STDERR_FILE="$CACHE_DIR/round-${CURRENT_ROUND}-codex-run.log"

# Source portable timeout if available
TIMEOUT_SCRIPT="$PLUGIN_ROOT/scripts/portable-timeout.sh"
if [[ -f "$TIMEOUT_SCRIPT" ]]; then
    source "$TIMEOUT_SCRIPT"
else
    # Fallback: define run_with_timeout inline
    run_with_timeout() {
        local timeout_secs="$1"
        shift
        if command -v timeout &>/dev/null; then
            timeout "$timeout_secs" "$@"
        elif command -v gtimeout &>/dev/null; then
            gtimeout "$timeout_secs" "$@"
        else
            # No timeout command, just run directly
            "$@"
        fi
    }
fi

# Build Codex command arguments
# Note: codex exec reads prompt from stdin, writes to stdout, and we use -w to write to file
CODEX_ARGS=("-m" "$CODEX_MODEL")
if [[ -n "$CODEX_EFFORT" ]]; then
    CODEX_ARGS+=("-c" "model_reasoning_effort=${CODEX_EFFORT}")
fi
CODEX_ARGS+=("--full-auto" "-C" "$PROJECT_ROOT")

# Save the command for debugging
CODEX_PROMPT_CONTENT=$(cat "$REVIEW_PROMPT_FILE")
{
    echo "# Codex invocation debug info"
    echo "# Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Working directory: $PROJECT_ROOT"
    echo "# Timeout: $CODEX_TIMEOUT seconds"
    echo ""
    echo "codex exec ${CODEX_ARGS[*]} \"<prompt>\""
    echo ""
    echo "# Prompt content:"
    echo "$CODEX_PROMPT_CONTENT"
} > "$CODEX_CMD_FILE"

echo "Codex command saved to: $CODEX_CMD_FILE" >&2
echo "Running codex exec with timeout ${CODEX_TIMEOUT}s..." >&2

CODEX_EXIT_CODE=0
printf '%s' "$CODEX_PROMPT_CONTENT" | run_with_timeout "$CODEX_TIMEOUT" codex exec "${CODEX_ARGS[@]}" - \
    > "$CODEX_STDOUT_FILE" 2> "$CODEX_STDERR_FILE" || CODEX_EXIT_CODE=$?

echo "Codex exit code: $CODEX_EXIT_CODE" >&2
echo "Codex stdout saved to: $CODEX_STDOUT_FILE" >&2
echo "Codex stderr saved to: $CODEX_STDERR_FILE" >&2

# ========================================
# Check Codex Execution Result
# ========================================

# Helper function to print Codex failure and block exit for retry
# Uses JSON output with exit 0 (per Claude Code hooks spec) instead of exit 2
codex_failure_exit() {
    local error_type="$1"
    local details="$2"

    REASON="# Codex Review Failed

**Error Type:** $error_type

$details

**Debug files:**
- Command: $CODEX_CMD_FILE
- Stdout: $CODEX_STDOUT_FILE
- Stderr: $CODEX_STDERR_FILE

Please retry or use \`/cancel-rlcr-loop\` to end the loop."

    cat <<EOF
{
    "decision": "block",
    "reason": $(echo "$REASON" | jq -Rs .)
}
EOF
    exit 0
}

# Check 1: Codex exit code indicates failure
if [[ "$CODEX_EXIT_CODE" -ne 0 ]]; then
    STDERR_CONTENT=""
    if [[ -f "$CODEX_STDERR_FILE" ]]; then
        STDERR_CONTENT=$(tail -30 "$CODEX_STDERR_FILE" 2>/dev/null || echo "(unable to read stderr)")
    fi

    codex_failure_exit "Non-zero exit code ($CODEX_EXIT_CODE)" \
"Codex exited with code $CODEX_EXIT_CODE.
This may indicate:
  - Invalid arguments or configuration
  - Authentication failure
  - Network issues
  - Prompt format issues (e.g., multiline handling)

Stderr output (last 30 lines):
$STDERR_CONTENT"
fi

# Check if Codex created the review result file (it should write to workspace)
# If not, check if it wrote to stdout
if [[ ! -f "$REVIEW_RESULT_FILE" ]]; then
    # Codex might have written output to stdout instead
    if [[ -s "$CODEX_STDOUT_FILE" ]]; then
        echo "Codex output found in stdout, copying to review result file..." >&2
        if ! cp "$CODEX_STDOUT_FILE" "$REVIEW_RESULT_FILE" 2>/dev/null; then
            codex_failure_exit "Failed to copy stdout to review result file" \
"Codex wrote output to stdout but copying to review file failed.
Source: $CODEX_STDOUT_FILE
Target: $REVIEW_RESULT_FILE

This may indicate permission issues or disk space problems.
Check if the loop directory is writable."
        fi
    fi
fi

# Check 2: Review result file still doesn't exist
if [[ ! -f "$REVIEW_RESULT_FILE" ]]; then
    STDERR_CONTENT=""
    if [[ -f "$CODEX_STDERR_FILE" ]]; then
        STDERR_CONTENT=$(tail -30 "$CODEX_STDERR_FILE" 2>/dev/null || echo "(no stderr output)")
    fi

    STDOUT_CONTENT=""
    if [[ -f "$CODEX_STDOUT_FILE" ]]; then
        STDOUT_CONTENT=$(tail -30 "$CODEX_STDOUT_FILE" 2>/dev/null || echo "(no stdout output)")
    fi

    codex_failure_exit "Review result file not created" \
"Expected file: $REVIEW_RESULT_FILE
Codex completed (exit code 0) but did not create the review result file.

This may indicate:
  - Codex did not understand the prompt
  - Codex wrote to wrong path
  - Workspace/permission issues

Stdout (last 30 lines):
$STDOUT_CONTENT

Stderr (last 30 lines):
$STDERR_CONTENT"
fi

# Check 3: Review result file is empty
if [[ ! -s "$REVIEW_RESULT_FILE" ]]; then
    codex_failure_exit "Review result file is empty" \
"File exists but is empty: $REVIEW_RESULT_FILE
Codex created the file but wrote no content.

This may indicate Codex encountered an internal error."
fi

# Read the review result
REVIEW_CONTENT=$(cat "$REVIEW_RESULT_FILE")

# Check if the last non-empty line is exactly "COMPLETE" or "STOP"
# The word must be on its own line to avoid false positives like "CANNOT COMPLETE"
# Use strict matching: only whitespace before/after the word is allowed
LAST_LINE=$(echo "$REVIEW_CONTENT" | grep -v '^[[:space:]]*$' | tail -1)
LAST_LINE_TRIMMED=$(echo "$LAST_LINE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

# Handle COMPLETE - loop finished successfully
if [[ "$LAST_LINE_TRIMMED" == "$MARKER_COMPLETE" ]]; then
    if [[ "$FULL_ALIGNMENT_CHECK" == "true" ]]; then
        echo "Codex review passed. All goals achieved. Loop complete!" >&2
    else
        echo "Codex review passed. Loop complete!" >&2
    fi
    end_loop "$LOOP_DIR" "$STATE_FILE" "$EXIT_COMPLETE"
    exit 0
fi

# Handle STOP - circuit breaker triggered
if [[ "$LAST_LINE_TRIMMED" == "$MARKER_STOP" ]]; then
    echo "" >&2
    echo "========================================" >&2
    if [[ "$FULL_ALIGNMENT_CHECK" == "true" ]]; then
        echo "CIRCUIT BREAKER TRIGGERED" >&2
        echo "========================================" >&2
        echo "Codex detected development stagnation during Full Alignment Check (Round $CURRENT_ROUND)." >&2
        echo "The loop has been stopped to prevent further unproductive iterations." >&2
        echo "" >&2
        echo "Review the historical round files in .humanize/rlcr/$(basename "$LOOP_DIR")/ to understand what went wrong." >&2
        echo "Consider:" >&2
        echo "  - Revisiting the original plan for clarity" >&2
        echo "  - Breaking down the task into smaller pieces" >&2
        echo "  - Manually addressing the blocking issues" >&2
    else
        echo "UNEXPECTED CIRCUIT BREAKER" >&2
        echo "========================================" >&2
        echo "Codex output STOP during a non-alignment round (Round $CURRENT_ROUND)." >&2
        echo "This is unusual - STOP is normally only expected during Full Alignment Checks (every 5 rounds)." >&2
        echo "Honoring the STOP request and terminating the loop." >&2
        echo "" >&2
        echo "Review the review result to understand why Codex requested an early stop:" >&2
        echo "  $REVIEW_RESULT_FILE" >&2
    fi
    echo "========================================" >&2
    end_loop "$LOOP_DIR" "$STATE_FILE" "$EXIT_STOP"
    exit 0
fi

# ========================================
# Review Found Issues - Continue Loop
# ========================================

# Update state file for next round
TEMP_FILE="${STATE_FILE}.tmp.$$"
sed "s/^current_round: .*/current_round: $NEXT_ROUND/" "$STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$STATE_FILE"

# Create next round prompt
NEXT_PROMPT_FILE="$LOOP_DIR/round-${NEXT_ROUND}-prompt.md"
NEXT_SUMMARY_FILE="$LOOP_DIR/round-${NEXT_ROUND}-summary.md"

# Build the next round prompt from templates
NEXT_ROUND_FALLBACK="# Next Round Instructions

Review the feedback below and address all issues.

## Codex Review
{{REVIEW_CONTENT}}

Reference: {{PLAN_FILE}}, {{GOAL_TRACKER_FILE}}"
load_and_render_safe "$TEMPLATE_DIR" "claude/next-round-prompt.md" "$NEXT_ROUND_FALLBACK" \
    "PLAN_FILE=$PLAN_FILE" \
    "REVIEW_CONTENT=$REVIEW_CONTENT" \
    "GOAL_TRACKER_FILE=$GOAL_TRACKER_FILE" > "$NEXT_PROMPT_FILE"

# Add special instructions for post-Full Alignment Check rounds (round after every 5th)
if [[ $((CURRENT_ROUND % 5)) -eq 4 ]]; then
    POST_ALIGNMENT=$(load_template "$TEMPLATE_DIR" "claude/post-alignment-action-items.md" 2>/dev/null)
    if [[ -n "$POST_ALIGNMENT" ]]; then
        echo "$POST_ALIGNMENT" >> "$NEXT_PROMPT_FILE"
    fi
fi

# Add footer with commit/summary instructions
FOOTER_FALLBACK="## Before Exiting
Commit your changes and write summary to {{NEXT_SUMMARY_FILE}}"
load_and_render_safe "$TEMPLATE_DIR" "claude/next-round-footer.md" "$FOOTER_FALLBACK" \
    "NEXT_SUMMARY_FILE=$NEXT_SUMMARY_FILE" >> "$NEXT_PROMPT_FILE"

# Add push instruction only if push_every_round is true
if [[ "$PUSH_EVERY_ROUND" == "true" ]]; then
    PUSH_NOTE=$(load_template "$TEMPLATE_DIR" "claude/push-every-round-note.md" 2>/dev/null)
    if [[ -z "$PUSH_NOTE" ]]; then
        PUSH_NOTE="Also push your changes after committing."
    fi
    echo "$PUSH_NOTE" >> "$NEXT_PROMPT_FILE"
fi

# Add goal tracker update request template
GOAL_UPDATE_REQUEST=$(load_template "$TEMPLATE_DIR" "claude/goal-tracker-update-request.md" 2>/dev/null)
if [[ -z "$GOAL_UPDATE_REQUEST" ]]; then
    GOAL_UPDATE_REQUEST="Include a Goal Tracker Update Request section in your summary if needed."
fi
echo "$GOAL_UPDATE_REQUEST" >> "$NEXT_PROMPT_FILE"

# Build system message
SYSTEM_MSG="Loop: Round $NEXT_ROUND/$MAX_ITERATIONS - Codex found issues to address"

# Block exit and send review feedback
jq -n \
    --arg reason "$(cat "$NEXT_PROMPT_FILE")" \
    --arg msg "$SYSTEM_MSG" \
    '{
        "decision": "block",
        "reason": $reason,
        "systemMessage": $msg
    }'

exit 0
