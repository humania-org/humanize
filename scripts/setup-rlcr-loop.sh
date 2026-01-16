#!/bin/bash
#
# Setup script for start-rlcr-loop
#
# Creates state files for the loop that uses Codex to review Claude's work.
#
# Usage:
#   setup-rlcr-loop.sh <path/to/plan.md> [--max N] [--codex-model MODEL:EFFORT]
#

set -euo pipefail

# ========================================
# Default Configuration
# ========================================

# Default Codex model and reasoning effort
DEFAULT_CODEX_MODEL="gpt-5.2-codex"
DEFAULT_CODEX_EFFORT="high"
DEFAULT_CODEX_TIMEOUT=5400
DEFAULT_MAX_ITERATIONS=42

# Default timeout for git operations (30 seconds)
GIT_TIMEOUT=30

# Source portable timeout wrapper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/portable-timeout.sh"

# ========================================
# Parse Arguments
# ========================================

PLAN_FILE=""
PLAN_FILE_EXPLICIT=""
TRACK_PLAN_FILE="false"
MAX_ITERATIONS="$DEFAULT_MAX_ITERATIONS"
CODEX_MODEL="$DEFAULT_CODEX_MODEL"
CODEX_EFFORT="$DEFAULT_CODEX_EFFORT"
CODEX_TIMEOUT="$DEFAULT_CODEX_TIMEOUT"
PUSH_EVERY_ROUND="false"

