#!/bin/bash
#
# Stop Hook for RLCR loop
#
# Intercepts Claude's exit attempts and uses Codex to review work.
# If Codex doesn't confirm completion, blocks exit and feeds review back.
#
# State directory: .humanize-rlcr.local/<timestamp>/
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
# - Codex outputs "COMPLETE" -> allow exit
# - current_round >= max_iterations -> allow exit

# ========================================
# Find Active Loop
# ========================================

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
LOOP_BASE_DIR="$PROJECT_ROOT/.humanize-rlcr.local"

# Source shared loop functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib/loop-common.sh"

LOOP_DIR=$(find_active_loop "$LOOP_BASE_DIR")

# If no active loop, allow exit
if [[ -z "$LOOP_DIR" ]]; then
    exit 0
fi

STATE_FILE="$LOOP_DIR/state.md"

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

    if [[ "$TODO_EXIT" -eq 1 ]]; then
        # Incomplete todos found - block immediately without Codex review
        # Extract the incomplete todo list from the result
        INCOMPLETE_LIST=$(echo "$TODO_RESULT" | tail -n +2)

        REASON="# Incomplete Todos Detected

You are trying to stop, but you still have **incomplete todos**:

$INCOMPLETE_LIST

**Required Action**:
1. Complete all remaining todos before attempting to stop
2. Mark each todo as completed using the TodoWrite tool
3. Only after ALL todos are completed, you may proceed to write your summary and stop

Do NOT proceed to Codex review until all todos are finished. This saves time and ensures thorough work."

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
# Quick Check: Large File Detection
# ========================================
# Check if any tracked or new files exceed the line limit.
# Large files should be split into smaller modules.

MAX_LINES=2000

if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null 2>&1; then
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

        if [ "$line_count" -gt "$MAX_LINES" ]; then
            LARGE_FILES="${LARGE_FILES}
