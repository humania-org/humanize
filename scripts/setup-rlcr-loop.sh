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

# ========================================
# Parse Arguments
# ========================================

PLAN_FILE=""
MAX_ITERATIONS="$DEFAULT_MAX_ITERATIONS"
CODEX_MODEL="$DEFAULT_CODEX_MODEL"
CODEX_EFFORT="$DEFAULT_CODEX_EFFORT"
CODEX_TIMEOUT="$DEFAULT_CODEX_TIMEOUT"
PUSH_EVERY_ROUND="false"
COMMIT_PLAN_FILE="false"

show_help() {
    cat << 'HELP_EOF'
start-rlcr-loop - Iterative development with Codex review

USAGE:
  /humanize:start-rlcr-loop <path/to/plan.md> [OPTIONS]

ARGUMENTS:
  <path/to/plan.md>    Path to a markdown file containing the implementation plan
                       (must exist and have at least 5 lines)

OPTIONS:
  --max <N>            Maximum iterations before auto-stop (default: 42)
  --codex-model <MODEL:EFFORT>
                       Codex model and reasoning effort (default: gpt-5.2-codex:high)
  --codex-timeout <SECONDS>
                       Timeout for each Codex review in seconds (default: 5400)
  --push-every-round   Require git push after each round (default: commits stay local)
  --commit-plan-file   Include the plan file in commits (default: plan file stays uncommitted)
                       When set, the plan file must not be git-ignored and will be committed.
                       When not set, the plan file is allowed to remain dirty (uncommitted),
                       and any accidental commits of the plan file will be blocked.
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
  cat .humanize-loop.local/*/state.md

  # View latest summary:
  cat .humanize-loop.local/*/round-*-summary.md | tail -50

  # View Codex review:
  cat .humanize-loop.local/*/round-*-review-result.md | tail -50
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
        --commit-plan-file)
            COMMIT_PLAN_FILE="true"
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

# Check plan file is provided
if [[ -z "$PLAN_FILE" ]]; then
    echo "Error: No plan file provided" >&2
    echo "" >&2
    echo "Usage: /humanize:start-rlcr-loop <path/to/plan.md> [OPTIONS]" >&2
    echo "" >&2
    echo "For help: /humanize:start-rlcr-loop --help" >&2
    exit 1
fi

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# Make path absolute if relative
if [[ ! "$PLAN_FILE" = /* ]]; then
    PLAN_FILE="$PROJECT_ROOT/$PLAN_FILE"
fi

# Check plan file exists
if [[ ! -f "$PLAN_FILE" ]]; then
    echo "Error: Plan file not found: $PLAN_FILE" >&2
    exit 1
fi

# Require git repository with at least one commit
if ! git rev-parse --git-dir &>/dev/null 2>&1; then
    echo "Error: RLCR loop requires a git repository" >&2
    echo "Please initialize a git repository first: git init" >&2
    exit 1
fi

if ! git rev-parse HEAD &>/dev/null 2>&1; then
    echo "Error: RLCR loop requires at least one commit in the repository" >&2
    echo "Please create an initial commit first: git commit -m 'Initial commit'" >&2
    exit 1
fi

# Get relative path for validation
PLAN_FILE_REL=$(realpath --relative-to="$PROJECT_ROOT" "$PLAN_FILE" 2>/dev/null || basename "$PLAN_FILE")

# Reject paths with spaces or regex metacharacters (required for git status filtering)
if [[ "$PLAN_FILE_REL" =~ [[:space:]\[\]\*\?\{\}\|\(\)\^\$\\] ]]; then
    echo "Error: Plan file path contains unsupported characters" >&2
    echo "Plan file: $PLAN_FILE_REL" >&2
    echo "Plan file paths must not contain spaces or special characters:" >&2
    echo "  spaces, [ ] * ? { } | ( ) ^ \$ \\" >&2
    echo "Please rename or move the plan file to a simpler path." >&2
    exit 1
fi

# Check plan file has at least 5 lines
LINE_COUNT=$(wc -l < "$PLAN_FILE" | tr -d ' ')
if [[ "$LINE_COUNT" -lt 5 ]]; then
    echo "Error: Plan is too simple (only $LINE_COUNT lines, need at least 5)" >&2
    echo "" >&2
    echo "The plan file should contain enough detail for implementation." >&2
    echo "Consider adding more context, acceptance criteria, or steps." >&2
    exit 1
fi

# Check codex is available
if ! command -v codex &>/dev/null; then
    echo "Error: start-rlcr-loop requires codex to run" >&2
    echo "" >&2
    echo "Please install Codex CLI: https://openai.com/codex" >&2
    exit 1
fi

# Validate --commit-plan-file requirements
if [[ "$COMMIT_PLAN_FILE" == "true" ]]; then
    if [[ "$PLAN_FILE_REL" == ../* ]]; then
        echo "Error: --commit-plan-file is set but the plan file is outside the project" >&2
        echo "Plan file: $PLAN_FILE (relative: $PLAN_FILE_REL)" >&2
        echo "Either move the plan file inside the project or omit --commit-plan-file" >&2
        exit 1
    fi

    if git check-ignore -q "$PLAN_FILE" 2>/dev/null; then
        echo "Error: --commit-plan-file is set but the plan file is git-ignored" >&2
        echo "Plan file: $PLAN_FILE" >&2
        echo "Either remove from .gitignore or omit --commit-plan-file" >&2
        exit 1
    fi
fi

# ========================================
# Check Plan File Tracking Status
# ========================================
# Determine if plan file is tracked in git (inside repo and committed)

PLAN_FILE_TRACKED="false"
if [[ "$PLAN_FILE_REL" != ../* ]]; then
    if ! git check-ignore -q "$PLAN_FILE" 2>/dev/null; then
        if git ls-files --error-unmatch "$PLAN_FILE_REL" &>/dev/null 2>&1; then
            PLAN_FILE_TRACKED="true"
        fi
    fi
fi

# Enforce --commit-plan-file requirements: must be tracked and clean
if [[ "$COMMIT_PLAN_FILE" == "true" ]]; then
    if [[ "$PLAN_FILE_TRACKED" != "true" ]]; then
        echo "Error: --commit-plan-file is set but the plan file is not tracked by git" >&2
        echo "Plan file: $PLAN_FILE_REL" >&2
        echo "Add and commit: git add '$PLAN_FILE_REL' && git commit -m 'Add plan file'" >&2
        echo "Or omit --commit-plan-file to allow uncommitted plan files" >&2
        exit 1
    fi

    PLAN_FILE_STATUS=$(git status --porcelain "$PLAN_FILE_REL" 2>/dev/null || true)
    if [[ -n "$PLAN_FILE_STATUS" ]]; then
        echo "Error: --commit-plan-file is set but the plan file has uncommitted changes" >&2
        echo "Plan file: $PLAN_FILE_REL (status: $PLAN_FILE_STATUS)" >&2
        echo "Commit changes: git add '$PLAN_FILE_REL' && git commit -m 'Update plan'" >&2
        echo "Or omit --commit-plan-file to allow uncommitted plan files" >&2
        exit 1
    fi
fi

# ========================================
# Setup State Directory
# ========================================

LOOP_BASE_DIR="$PROJECT_ROOT/.humanize-loop.local"

# Create timestamp for this loop session
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
LOOP_DIR="$LOOP_BASE_DIR/$TIMESTAMP"

mkdir -p "$LOOP_DIR"

# Backup plan file and record starting commit for post-commit validation
cp "$PLAN_FILE" "$LOOP_DIR/plan-backup.md"
START_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "")
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
commit_plan_file: $COMMIT_PLAN_FILE
plan_file: $PLAN_FILE
plan_file_tracked: $PLAN_FILE_TRACKED
start_commit: $START_COMMIT
started_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
---
EOF

# ========================================
# Create Goal Tracker File
# ========================================

GOAL_TRACKER_FILE="$LOOP_DIR/goal-tracker.md"
PLAN_CONTENT=$(cat "$PLAN_FILE")

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
GOAL_LINE=$(grep -i -m1 '^\s*##\s*\(goal\|objective\|purpose\)' "$PLAN_FILE" 2>/dev/null || echo "")
if [[ -n "$GOAL_LINE" ]]; then
    # Get the content after the heading
    GOAL_SECTION=$(sed -n '/^\s*##\s*[Gg]oal\|^\s*##\s*[Oo]bjective\|^\s*##\s*[Pp]urpose/,/^\s*##/p' "$PLAN_FILE" | head -20 | tail -n +2 | head -10)
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
AC_SECTION=$(sed -n '/^\s*##\s*[Aa]cceptance\|^\s*##\s*[Cc]riteria\|^\s*##\s*[Rr]equirements/,/^\s*##/p' "$PLAN_FILE" 2>/dev/null | head -30 | tail -n +2 | head -25)
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

$(cat "$PLAN_FILE")

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
Plan File Backup: $LOOP_DIR/plan-backup.md
Commit Plan File: $COMMIT_PLAN_FILE
Start Commit: ${START_COMMIT:-"(not in git repo)"}
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