show_help() {
    cat << 'HELP_EOF'
start-rlcr-loop - Iterative development with Codex review

USAGE:
  /humanize:start-rlcr-loop <path/to/plan.md> [OPTIONS]

ARGUMENTS:
  <path/to/plan.md>    Path to a markdown file containing the implementation plan
                       (must exist, have at least 5 lines, no spaces in path)

OPTIONS:
  --plan-file <path>   Explicit plan file path (alternative to positional arg)
  --track-plan-file    Indicate plan file should be tracked in git (must be clean)
  --max <N>            Maximum iterations before auto-stop (default: 42)
  --codex-model <MODEL:EFFORT>
                       Codex model and reasoning effort (default: gpt-5.2-codex:high)
  --codex-timeout <SECONDS>
                       Timeout for each Codex review in seconds (default: 5400)
  --push-every-round   Require git push after each round (default: commits stay local)
  -h, --help           Show this help message

DESCRIPTION:
  Starts an iterative loop with Codex review in your CURRENT session.
  This command:

  1. Takes a markdown plan file as input (not a prompt string)
  2. Uses Codex to independently review Claude's work each iteration
  3. Continues until Codex confirms completion with "COMPLETE" or max iterations

  The flow:
  1. Claude works on the plan
  2. Claude writes a summary to round-N-summary.md
  3. On exit attempt, Codex reviews the summary
  4. If Codex finds issues, it blocks exit and sends feedback
  5. If Codex outputs "COMPLETE", the loop ends

EXAMPLES:
  /humanize:start-rlcr-loop docs/feature-plan.md
  /humanize:start-rlcr-loop docs/impl.md --max 20
  /humanize:start-rlcr-loop plan.md --codex-model gpt-5.2-codex:high
  /humanize:start-rlcr-loop plan.md --codex-timeout 7200  # 2 hour timeout

STOPPING:
  - /humanize:cancel-rlcr-loop   Cancel the active loop
  - Reach --max iterations
  - Codex outputs "COMPLETE" as final line of review

MONITORING:
  # View current state:
  cat .humanize/rlcr/*/state.md

  # View latest summary:
  cat .humanize/rlcr/*/round-*-summary.md | tail -50

  # View Codex review:
  cat .humanize/rlcr/*/round-*-review-result.md | tail -50
HELP_EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
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
        --push-every-round)
            PUSH_EVERY_ROUND="true"
            shift
            ;;
        --plan-file)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --plan-file requires a file path" >&2
                exit 1
            fi
            PLAN_FILE_EXPLICIT="$2"
            shift 2
            ;;
        --track-plan-file)
            TRACK_PLAN_FILE="true"
            shift
            ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
        *)
            if [[ -z "$PLAN_FILE" ]]; then
                PLAN_FILE="$1"
            else
                echo "Error: Multiple plan files specified" >&2
                echo "Only one plan file is allowed" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

# ========================================
# Validate Prerequisites
# ========================================

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Merge explicit and positional plan file
if [[ -n "$PLAN_FILE_EXPLICIT" && -n "$PLAN_FILE" ]]; then
    echo "Error: Cannot specify both --plan-file and positional plan file" >&2
    exit 1
fi
if [[ -n "$PLAN_FILE_EXPLICIT" ]]; then
    PLAN_FILE="$PLAN_FILE_EXPLICIT"
fi

# Check plan file is provided
if [[ -z "$PLAN_FILE" ]]; then
    echo "Error: No plan file provided" >&2
    echo "" >&2
    echo "Usage: /humanize:start-rlcr-loop <path/to/plan.md> [OPTIONS]" >&2
    echo "" >&2
    echo "For help: /humanize:start-rlcr-loop --help" >&2
    exit 1
fi

# ========================================
# Git Repository Validation
# ========================================

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

# ========================================
# Plan File Path Validation
# ========================================

# Reject absolute paths
if [[ "$PLAN_FILE" = /* ]]; then
    echo "Error: Plan file must be a relative path, got: $PLAN_FILE" >&2
    exit 1
fi

# Reject paths with spaces (not supported for YAML serialization consistency)
if [[ "$PLAN_FILE" =~ [[:space:]] ]]; then
    echo "Error: Plan file path cannot contain spaces" >&2
    echo "  Got: $PLAN_FILE" >&2
    echo "  Rename the file or directory to remove spaces" >&2
    exit 1
fi

# Reject paths with shell metacharacters (prevents injection when used in shell commands)
# Use glob pattern matching (== *[...]*) instead of regex (=~) for portability
if [[ "$PLAN_FILE" == *[\;\&\|\$\`\<\>\(\)\{\}\[\]\!\#\~\*\?\\]* ]]; then
    echo "Error: Plan file path contains shell metacharacters" >&2
    echo "  Got: $PLAN_FILE" >&2
    echo "  Rename the file to use only alphanumeric, dash, underscore, dot, and slash" >&2
    exit 1
fi

# Build full path
FULL_PLAN_PATH="$PROJECT_ROOT/$PLAN_FILE"

# Reject symlinks
if [[ -L "$FULL_PLAN_PATH" ]]; then
    echo "Error: Plan file cannot be a symbolic link" >&2
    exit 1
fi

# Check parent directory exists (provides clearer error for typos in path)
PLAN_DIR="$(dirname "$FULL_PLAN_PATH")"
if [[ ! -d "$PLAN_DIR" ]]; then
    echo "Error: Plan file directory not found: $(dirname "$PLAN_FILE")" >&2
    exit 1
fi

# Check file exists
if [[ ! -f "$FULL_PLAN_PATH" ]]; then
    echo "Error: Plan file not found: $PLAN_FILE" >&2
    exit 1
fi

# Check file is readable
if [[ ! -r "$FULL_PLAN_PATH" ]]; then
    echo "Error: Plan file not readable: $PLAN_FILE" >&2
    exit 1
fi

# Check file is within project (no ../ escaping)
# Resolve the real path by cd'ing to the directory and getting pwd
# This handles symlinks in parent directories and ../ path components
RESOLVED_PLAN_DIR=$(cd "$PLAN_DIR" 2>/dev/null && pwd) || {
    echo "Error: Cannot resolve plan file directory: $(dirname "$PLAN_FILE")" >&2
    echo "  This may indicate permission issues or broken symlinks in the path" >&2
    exit 1
}
REAL_PLAN_PATH="$RESOLVED_PLAN_DIR/$(basename "$FULL_PLAN_PATH")"
if [[ ! "$REAL_PLAN_PATH" = "$PROJECT_ROOT"/* ]]; then
    echo "Error: Plan file must be within project directory" >&2
    exit 1
fi

# Check not in submodule
# Quick check: only run expensive git submodule status if .gitmodules exists
if [[ -f "$PROJECT_ROOT/.gitmodules" ]]; then
    if run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" submodule status 2>/dev/null | grep -q .; then
        # Get list of submodule paths
        SUBMODULES=$(run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" submodule status | awk '{print $2}')
        for submod in $SUBMODULES; do
            if [[ "$PLAN_FILE" = "$submod"/* || "$PLAN_FILE" = "$submod" ]]; then
                echo "Error: Plan file cannot be inside a git submodule: $submod" >&2
                exit 1
            fi
        done
    fi
fi

# ========================================
# Plan File Tracking Status Validation
# ========================================

# Check git status - fail closed on timeout
# Use || true to capture exit code without triggering set -e
PLAN_GIT_STATUS=$(run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" status --porcelain "$PLAN_FILE" 2>/dev/null) || STATUS_EXIT=$?
STATUS_EXIT=${STATUS_EXIT:-0}
if [[ $STATUS_EXIT -eq 124 ]]; then
    echo "Error: Git operation timed out while checking plan file status" >&2
    exit 1
fi

# Check if tracked - fail closed on timeout
# ls-files --error-unmatch returns 1 for untracked files (expected behavior)
# We need to distinguish between: 0 (tracked), 1 (not tracked), 124 (timeout)
run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" ls-files --error-unmatch "$PLAN_FILE" &>/dev/null || LS_FILES_EXIT=$?
LS_FILES_EXIT=${LS_FILES_EXIT:-0}
if [[ $LS_FILES_EXIT -eq 124 ]]; then
    echo "Error: Git operation timed out while checking plan file tracking status" >&2
    exit 1
fi
PLAN_IS_TRACKED=$([[ $LS_FILES_EXIT -eq 0 ]] && echo "true" || echo "false")

if [[ "$TRACK_PLAN_FILE" == "true" ]]; then
    # Must be tracked and clean
    if [[ "$PLAN_IS_TRACKED" != "true" ]]; then
        echo "Error: --track-plan-file requires plan file to be tracked in git" >&2
        echo "  File: $PLAN_FILE" >&2
        echo "  Run: git add $PLAN_FILE && git commit" >&2
        exit 1
    fi
    if [[ -n "$PLAN_GIT_STATUS" ]]; then
        echo "Error: --track-plan-file requires plan file to be clean (no modifications)" >&2
        echo "  File: $PLAN_FILE" >&2
        echo "  Status: $PLAN_GIT_STATUS" >&2
        echo "  Commit or stash your changes first" >&2
        exit 1
    fi
else
    # Must be gitignored (not tracked)
    if [[ "$PLAN_IS_TRACKED" == "true" ]]; then
        echo "Error: Plan file must be gitignored when not using --track-plan-file" >&2
        echo "  File: $PLAN_FILE" >&2
        echo "  Either:" >&2
        echo "    1. Add to .gitignore and remove from git: git rm --cached $PLAN_FILE" >&2
        echo "    2. Use --track-plan-file if you want to track the plan file" >&2
        exit 1
    fi
fi

# ========================================
# Plan File Content Validation
# ========================================

# Check plan file has at least 5 lines
LINE_COUNT=$(wc -l < "$FULL_PLAN_PATH" | tr -d ' ')
if [[ "$LINE_COUNT" -lt 5 ]]; then
    echo "Error: Plan is too simple (only $LINE_COUNT lines, need at least 5)" >&2
    echo "" >&2
    echo "The plan file should contain enough detail for implementation." >&2
    echo "Consider adding more context, acceptance criteria, or steps." >&2
    exit 1
fi

# Check plan has actual content (not just whitespace/blank lines/comments)
# Exclude: blank lines, shell/YAML comments (# ...), and HTML comments (<!-- ... -->)
# Note: Lines starting with # are treated as comments, not markdown headings
# A "content line" is any line that is not blank and not purely a comment
# For multi-line HTML comments, we count lines inside them as non-content
CONTENT_LINES=0
IN_COMMENT=false
while IFS= read -r line || [[ -n "$line" ]]; do
    # If inside multi-line comment, check for end marker
    if [[ "$IN_COMMENT" == "true" ]]; then
        if [[ "$line" =~ --\>[[:space:]]*$ ]]; then
            IN_COMMENT=false
        fi
        continue
    fi
    # Skip blank lines
    if [[ "$line" =~ ^[[:space:]]*$ ]]; then
        continue
    fi
    # Skip single-line HTML comments (must check BEFORE multi-line start)
    # Single-line: <!-- ... --> on same line
    if [[ "$line" =~ ^[[:space:]]*\<!--.*--\>[[:space:]]*$ ]]; then
        continue
    fi
    # Check for multi-line HTML comment start (<!-- without closing --> on same line)
    # Only trigger if the line contains <!-- but NOT -->
    if [[ "$line" =~ ^[[:space:]]*\<!-- ]] && ! [[ "$line" =~ --\> ]]; then
        IN_COMMENT=true
        continue
    fi
    # Skip shell/YAML style comments (lines starting with #)
    if [[ "$line" =~ ^[[:space:]]*# ]]; then
        continue
    fi
    # This is a content line
    CONTENT_LINES=$((CONTENT_LINES + 1))
done < "$FULL_PLAN_PATH"

if [[ "$CONTENT_LINES" -lt 3 ]]; then
    echo "Error: Plan file has insufficient content (only $CONTENT_LINES content lines)" >&2
    echo "" >&2
    echo "The plan file should contain meaningful content, not just blank lines or comments." >&2
    exit 1
fi

# Check codex is available
if ! command -v codex &>/dev/null; then
    echo "Error: start-rlcr-loop requires codex to run" >&2
    echo "" >&2
    echo "Please install Codex CLI: https://openai.com/codex" >&2
    exit 1
fi

# ========================================
# Record Branch
# ========================================

START_BRANCH=$(run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD)
if [[ -z "$START_BRANCH" ]]; then
    echo "Error: Failed to get current branch (git command timed out or failed)" >&2
    exit 1
fi

# Validate branch name for YAML safety (prevents injection in state.md)
# Reject branches with YAML-unsafe characters: colon, hash, quotes, newlines
if [[ "$START_BRANCH" == *[:\#\"\'\`]* ]] || [[ "$START_BRANCH" =~ $'\n' ]]; then
    echo "Error: Branch name contains YAML-unsafe characters" >&2
    echo "  Branch: $START_BRANCH" >&2
    echo "  Characters not allowed: : # \" ' \` newline" >&2
    echo "  Please checkout a branch with a simpler name" >&2
    exit 1
fi

# Validate codex model for YAML safety
# Only alphanumeric, hyphen, underscore, dot allowed
if [[ ! "$CODEX_MODEL" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "Error: Codex model contains invalid characters" >&2
    echo "  Model: $CODEX_MODEL" >&2
    echo "  Only alphanumeric, hyphen, underscore, dot allowed" >&2
    exit 1
fi

# Validate codex effort for YAML safety
# Only alphanumeric, hyphen, underscore allowed
if [[ ! "$CODEX_EFFORT" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: Codex effort contains invalid characters" >&2
    echo "  Effort: $CODEX_EFFORT" >&2
    echo "  Only alphanumeric, hyphen, underscore allowed" >&2
    exit 1
fi

# ========================================
# Setup State Directory
# ========================================

LOOP_BASE_DIR="$PROJECT_ROOT/.humanize/rlcr"

# Create timestamp for this loop session
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
LOOP_DIR="$LOOP_BASE_DIR/$TIMESTAMP"

mkdir -p "$LOOP_DIR"

# Copy plan file to loop directory as backup
cp "$FULL_PLAN_PATH" "$LOOP_DIR/plan.md"

# Docs path default
DOCS_PATH="docs"

# ========================================
# Create State File
# ========================================

cat > "$LOOP_DIR/state.md" << EOF
---
current_round: 0
max_iterations: $MAX_ITERATIONS
codex_model: $CODEX_MODEL
codex_effort: $CODEX_EFFORT
codex_timeout: $CODEX_TIMEOUT
push_every_round: $PUSH_EVERY_ROUND
plan_file: $PLAN_FILE
plan_tracked: $TRACK_PLAN_FILE
start_branch: $START_BRANCH
started_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
---
EOF

# ========================================
# Create Goal Tracker File
# ========================================

GOAL_TRACKER_FILE="$LOOP_DIR/goal-tracker.md"
PLAN_CONTENT=$(cat "$FULL_PLAN_PATH")

cat > "$GOAL_TRACKER_FILE" << 'GOAL_TRACKER_EOF'
# Goal Tracker

<!--
This file tracks the ultimate goal, acceptance criteria, and plan evolution.
It prevents goal drift by maintaining a persistent anchor across all rounds.

RULES:
- IMMUTABLE SECTION: Do not modify after initialization
- MUTABLE SECTION: Update each round, but document all changes
- Every task must be in one of: Active, Completed, or Deferred
- Deferred items require explicit justification
-->

## IMMUTABLE SECTION
<!-- Do not modify after initialization -->

### Ultimate Goal
GOAL_TRACKER_EOF

# Extract goal from plan file (look for ## Goal, ## Objective, or first paragraph)
# This is a heuristic - Claude will refine it in round 0
# Use ^## without leading whitespace - markdown headers should start at column 0
GOAL_LINE=$(grep -i -m1 '^##[[:space:]]*\(goal\|objective\|purpose\)' "$FULL_PLAN_PATH" 2>/dev/null || echo "")
if [[ -n "$GOAL_LINE" ]]; then
    # Get the content after the heading
    GOAL_SECTION=$(sed -n '/^##[[:space:]]*[Gg]oal\|^##[[:space:]]*[Oo]bjective\|^##[[:space:]]*[Pp]urpose/,/^##/p' "$FULL_PLAN_PATH" | head -20 | tail -n +2 | head -10)
    echo "$GOAL_SECTION" >> "$GOAL_TRACKER_FILE"
else
    # Use first non-empty, non-heading paragraph as goal description
    echo "[To be extracted from plan by Claude in Round 0]" >> "$GOAL_TRACKER_FILE"
    echo "" >> "$GOAL_TRACKER_FILE"
    echo "Source plan: $PLAN_FILE" >> "$GOAL_TRACKER_FILE"
fi

cat >> "$GOAL_TRACKER_FILE" << 'GOAL_TRACKER_EOF'

### Acceptance Criteria
<!-- Each criterion must be independently verifiable -->
<!-- Claude must extract or define these in Round 0 -->

GOAL_TRACKER_EOF

# Extract acceptance criteria from plan file (look for ## Acceptance, ## Criteria, ## Requirements)
# Use ^## without leading whitespace - markdown headers should start at column 0
AC_SECTION=$(sed -n '/^##[[:space:]]*[Aa]cceptance\|^##[[:space:]]*[Cc]riteria\|^##[[:space:]]*[Rr]equirements/,/^##/p' "$FULL_PLAN_PATH" 2>/dev/null | head -30 | tail -n +2 | head -25)
if [[ -n "$AC_SECTION" ]]; then
    echo "$AC_SECTION" >> "$GOAL_TRACKER_FILE"
else
    echo "[To be defined by Claude in Round 0 based on the plan]" >> "$GOAL_TRACKER_FILE"
fi

cat >> "$GOAL_TRACKER_FILE" << 'GOAL_TRACKER_EOF'

---

## MUTABLE SECTION
<!-- Update each round with justification for changes -->

### Plan Version: 1 (Updated: Round 0)

#### Plan Evolution Log
<!-- Document any changes to the plan with justification -->
| Round | Change | Reason | Impact on AC |
|-------|--------|--------|--------------|
| 0 | Initial plan | - | - |

#### Active Tasks
<!-- Map each task to its target Acceptance Criterion -->
| Task | Target AC | Status | Notes |
|------|-----------|--------|-------|
| [To be populated by Claude based on plan] | - | pending | - |

### Completed and Verified
<!-- Only move tasks here after Codex verification -->
| AC | Task | Completed Round | Verified Round | Evidence |
|----|------|-----------------|----------------|----------|

### Explicitly Deferred
<!-- Items here require strong justification -->
| Task | Original AC | Deferred Since | Justification | When to Reconsider |
|------|-------------|----------------|---------------|-------------------|

### Open Issues
<!-- Issues discovered during implementation -->
| Issue | Discovered Round | Blocking AC | Resolution Path |
|-------|-----------------|-------------|-----------------|
GOAL_TRACKER_EOF

# ========================================
# Create Initial Prompt
# ========================================

SUMMARY_PATH="$LOOP_DIR/round-0-summary.md"

cat > "$LOOP_DIR/round-0-prompt.md" << EOF
Read and execute below with ultrathink

## Goal Tracker Setup (REQUIRED FIRST STEP)

Before starting implementation, you MUST initialize the Goal Tracker:

1. Read @$GOAL_TRACKER_FILE
2. If the "Ultimate Goal" section says "[To be extracted...]", extract a clear goal statement from the plan
3. If the "Acceptance Criteria" section says "[To be defined...]", define 3-7 specific, testable criteria
4. Populate the "Active Tasks" table with tasks from the plan, mapping each to an AC
5. Write the updated goal-tracker.md

**IMPORTANT**: The IMMUTABLE SECTION can only be modified in Round 0. After this round, it becomes read-only.

---

## Implementation Plan

For all tasks that need to be completed, please create Todos to track each item in order of importance.
You are strictly prohibited from only addressing the most important issues - you MUST create Todos for ALL discovered issues and attempt to resolve each one.

$(cat "$LOOP_DIR/plan.md")

---

## Goal Tracker Rules

Throughout your work, you MUST maintain the Goal Tracker:

1. **Before starting a task**: Mark it as "in_progress" in Active Tasks
2. **After completing a task**: Move it to "Completed and Verified" with evidence (but mark as "pending verification")
3. **If you discover the plan has errors**:
   - Do NOT silently change direction
   - Add entry to "Plan Evolution Log" with justification
   - Explain how the change still serves the Ultimate Goal
4. **If you need to defer a task**:
   - Move it to "Explicitly Deferred" section
   - Provide strong justification
   - Explain impact on Acceptance Criteria
5. **If you discover new issues**: Add to "Open Issues" table

---

Note: You MUST NOT try to exit \`start-rlcr-loop\` loop by lying or edit loop state file or try to execute \`cancel-rlcr-loop\`

After completing the work, please:
0. If you have access to the \`code-simplifier\` agent, use it to review and optimize the code you just wrote
1. Finalize @$GOAL_TRACKER_FILE (this is Round 0, so you are initializing it - see "Goal Tracker Setup" above)
2. Commit your changes with a descriptive commit message
3. Write your work summary into @$SUMMARY_PATH
EOF

# Add push instruction only if push_every_round is true
if [[ "$PUSH_EVERY_ROUND" == "true" ]]; then
    cat >> "$LOOP_DIR/round-0-prompt.md" << 'EOF'

Note: Since `--push-every-round` is enabled, you must push your commits to remote after each round.
EOF
fi

# ========================================
# Output Setup Message
# ========================================

cat << EOF
=== start-rlcr-loop activated ===

Plan File: $PLAN_FILE ($LINE_COUNT lines)
Plan Tracked: $TRACK_PLAN_FILE
Start Branch: $START_BRANCH
Max Iterations: $MAX_ITERATIONS
Codex Model: $CODEX_MODEL
Codex Effort: $CODEX_EFFORT
Codex Timeout: ${CODEX_TIMEOUT}s
Loop Directory: $LOOP_DIR

The loop is now active. When you try to exit:
1. Codex will review your work summary
2. If issues are found, you'll receive feedback and continue
3. If Codex outputs "COMPLETE", the loop ends

To cancel: /humanize:cancel-rlcr-loop

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
if [[ "$PUSH_EVERY_ROUND" == "true" ]]; then
echo "1. COMMIT and PUSH your changes:"
echo "   - Create a commit with descriptive message"
echo "   - Push to the remote repository"
else
echo "1. COMMIT your changes:"
echo "   - Create a commit with descriptive message"
echo "   - (Commits stay local - no push required)"
fi
echo ""
echo "2. Write a detailed summary to:"
echo "   $SUMMARY_PATH"
echo ""
echo "   The summary should include:"
echo "   - What was implemented"
echo "   - Files created/modified"
echo "   - Tests added/passed"
echo "   - Any remaining items"
echo ""
echo "Codex will review this summary to determine if work is complete."
echo "==========================================="