- \`${filename}\`: ${line_count} lines (${file_type} file)"
        fi
    done <<EOF
$(git status --porcelain 2>/dev/null)
EOF

    if [ -n "$LARGE_FILES" ]; then
        REASON="# Large Files Detected

You are trying to stop, but some files exceed the **${MAX_LINES}-line limit**:
$LARGE_FILES

**Why This Matters**:
- Large files are harder to maintain, review, and understand
- They hinder modular development and code reusability
- They make future changes more error-prone

**Required Actions**:

For **code files**:
1. Split into smaller, modular files (each < ${MAX_LINES} lines)
2. Ensure functionality remains **strictly unchanged** after splitting
3. Consider using the \`code-simplifier\` agent to review and optimize the refactored code
4. Maintain clear module boundaries and interfaces

For **documentation files**:
1. Split into logical sections or chapters (each < ${MAX_LINES} lines)
2. Ensure smooth **cross-references** between split files
3. Maintain **narrative flow** and coherence across files
4. Update any table of contents or navigation structures

After splitting the files, commit the changes and attempt to exit again."

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

# Check if git is available and we're in a git repo
if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null 2>&1; then
    GIT_ISSUES=""
    SPECIAL_NOTES=""

    # Check for uncommitted changes (staged or unstaged)
    GIT_STATUS=$(git status --porcelain 2>/dev/null)
    if [[ -n "$GIT_STATUS" ]]; then
        GIT_ISSUES="uncommitted changes"

        # Check for special cases in untracked files
        UNTRACKED=$(echo "$GIT_STATUS" | grep '^??' || true)

        # Check if .humanize-rlcr.local is untracked
        if echo "$UNTRACKED" | grep -q '\.humanize-loop\.local'; then
            SPECIAL_NOTES="$SPECIAL_NOTES
**Special Case - .humanize-rlcr.local detected**:
The \`.humanize-rlcr.local/\` directory is created by humanize:start-rlcr-loop and should NOT be committed.
Please add it to .gitignore:
\`\`\`bash
echo '.humanize*local*' >> .gitignore
git add .gitignore
\`\`\`
"
        fi

        # Check for other untracked files (potential artifacts)
        OTHER_UNTRACKED=$(echo "$UNTRACKED" | grep -v '\.humanize-loop\.local' || true)
        if [[ -n "$OTHER_UNTRACKED" ]]; then
            SPECIAL_NOTES="$SPECIAL_NOTES
**Note on Untracked Files**:
Some untracked files may be build artifacts, test outputs, or runtime-generated files.
These should typically be added to \`.gitignore\` rather than committed:
- Build outputs (e.g., \`target/\`, \`build/\`, \`dist/\`)
- Dependencies (e.g., \`node_modules/\`, \`vendor/\`)
- IDE/editor files (e.g., \`.idea/\`, \`.vscode/\`)
- Log files, cache files, temporary files

Review untracked files and add appropriate patterns to \`.gitignore\`.
"
        fi
    fi

    # Block if there are uncommitted changes
    if [[ -n "$GIT_ISSUES" ]]; then
        # Git has uncommitted changes - block and remind Claude to commit
        REASON="# Git Not Clean

You are trying to stop, but you have **$GIT_ISSUES**.
$SPECIAL_NOTES
**Required Actions**:
0. If you have access to the \`code-simplifier\` agent, consider using it to review and simplify the code you just wrote before committing
1. Review untracked files - add build artifacts to \`.gitignore\`
2. Stage real changes: \`git add <files>\` (or \`git add -A\` if all files should be tracked)
3. Commit with a descriptive message following project conventions

**Important Rules**:
- Commit message must follow project conventions
- AI tools (Claude, Codex, etc.) must NOT have authorship in commits
- Do NOT include \`Co-Authored-By: Claude\` or similar AI attribution

After committing all changes, you may attempt to exit again."

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
    # Read push_every_round from state file
    PUSH_EVERY_ROUND=$(grep -E "^push_every_round:" "$STATE_FILE" 2>/dev/null | sed 's/push_every_round: *//' || echo "false")

    if [[ "$PUSH_EVERY_ROUND" == "true" ]]; then
        # Check if local branch is ahead of remote (unpushed commits)
        GIT_AHEAD=$(git status -sb 2>/dev/null | grep -o 'ahead [0-9]*' || true)
        if [[ -n "$GIT_AHEAD" ]]; then
            AHEAD_COUNT=$(echo "$GIT_AHEAD" | grep -o '[0-9]*')
            CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

            REASON="# Unpushed Commits Detected

You are trying to stop, but you have **$AHEAD_COUNT unpushed commit(s)** on branch \`$CURRENT_BRANCH\`.

Since \`--push-every-round\` is enabled, you must push your commits before exiting.

**Required Action**:
\`\`\`bash
git push origin $CURRENT_BRANCH
\`\`\`

After pushing all commits, you may attempt to exit again."

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
# Parse State File
# ========================================

if [[ ! -f "$STATE_FILE" ]]; then
    exit 0
fi

# Extract frontmatter values
FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE" 2>/dev/null || echo "")

CURRENT_ROUND=$(echo "$FRONTMATTER" | grep '^current_round:' | sed 's/current_round: *//' | tr -d ' ')
MAX_ITERATIONS=$(echo "$FRONTMATTER" | grep '^max_iterations:' | sed 's/max_iterations: *//' | tr -d ' ')
CODEX_MODEL=$(echo "$FRONTMATTER" | grep '^codex_model:' | sed 's/codex_model: *//' | tr -d ' ')
CODEX_EFFORT=$(echo "$FRONTMATTER" | grep '^codex_effort:' | sed 's/codex_effort: *//' | tr -d ' ')
STATE_CODEX_TIMEOUT=$(echo "$FRONTMATTER" | grep '^codex_timeout:' | sed 's/codex_timeout: *//' | tr -d ' ')
PLAN_FILE=$(echo "$FRONTMATTER" | grep '^plan_file:' | sed 's/plan_file: *//')

# Defaults
CURRENT_ROUND="${CURRENT_ROUND:-0}"
MAX_ITERATIONS="${MAX_ITERATIONS:-10}"
CODEX_MODEL="${CODEX_MODEL:-$DEFAULT_CODEX_MODEL}"
CODEX_EFFORT="${CODEX_EFFORT:-$DEFAULT_CODEX_EFFORT}"
# Timeout priority: state file > env var > default
CODEX_TIMEOUT="${STATE_CODEX_TIMEOUT:-${CODEX_TIMEOUT:-$DEFAULT_CODEX_TIMEOUT}}"

# Validate numeric fields
if [[ ! "$CURRENT_ROUND" =~ ^[0-9]+$ ]]; then
    echo "Warning: State file corrupted (current_round), stopping loop" >&2
    rm -f "$STATE_FILE"
    exit 0
fi

# max_iterations must be a number
if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
    MAX_ITERATIONS=42
fi

# ========================================
# Check Summary File Exists
# ========================================

SUMMARY_FILE="$LOOP_DIR/round-${CURRENT_ROUND}-summary.md"

if [[ ! -f "$SUMMARY_FILE" ]]; then
    # Summary file doesn't exist - Claude didn't write it
    # Block exit and remind Claude to write summary

    REASON="# Work Summary Missing

You attempted to exit without writing your work summary.

**Required Action**: Write your work summary to:
\`\`\`
$SUMMARY_FILE
\`\`\`

The summary should include:
- What was implemented
- Files created/modified
- Tests added/passed
- Any remaining items

After writing the summary, you may attempt to exit again."

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
    GOAL_TRACKER_CONTENT=$(cat "$GOAL_TRACKER_FILE")

    HAS_GOAL_PLACEHOLDER=false
    HAS_AC_PLACEHOLDER=false
    HAS_TASKS_PLACEHOLDER=false

    if echo "$GOAL_TRACKER_CONTENT" | grep -q '\[To be extracted from plan'; then
        HAS_GOAL_PLACEHOLDER=true
    fi

    if echo "$GOAL_TRACKER_CONTENT" | grep -q '\[To be defined by Claude'; then
        HAS_AC_PLACEHOLDER=true
    fi

    if echo "$GOAL_TRACKER_CONTENT" | grep -q '\[To be populated by Claude'; then
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
        REASON="# Goal Tracker Not Initialized

You are in **Round 0** and the Goal Tracker has not been properly initialized.

**Missing items in \`$GOAL_TRACKER_FILE\`**:
$MISSING_ITEMS

**Required Actions**:
1. Read \`$GOAL_TRACKER_FILE\`
2. Replace placeholder text with actual content:
   - Extract or define the **Ultimate Goal** from your understanding of the plan
   - Define 3-7 specific, testable **Acceptance Criteria**
   - Populate **Active Tasks** with tasks from the plan, mapping each to an AC
3. Write the updated goal-tracker.md

**IMPORTANT**: The IMMUTABLE SECTION can only be set in Round 0. After this round, it becomes read-only.

After updating the Goal Tracker, you may attempt to exit again."

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
    rm -f "$STATE_FILE"
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
GOAL_TRACKER_UPDATE_SECTION="## Goal Tracker Update Requests (YOUR RESPONSIBILITY)

**Important**: Claude cannot directly modify \`goal-tracker.md\` after Round 0. If Claude's summary contains a \"Goal Tracker Update Request\" section, YOU must:

1. **Evaluate the request**: Is the change justified? Does it serve the Ultimate Goal?
2. **If approved**: Update @$GOAL_TRACKER_FILE yourself with the requested changes:
   - Move tasks between Active/Completed/Deferred sections as appropriate
   - Add entries to \"Plan Evolution Log\" with round number and justification
   - Add new issues to \"Open Issues\" if discovered
   - **NEVER modify the IMMUTABLE SECTION** (Ultimate Goal and Acceptance Criteria)
3. **If rejected**: Include in your review why the request was rejected

Common update requests you should handle:
- Task completion: Move from \"Active Tasks\" to \"Completed and Verified\"
- New issues: Add to \"Open Issues\" table
- Plan changes: Add to \"Plan Evolution Log\" with your assessment
- Deferrals: Only allow with strong justification; add to \"Explicitly Deferred\""

# Determine if this is a Full Alignment Check round (every 5 rounds)
FULL_ALIGNMENT_CHECK=false
if [[ $((CURRENT_ROUND % 5)) -eq 4 ]]; then
    FULL_ALIGNMENT_CHECK=true
fi

# Build the review prompt
if [[ "$FULL_ALIGNMENT_CHECK" == "true" ]]; then
    # Full Alignment Check prompt
    cat > "$REVIEW_PROMPT_FILE" << EOF
# FULL GOAL ALIGNMENT CHECK - Round $CURRENT_ROUND

This is a **mandatory checkpoint** (every 5 rounds). You must conduct a comprehensive goal alignment audit.

## Original Implementation Plan

**IMPORTANT**: The original plan that Claude is implementing is located at:
@$PLAN_FILE

You MUST read this plan file first to understand the full scope of work before conducting your review.

---
## Claude's Work Summary
<!-- CLAUDE's WORK SUMMARY START -->
$SUMMARY_CONTENT
<!-- CLAUDE's WORK SUMMARY  END  -->
---

## Part 1: Goal Tracker Audit (MANDATORY)

Read @$GOAL_TRACKER_FILE and verify:

### 1.1 Acceptance Criteria Status
For EACH Acceptance Criterion in the IMMUTABLE SECTION:
| AC | Status | Evidence (if MET) | Blocker (if NOT MET) | Justification (if DEFERRED) |
|----|--------|-------------------|---------------------|----------------------------|
| AC-1 | MET / PARTIAL / NOT MET / DEFERRED | ... | ... | ... |
| ... | ... | ... | ... | ... |

### 1.2 Forgotten Items Detection
Compare the original plan (@$PLAN_FILE) with the current goal-tracker:
- Are there tasks that are neither in "Active", "Completed", nor "Deferred"?
- Are there tasks marked "complete" in summaries but not verified?
- List any forgotten items found.

### 1.3 Deferred Items Audit
For each item in "Explicitly Deferred":
- Is the deferral justification still valid?
- Should it be un-deferred based on current progress?
- Does it contradict the Ultimate Goal?

### 1.4 Goal Completion Summary
\`\`\`
Acceptance Criteria: X/Y met (Z deferred)
Active Tasks: N remaining
Estimated remaining rounds: ?
Critical blockers: [list if any]
\`\`\`

## Part 2: Implementation Review

- Conduct a deep critical review of the implementation
- Verify Claude's claims match reality
- Identify any gaps, bugs, or incomplete work
- Reference @$DOCS_PATH for design documents

## Part 3: $GOAL_TRACKER_UPDATE_SECTION

## Part 4: Progress Stagnation Check (MANDATORY for Full Alignment Rounds)

To implement the original plan at @$PLAN_FILE, we have completed **$((CURRENT_ROUND + 1)) iterations** (Round 0 to Round $CURRENT_ROUND).

The project's \`.humanize-rlcr.local/$(basename "$LOOP_DIR")/\` directory contains the history of each round's iteration:
- Round input prompts: \`round-N-prompt.md\`
- Round output summaries: \`round-N-summary.md\`
- Round review prompts: \`round-N-review-prompt.md\`
- Round review results: \`round-N-review-result.md\`

**How to Access Historical Files**: Read the historical review results and summaries using file paths like:
- \`@.humanize-rlcr.local/$(basename "$LOOP_DIR")/round-$((CURRENT_ROUND - 1))-review-result.md\` (previous round)
- \`@.humanize-rlcr.local/$(basename "$LOOP_DIR")/round-$((CURRENT_ROUND - 2))-review-result.md\` (2 rounds ago)
- \`@.humanize-rlcr.local/$(basename "$LOOP_DIR")/round-$((CURRENT_ROUND - 1))-summary.md\` (previous summary)

**Your Task**: Review the historical review results, especially the **last 5 rounds** of development progress and review outcomes, to determine if the development has stalled.

**Signs of Stagnation** (circuit breaker triggers):
- Same issues appearing repeatedly across multiple rounds
- No meaningful progress on Acceptance Criteria over several rounds
- Claude making the same mistakes repeatedly
- Circular discussions without resolution
- No new code changes despite continued iterations
- Codex giving similar feedback repeatedly without Claude addressing it

**If development is stagnating**, write **STOP** (as a single word on its own line) as the last line of your review output @$REVIEW_RESULT_FILE instead of COMPLETE.

## Part 5: Output Requirements

- If issues found OR any AC is NOT MET (including deferred ACs), write your findings to @$REVIEW_RESULT_FILE
- Include specific action items for Claude to address
- **If development is stagnating** (see Part 4), write "STOP" as the last line
- **CRITICAL**: Only write "COMPLETE" as the last line if ALL ACs from the original plan are FULLY MET with no deferrals
  - DEFERRED items are considered INCOMPLETE - do NOT output COMPLETE if any AC is deferred
  - The ONLY condition for COMPLETE is: all original plan tasks are done, all ACs are met, no deferrals allowed
EOF

else
    # Regular review prompt with goal alignment section
    cat > "$REVIEW_PROMPT_FILE" << EOF
# Code Review - Round $CURRENT_ROUND

## Original Implementation Plan

**IMPORTANT**: The original plan that Claude is implementing is located at:
@$PLAN_FILE

You MUST read this plan file first to understand the full scope of work before conducting your review.
This plan contains the complete requirements and implementation details that Claude should be following.

Based on the original plan and @$PROMPT_FILE, Claude claims to have completed the work. Please conduct a thorough critical review to verify this.

---
Below is Claude's summary of the work completed:
<!-- CLAUDE's WORK SUMMARY START -->
$SUMMARY_CONTENT
<!-- CLAUDE's WORK SUMMARY  END  -->
---

## Part 1: Implementation Review

- Your task is to conduct a deep critical review, focusing on finding implementation issues and identifying gaps between "plan-design" and actual implementation.
- Relevant top-level guidance documents, phased implementation plans, and other important documentation and implementation references are located under @$DOCS_PATH.
- If Claude planned to defer any tasks to future phases in its summary, DO NOT follow its lead. Instead, you should force Claude to complete ALL tasks as planned.
  - Such deferred tasks are considered incomplete work and should be flagged in your review comments, requiring Claude to address them.
  - If Claude planned to defer any tasks, please explore the codebase in-depth and draft a detailed implementation plan. This plan should be included in your review comments for Claude to follow.
  - Your review should be meticulous and skeptical. Look for any discrepancies, missing features, incomplete implementations.
- If Claude does not plan to defer any tasks, but honestly admits that some tasks are still pending (not yet completed), you should also include those pending tasks in your review.
  - Your review should elaborate on those unfinished tasks, explore the codebase, and draft an implementation plan.
  - A good engineering implementation plan should be **singular, directive, and definitive**, rather than discussing multiple possible implementation options.
  - The implementation plan should be **unambiguous**, internally consistent, and coherent from beginning to end, so that **Claude can execute the work accurately and without error**.

## Part 2: Goal Alignment Check (MANDATORY)

Read @$GOAL_TRACKER_FILE and verify:

1. **Acceptance Criteria Progress**: For each AC, is progress being made? Are any ACs being ignored?
2. **Forgotten Items**: Are there tasks from the original plan that are not tracked in Active/Completed/Deferred?
3. **Deferred Items**: Are deferrals justified? Do they block any ACs?
4. **Plan Evolution**: If Claude modified the plan, is the justification valid?

Include a brief Goal Alignment Summary in your review:
\`\`\`
ACs: X/Y addressed | Forgotten items: N | Unjustified deferrals: N
\`\`\`

## Part 3: $GOAL_TRACKER_UPDATE_SECTION

## Part 4: Output Requirements

- In short, your review comments can include: problems/findings/blockers; claims that don't match reality; implementation plans for deferred work (to be implemented now); implementation plans for unfinished work; goal alignment issues.
- If after your investigation the actual situation does not match what Claude claims to have completed, or there is pending work to be done, output your review comments to @$REVIEW_RESULT_FILE.
- **CRITICAL**: Only output "COMPLETE" as the last line if ALL tasks from the original plan are FULLY completed with no deferrals
  - DEFERRED items are considered INCOMPLETE - do NOT output COMPLETE if any task is deferred
  - UNFINISHED items are considered INCOMPLETE - do NOT output COMPLETE if any task is pending
  - The ONLY condition for COMPLETE is: all original plan tasks are done, all ACs are met, no deferrals or pending work allowed
- The word COMPLETE on the last line will stop Claude.
EOF
fi

# ========================================
# Run Codex Review
# ========================================

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
run_with_timeout "$CODEX_TIMEOUT" codex exec "${CODEX_ARGS[@]}" "$CODEX_PROMPT_CONTENT" \
    > "$CODEX_STDOUT_FILE" 2> "$CODEX_STDERR_FILE" || CODEX_EXIT_CODE=$?

echo "Codex exit code: $CODEX_EXIT_CODE" >&2
echo "Codex stdout saved to: $CODEX_STDOUT_FILE" >&2
echo "Codex stderr saved to: $CODEX_STDERR_FILE" >&2

# Check if Codex created the review result file (it should write to workspace)
# If not, check if it wrote to stdout
if [[ ! -f "$REVIEW_RESULT_FILE" ]]; then
    # Codex might have written output to stdout instead
    if [[ -s "$CODEX_STDOUT_FILE" ]]; then
        echo "Codex output found in stdout, copying to review result file..." >&2
        cp "$CODEX_STDOUT_FILE" "$REVIEW_RESULT_FILE"
    fi
fi

# ========================================
# Check Codex Output
# ========================================

if [[ ! -f "$REVIEW_RESULT_FILE" ]]; then
    echo "Error: Codex did not create review result file" >&2

    # Read stderr for error details
    STDERR_CONTENT=""
    if [[ -f "$CODEX_STDERR_FILE" ]]; then
        STDERR_CONTENT=$(tail -50 "$CODEX_STDERR_FILE" 2>/dev/null || echo "(unable to read stderr)")
    fi

    REASON="# Codex Review Failed

The Codex review process failed to produce output.

**Exit Code**: $CODEX_EXIT_CODE
**Review Result File**: $REVIEW_RESULT_FILE (not created)

**Debug Files**:
- Command: $CODEX_CMD_FILE
- Stdout: $CODEX_STDOUT_FILE
- Stderr: $CODEX_STDERR_FILE

**Stderr (last 50 lines)**:
\`\`\`
$STDERR_CONTENT
\`\`\`

Please check the debug files for more details. The system will attempt another review when you exit."

    jq -n \
        --arg reason "$REASON" \
        --arg msg "Loop: Codex review failed for round $CURRENT_ROUND (exit code: $CODEX_EXIT_CODE)" \
        '{
            "decision": "block",
            "reason": $reason,
            "systemMessage": $msg
        }'
    exit 0
fi

# Read the review result
REVIEW_CONTENT=$(cat "$REVIEW_RESULT_FILE")

# Check if the last non-empty line is exactly "COMPLETE" or "STOP"
# The word must be on its own line to avoid false positives like "CANNOT COMPLETE"
# Use strict matching: only whitespace before/after the word is allowed
LAST_LINE=$(echo "$REVIEW_CONTENT" | grep -v '^[[:space:]]*$' | tail -1)
LAST_LINE_TRIMMED=$(echo "$LAST_LINE" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

# Handle COMPLETE - loop finished successfully
if [[ "$LAST_LINE_TRIMMED" == "COMPLETE" ]]; then
    if [[ "$FULL_ALIGNMENT_CHECK" == "true" ]]; then
        echo "Codex review passed. All goals achieved. Loop complete!" >&2
    else
        echo "Codex review passed. Loop complete!" >&2
    fi
    rm -f "$STATE_FILE"
    exit 0
fi

# Handle STOP - circuit breaker triggered
if [[ "$LAST_LINE_TRIMMED" == "STOP" ]]; then
    echo "" >&2
    echo "========================================" >&2
    if [[ "$FULL_ALIGNMENT_CHECK" == "true" ]]; then
        echo "CIRCUIT BREAKER TRIGGERED" >&2
        echo "========================================" >&2
        echo "Codex detected development stagnation during Full Alignment Check (Round $CURRENT_ROUND)." >&2
        echo "The loop has been stopped to prevent further unproductive iterations." >&2
        echo "" >&2
        echo "Review the historical round files in .humanize-rlcr.local/$(basename "$LOOP_DIR")/ to understand what went wrong." >&2
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
    rm -f "$STATE_FILE"
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

# Check if this is a Full Alignment Check follow-up (round after every 5th)
IS_POST_ALIGNMENT=$([[ $((CURRENT_ROUND % 5)) -eq 4 ]] && echo "true" || echo "false")

cat > "$NEXT_PROMPT_FILE" << EOF
Your work is not finished. Read and execute the below with ultrathink.

## Original Implementation Plan

**IMPORTANT**: Before proceeding, review the original plan you are implementing:
@$PLAN_FILE

This plan contains the full scope of work and requirements. Ensure your work aligns with this plan.

---

For all tasks that need to be completed, please create Todos to track each item in order of importance.
You are strictly prohibited from only addressing the most important issues - you MUST create Todos for ALL discovered issues and attempt to resolve each one.

---
Below is Codex's review result:
<!-- CODEX's REVIEW RESULT START -->
$REVIEW_CONTENT
<!-- CODEX's REVIEW RESULT  END  -->
---

## Goal Tracker Reference (READ-ONLY after Round 0)

Before starting work, **read** @$GOAL_TRACKER_FILE to understand:
- The Ultimate Goal and Acceptance Criteria you're working toward
- Which tasks are Active, Completed, or Deferred
- Any Plan Evolution that has occurred
- Open Issues that need attention

**IMPORTANT**: You CANNOT directly modify goal-tracker.md after Round 0.
If you need to update the Goal Tracker, include a "Goal Tracker Update Request" section in your summary (see below).
EOF

# Add special instructions for post-Full Alignment Check rounds
if [[ "$IS_POST_ALIGNMENT" == "true" ]]; then
    cat >> "$NEXT_PROMPT_FILE" << EOF

### Post-Alignment Check Action Items

This round follows a Full Goal Alignment Check. Pay special attention to:
- **Forgotten Items**: Codex may have identified tasks that were being ignored. Address them.
- **AC Status**: If any Acceptance Criteria were marked NOT MET, prioritize work toward those.
- **Deferred Items**: If any deferrals were flagged as unjustified, un-defer them now.
EOF
fi

cat >> "$NEXT_PROMPT_FILE" << EOF

---

Note: You MUST NOT try to exit the RLCR loop by lying, editing the loop state file, or executing \`cancel-rlcr-loop\`.

After completing the work, please:
0. If you have access to the \`code-simplifier\` agent, use it to review and optimize the code you just wrote
1. Commit your changes with a descriptive commit message
2. Write your work summary into @$NEXT_SUMMARY_FILE
EOF

# Add push instruction only if push_every_round is true
if [[ "$PUSH_EVERY_ROUND" == "true" ]]; then
    cat >> "$NEXT_PROMPT_FILE" << 'EOF'

Note: Since `--push-every-round` is enabled, you must push your commits to remote after each round.
EOF
fi

cat >> "$NEXT_PROMPT_FILE" << 'EOF'

**If Goal Tracker needs updates**, include this section in your summary:
\`\`\`markdown
## Goal Tracker Update Request

### Requested Changes:
- [E.g., "Mark Task X as completed with evidence: tests pass"]
- [E.g., "Add to Open Issues: discovered Y needs addressing"]
- [E.g., "Plan Evolution: changed approach from A to B because..."]
- [E.g., "Defer Task Z because... (impact on AC: none/minimal)"]

### Justification:
[Explain why these changes are needed and how they serve the Ultimate Goal]
\`\`\`

Codex will review your request and update the Goal Tracker if justified.
EOF

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
