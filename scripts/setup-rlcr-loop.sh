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

# DEFAULT_CODEX_MODEL and DEFAULT_CODEX_EFFORT are provided by loop-common.sh
DEFAULT_CODEX_TIMEOUT=5400
DEFAULT_MAX_ITERATIONS=42
DEFAULT_FULL_REVIEW_ROUND=5

# Default timeout for git operations (30 seconds)
GIT_TIMEOUT=30

# Source portable timeout wrapper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/portable-timeout.sh"

# Source shared loop library (provides DEFAULT_CODEX_MODEL and other constants)
HOOKS_LIB_DIR="$(cd "$SCRIPT_DIR/../hooks/lib" && pwd)"
source "$HOOKS_LIB_DIR/loop-common.sh"

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
BASE_BRANCH=""
FULL_REVIEW_ROUND="$DEFAULT_FULL_REVIEW_ROUND"
SKIP_IMPL="false"
SKIP_IMPL_NO_PLAN="false"
ASK_CODEX_QUESTION="true"
AGENT_TEAMS="false"

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
                       Codex model and reasoning effort (default: gpt-5.3-codex:xhigh)
  --codex-timeout <SECONDS>
                       Timeout for each Codex review in seconds (default: 5400)
  --push-every-round   Require git push after each round (default: commits stay local)
  --base-branch <BRANCH>
                       Base branch for code review phase (default: auto-detect)
                       Priority: user input > remote default > main > master
  --full-review-round <N>
                       Interval for Full Alignment Check rounds (default: 5, min: 2)
                       Full Alignment Checks occur at rounds N-1, 2N-1, 3N-1, etc.
  --skip-impl          Skip implementation phase and go directly to code review
                       Plan file is optional when using this flag
  --claude-answer-codex
                       When Codex finds Open Questions, let Claude answer them
                       directly instead of asking user via AskUserQuestion.
                       NOT RECOMMENDED: Open Questions usually indicate gaps in
                       your plan that deserve human clarification. By default,
                       Claude asks user for clarification, which is preferred.
  --agent-teams        Enable Claude Code Agent Teams mode for parallel development.
                       Requires CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 environment variable.
                       Claude acts as team leader, splitting tasks among team members.
  -h, --help           Show this help message

DESCRIPTION:
  Starts an iterative loop with Codex review in your CURRENT session.
  This command:

  1. Takes a markdown plan file as input (not a prompt string)
  2. Uses Codex to independently review Claude's work each iteration
  3. Has two phases: Implementation Phase and Review Phase

  The flow:
  1. Claude works on the plan (Implementation Phase)
  2. Claude writes a summary to round-N-summary.md
  3. On exit attempt, Codex reviews the summary
  4. If Codex finds issues, it blocks exit and sends feedback
  5. If Codex outputs "COMPLETE", enters Review Phase
  6. In Review Phase, codex review checks code quality with [P0-9] markers
  7. If code review finds issues, Claude fixes them
  8. When no issues found, enters Finalize Phase and loop ends

EXAMPLES:
  /humanize:start-rlcr-loop docs/feature-plan.md
  /humanize:start-rlcr-loop docs/impl.md --max 20
  /humanize:start-rlcr-loop plan.md --codex-model gpt-5.3-codex:xhigh
  /humanize:start-rlcr-loop plan.md --codex-timeout 7200  # 2 hour timeout

STOPPING:
  - /humanize:cancel-rlcr-loop   Cancel the active loop
  - Reach --max iterations
  - Pass code review (no [P0-9] issues) after COMPLETE

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
        --base-branch)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --base-branch requires a branch name argument" >&2
                exit 1
            fi
            BASE_BRANCH="$2"
            shift 2
            ;;
        --full-review-round)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --full-review-round requires a number argument" >&2
                exit 1
            fi
            if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --full-review-round must be a positive integer, got: $2" >&2
                exit 1
            fi
            if [[ "$2" -lt 2 ]]; then
                echo "Error: --full-review-round must be at least 2, got: $2" >&2
                exit 1
            fi
            FULL_REVIEW_ROUND="$2"
            shift 2
            ;;
        --skip-impl)
            SKIP_IMPL="true"
            shift
            ;;
        --claude-answer-codex)
            ASK_CODEX_QUESTION="false"
            shift
            ;;
        --agent-teams)
            AGENT_TEAMS="true"
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

# loop-common.sh already sourced above (provides find_active_loop, find_active_pr_loop, etc.)

# ========================================
# Mutual Exclusion Check
# ========================================

# Check for existing active loops (both RLCR and PR loops)
# Only one loop type can be active at a time
RLCR_LOOP_DIR=$(find_active_loop "$PROJECT_ROOT/.humanize/rlcr" 2>/dev/null || echo "")
PR_LOOP_DIR=$(find_active_pr_loop "$PROJECT_ROOT/.humanize/pr-loop" 2>/dev/null || echo "")

if [[ -n "$RLCR_LOOP_DIR" ]]; then
    echo "Error: An RLCR loop is already active" >&2
    echo "  Active loop: $RLCR_LOOP_DIR" >&2
    echo "" >&2
    echo "Only one loop can be active at a time." >&2
    echo "Cancel the RLCR loop first with: /humanize:cancel-rlcr-loop" >&2
    exit 1
fi

if [[ -n "$PR_LOOP_DIR" ]]; then
    echo "Error: A PR loop is already active" >&2
    echo "  Active loop: $PR_LOOP_DIR" >&2
    echo "" >&2
    echo "Only one loop can be active at a time." >&2
    echo "Cancel the PR loop first with: /humanize:cancel-pr-loop" >&2
    exit 1
fi

# ========================================
# Agent Teams Validation
# ========================================

if [[ "$AGENT_TEAMS" == "true" ]]; then
    if [[ "${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-}" != "1" ]]; then
        echo "Error: --agent-teams requires the CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS environment variable to be set." >&2
        echo "" >&2
        echo "Claude Code Agent Teams is an experimental feature that must be enabled before use." >&2
        echo "To enable it, set the environment variable before starting Claude Code:" >&2
        echo "" >&2
        echo "  export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1" >&2
        echo "" >&2
        echo "Or add it to your shell profile (~/.bashrc, ~/.zshrc) for persistent access." >&2
        exit 1
    fi
fi

# Merge explicit and positional plan file
if [[ -n "$PLAN_FILE_EXPLICIT" && -n "$PLAN_FILE" ]]; then
    echo "Error: Cannot specify both --plan-file and positional plan file" >&2
    exit 1
fi
if [[ -n "$PLAN_FILE_EXPLICIT" ]]; then
    PLAN_FILE="$PLAN_FILE_EXPLICIT"
fi

# Check plan file is provided (optional when --skip-impl is used)
if [[ -z "$PLAN_FILE" ]]; then
    if [[ "$SKIP_IMPL" == "true" ]]; then
        # Use internal placeholder for skip-impl mode
        PLAN_FILE=".humanize/skip-impl-placeholder.md"
        SKIP_IMPL_NO_PLAN="true"
        # Force TRACK_PLAN_FILE to false since there's no real plan file to track
        if [[ "$TRACK_PLAN_FILE" == "true" ]]; then
            echo "Warning: --track-plan-file ignored in skip-impl mode without a plan file" >&2
            TRACK_PLAN_FILE="false"
        fi
    else
        echo "Error: No plan file provided" >&2
        echo "" >&2
        echo "Usage: /humanize:start-rlcr-loop <path/to/plan.md> [OPTIONS]" >&2
        echo "" >&2
        echo "For help: /humanize:start-rlcr-loop --help" >&2
        exit 1
    fi
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

# Plan File Path Validation
# ========================================

# Skip plan file validation in skip-impl mode with no plan provided
if [[ "$SKIP_IMPL_NO_PLAN" == "true" ]]; then
    echo "Skip-impl mode: skipping plan file validation" >&2
    FULL_PLAN_PATH=""
    PLAN_IS_TRACKED="false"
else

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

# Reject symlinks (file itself)
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

# Reject symlinks in parent directory path (walk each segment)
# This prevents symlink-based path traversal attacks
CHECK_PATH="$PROJECT_ROOT"
# Split PLAN_FILE by / and check each parent directory segment
# Use parameter expansion for portability (works in bash and zsh)
REMAINING_PATH="${PLAN_FILE%/*}"
if [[ "$REMAINING_PATH" != "$PLAN_FILE" ]]; then
    # There are parent directories to check
    IFS='/' read -ra PATH_SEGMENTS <<< "$REMAINING_PATH"
    for segment in "${PATH_SEGMENTS[@]}"; do
        if [[ -z "$segment" ]]; then
            continue
        fi
        CHECK_PATH="$CHECK_PATH/$segment"
        if [[ -L "$CHECK_PATH" ]]; then
            echo "Error: Plan file path contains a symbolic link in parent directory" >&2
            echo "  Symlink found at: $segment" >&2
            echo "  Plan file paths must not traverse symbolic links" >&2
            exit 1
        fi
    done
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

fi  # End of skip-impl plan file validation skip

# ========================================
# Plan File Content Validation
# ========================================

# Skip plan file content validation in skip-impl mode with no plan provided
if [[ "$SKIP_IMPL_NO_PLAN" != "true" ]]; then

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

else
    # Skip-impl mode: set placeholder LINE_COUNT
    LINE_COUNT=0
fi  # End of skip-impl plan file content validation skip

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
# Git Working Tree Clean Check
# ========================================
# Placed after input validation so users see input errors first

GIT_STATUS_OUTPUT=$(run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" status --porcelain 2>/dev/null) || GIT_STATUS_EXIT=$?
GIT_STATUS_EXIT=${GIT_STATUS_EXIT:-0}
if [[ $GIT_STATUS_EXIT -eq 124 ]]; then
    echo "Error: Git operation timed out while checking working tree status" >&2
    exit 1
fi
if [[ -n "$GIT_STATUS_OUTPUT" ]]; then
    echo "Error: Git working tree is not clean" >&2
    echo "" >&2
    echo "RLCR loop can only be started on a clean git repository." >&2
    echo "Please commit or stash your changes before starting the loop." >&2
    echo "" >&2
    echo "Current status:" >&2
    echo "$GIT_STATUS_OUTPUT" >&2
    exit 1
fi

# ========================================
# Determine Base Branch for Code Review
# ========================================
# Priority: user input > remote default > local main > local master

if [[ -n "$BASE_BRANCH" ]]; then
    # User specified base branch - validate it exists LOCALLY
    # codex review --base requires a local ref, so remote-only branches won't work
    if run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/$BASE_BRANCH" 2>/dev/null; then
        : # Branch exists locally, good
    else
        # Check if it exists on remote but not locally
        if run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" ls-remote --heads origin "$BASE_BRANCH" 2>/dev/null | grep -q .; then
            echo "Error: Base branch '$BASE_BRANCH' exists on remote but not locally" >&2
            echo "  codex review requires a local branch reference" >&2
            echo "  Run: git fetch origin $BASE_BRANCH:$BASE_BRANCH" >&2
            exit 1
        else
            echo "Error: Specified base branch does not exist: $BASE_BRANCH" >&2
            echo "  Not found locally or on any remote" >&2
            exit 1
        fi
    fi
else
    # Auto-detect base branch
    # Note: codex review --base requires a LOCAL branch, so we must verify local existence
    # Priority 1: Remote default branch (if it exists locally)
    # Guard with || true to prevent pipefail from terminating script when origin is missing
    REMOTE_DEFAULT=$(run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" remote show origin 2>/dev/null | grep "HEAD branch:" | sed 's/.*HEAD branch:[[:space:]]*//' || true)
    if [[ -n "$REMOTE_DEFAULT" && "$REMOTE_DEFAULT" != "(unknown)" ]]; then
        # Verify the remote default branch exists locally
        if run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" show-ref --verify --quiet "refs/heads/$REMOTE_DEFAULT" 2>/dev/null; then
            BASE_BRANCH="$REMOTE_DEFAULT"
        fi
    fi
    # Priority 2: Local main branch (if not already set)
    if [[ -z "$BASE_BRANCH" ]] && run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" show-ref --verify --quiet refs/heads/main 2>/dev/null; then
        BASE_BRANCH="main"
    fi
    # Priority 3: Local master branch (if not already set)
    if [[ -z "$BASE_BRANCH" ]] && run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" show-ref --verify --quiet refs/heads/master 2>/dev/null; then
        BASE_BRANCH="master"
    fi
    # Error if no base branch found
    if [[ -z "$BASE_BRANCH" ]]; then
        echo "Error: Cannot determine base branch for code review" >&2
        echo "  No local main or master branch found" >&2
        if [[ -n "$REMOTE_DEFAULT" && "$REMOTE_DEFAULT" != "(unknown)" ]]; then
            echo "  Remote default '$REMOTE_DEFAULT' exists but not locally" >&2
            echo "  Run: git fetch origin $REMOTE_DEFAULT:$REMOTE_DEFAULT" >&2
        fi
        echo "  Use --base-branch to specify explicitly" >&2
        exit 1
    fi
fi

# Validate base branch name for YAML safety
if [[ "$BASE_BRANCH" == *[:\#\"\'\`]* ]] || [[ "$BASE_BRANCH" =~ $'\n' ]]; then
    echo "Error: Base branch name contains YAML-unsafe characters" >&2
    echo "  Branch: $BASE_BRANCH" >&2
    echo "  Characters not allowed: : # \" ' \` newline" >&2
    exit 1
fi

# Capture the base commit SHA at loop start time
# This prevents issues when working on the base branch itself (e.g., main)
# where the branch ref advances with commits, making diff against itself empty
BASE_COMMIT=$(run_with_timeout "$GIT_TIMEOUT" git -C "$PROJECT_ROOT" rev-parse "$BASE_BRANCH" 2>/dev/null)
if [[ -z "$BASE_COMMIT" ]]; then
    echo "Error: Failed to get commit SHA for base branch: $BASE_BRANCH" >&2
    exit 1
fi
echo "Base commit SHA captured: $BASE_COMMIT" >&2

# ========================================
# Setup State Directory
# ========================================

LOOP_BASE_DIR="$PROJECT_ROOT/.humanize/rlcr"

# Create timestamp for this loop session
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
LOOP_DIR="$LOOP_BASE_DIR/$TIMESTAMP"

mkdir -p "$LOOP_DIR"

# Copy plan file to loop directory as backup (or create placeholder for skip-impl)
if [[ "$SKIP_IMPL_NO_PLAN" == "true" ]]; then
    # Create placeholder plan file for skip-impl mode
    cat > "$LOOP_DIR/plan.md" << 'SKIP_IMPL_PLAN_EOF'
# Skip Implementation Mode

This RLCR loop was started with `--skip-impl` flag, which skips the implementation phase
and goes directly to code review.

No implementation plan was provided - this is expected for skip-impl mode.

The loop will:
1. Run `codex review` on the current branch changes
2. If issues are found, Claude will fix them
3. When no issues remain, enter finalize phase

SKIP_IMPL_PLAN_EOF
    # Update PLAN_FILE to point to the actual placeholder location (repo-relative path)
    # Using relative path because git ls-files requires repo-relative paths
    PLAN_FILE=".humanize/rlcr/$TIMESTAMP/plan.md"
else
    ln -s "$FULL_PLAN_PATH" "$LOOP_DIR/plan.md"
fi

# Docs path default
DOCS_PATH="docs"

# ========================================
# Create State File
# ========================================

# Determine initial review_started value based on skip-impl mode
INITIAL_REVIEW_STARTED="$SKIP_IMPL"

cat > "$LOOP_DIR/state.md" << EOF
---
current_round: 0
max_iterations: $MAX_ITERATIONS
codex_model: $CODEX_MODEL
codex_effort: $CODEX_EFFORT
codex_timeout: $CODEX_TIMEOUT
push_every_round: $PUSH_EVERY_ROUND
full_review_round: $FULL_REVIEW_ROUND
plan_file: $PLAN_FILE
plan_tracked: $TRACK_PLAN_FILE
start_branch: $START_BRANCH
base_branch: $BASE_BRANCH
base_commit: $BASE_COMMIT
review_started: $INITIAL_REVIEW_STARTED
ask_codex_question: $ASK_CODEX_QUESTION
session_id:
agent_teams: $AGENT_TEAMS
started_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
---
EOF

# Create signal file for PostToolUse hook to record session_id
# The hook will read the session_id from its JSON input and patch state.md
# Format: line 1 = state file path, line 2 = command marker for verification
# The PostToolUse hook will only consume this signal when the Bash command
# that triggered it matches the setup script marker, preventing other sessions
# from accidentally claiming the signal.
mkdir -p "$PROJECT_ROOT/.humanize"
# Write full resolved script path as command signature for strict verification
SCRIPT_SELF_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]:-$0}")"
printf '%s\n%s\n' "$LOOP_DIR/state.md" "$SCRIPT_SELF_PATH" > "$PROJECT_ROOT/.humanize/.pending-session-id"

# Create review phase marker file for skip-impl mode
if [[ "$SKIP_IMPL" == "true" ]]; then
    echo "build_finish_round=0" > "$LOOP_DIR/.review-phase-started"
fi

# ========================================
# Create Goal Tracker File
# ========================================

GOAL_TRACKER_FILE="$LOOP_DIR/goal-tracker.md"

if [[ "$SKIP_IMPL" == "true" ]]; then
    # Create simplified goal tracker for skip-impl mode (no placeholder text)
    cat > "$GOAL_TRACKER_FILE" << 'GOAL_TRACKER_EOF'
# Goal Tracker (Skip Implementation Mode)

This RLCR loop was started with `--skip-impl` flag. The implementation phase was skipped,
and the loop is running in code review mode only.

## Mode: Code Review Only

The goal tracker is not used in skip-impl mode because:
- There is no implementation plan to track
- The loop focuses solely on code review quality
- No acceptance criteria tracking is needed

## What This Loop Does

1. Runs `codex review` on changes between base branch and current branch
2. If issues are found, Claude fixes them iteratively
3. When no issues remain, enters finalize phase for code simplification

GOAL_TRACKER_EOF

else
    # Normal mode: create full goal tracker

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
    # Use || true after sed to ignore SIGPIPE when head closes the pipe early (pipefail mode)
    GOAL_SECTION=$({ sed -n '/^##[[:space:]]*[Gg]oal\|^##[[:space:]]*[Oo]bjective\|^##[[:space:]]*[Pp]urpose/,/^##/p' "$FULL_PLAN_PATH" || true; } | head -20 | tail -n +2 | head -10)
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
# Use || true after sed to ignore SIGPIPE when head closes the pipe early (pipefail mode)
AC_SECTION=$({ sed -n '/^##[[:space:]]*[Aa]cceptance\|^##[[:space:]]*[Cc]riteria\|^##[[:space:]]*[Rr]equirements/,/^##/p' "$FULL_PLAN_PATH" 2>/dev/null || true; } | head -30 | tail -n +2 | head -25)
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

fi  # End of skip-impl goal tracker handling

# ========================================
# Create Initial Prompt
# ========================================

SUMMARY_PATH="$LOOP_DIR/round-0-summary.md"

if [[ "$SKIP_IMPL" == "true" ]]; then
    # Skip-impl mode: create a prompt for code review only
    cat > "$LOOP_DIR/round-0-prompt.md" << EOF
# Skip Implementation Mode - Code Review Loop

This RLCR loop was started with \`--skip-impl\` flag.

**Mode**: Code Review Only (skipping implementation phase)
**Base Branch**: $BASE_BRANCH
**Current Branch**: $START_BRANCH

## What This Means

The loop will automatically run \`codex review\` on your changes when you try to exit.
If issues are found (marked with [P0-9] priority), you'll need to fix them before the loop ends.
Do not try to execute anything to trigger the review - just stop and it will run automatically.

## Your Task

1. Review your current work
2. When ready, try to exit - Codex will review your code
3. Fix any issues Codex finds
4. Repeat until no issues remain
5. Enter finalize phase for code simplification

## Note

Since this is skip-impl mode, there is no implementation plan to follow.
The goal tracker is not used - focus on fixing code review issues.

When you're ready for review, write a brief summary of your changes and try to exit (do not try to execute anything, just stop).

Write your summary to: @$SUMMARY_PATH

EOF
else
    # Normal mode: create full implementation prompt

# Write prompt header
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

For all tasks that need to be completed, please use the Task system (TaskCreate, TaskUpdate, TaskList) to track each item in order of importance.
You are strictly prohibited from only addressing the most important issues - you MUST create Tasks for ALL discovered issues and attempt to resolve each one.

EOF

# Append plan content directly (avoids command substitution size limits for large files)
cat "$LOOP_DIR/plan.md" >> "$LOOP_DIR/round-0-prompt.md"

# Inject agent-teams instructions if enabled
if [[ "$AGENT_TEAMS" == "true" ]]; then
    AGENT_TEAMS_TEMPLATE="$TEMPLATE_DIR/claude/agent-teams-instructions.md"
    if [[ -f "$AGENT_TEAMS_TEMPLATE" ]]; then
        echo "" >> "$LOOP_DIR/round-0-prompt.md"
        cat "$AGENT_TEAMS_TEMPLATE" >> "$LOOP_DIR/round-0-prompt.md"
    else
        cat >> "$LOOP_DIR/round-0-prompt.md" << 'AGENT_TEAMS_EOF'

## Agent Teams Mode

You are operating in **Agent Teams mode** as the **Team Leader**.

Split tasks into independent units, create agent teams to execute them, and coordinate team members.
Do NOT do implementation work yourself - delegate all coding to team members.
Prevent overlapping changes by assigning clear file ownership boundaries.
AGENT_TEAMS_EOF
    fi
fi

# Write prompt footer
cat >> "$LOOP_DIR/round-0-prompt.md" << EOF

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

fi  # End of skip-impl prompt handling

# ========================================
# Output Setup Message
# ========================================

# All important work is done. If output fails due to SIGPIPE (pipe closed), exit cleanly.
# This trap is set here (not at script start) to avoid affecting internal pipelines.
trap 'exit 0' PIPE

if [[ "$SKIP_IMPL" == "true" ]]; then
    cat << EOF
=== start-rlcr-loop activated (SKIP-IMPL MODE) ===

Mode: Code Review Only (--skip-impl)
Start Branch: $START_BRANCH
Base Branch: $BASE_BRANCH
Codex Model: $CODEX_MODEL
Codex Effort: $CODEX_EFFORT
Codex Timeout: ${CODEX_TIMEOUT}s
Loop Directory: $LOOP_DIR

Skip-impl mode is active. The implementation phase is skipped.
When you try to exit, codex review will run automatically by itself.

The loop will:
1. Run codex review on changes between $BASE_BRANCH and $START_BRANCH
2. If issues are found ([P0-9] markers), you'll need to fix them
3. When no issues remain, enters Finalize Phase and loop ends

To cancel: /humanize:cancel-rlcr-loop

---

EOF
else
    cat << EOF
=== start-rlcr-loop activated ===

Plan File: $PLAN_FILE ($LINE_COUNT lines)
Plan Tracked: $TRACK_PLAN_FILE
Start Branch: $START_BRANCH
Base Branch: $BASE_BRANCH
Max Iterations: $MAX_ITERATIONS
Codex Model: $CODEX_MODEL
Codex Effort: $CODEX_EFFORT
Codex Timeout: ${CODEX_TIMEOUT}s
Full Review Round: $FULL_REVIEW_ROUND (Full Alignment Checks at rounds $((FULL_REVIEW_ROUND - 1)), $((2 * FULL_REVIEW_ROUND - 1)), $((3 * FULL_REVIEW_ROUND - 1)), ...)
Ask User for Codex Questions: $ASK_CODEX_QUESTION
Loop Directory: $LOOP_DIR

The loop is now active. When you try to exit:
1. Codex will review your work summary
2. If issues are found, you'll receive feedback and continue
3. If Codex outputs "COMPLETE", enters Review Phase (code review)
4. Code review checks for [P0-9] issues; if found, you fix them
5. When no issues found, enters Finalize Phase and loop ends

To cancel: /humanize:cancel-rlcr-loop

---

EOF
fi

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

# Explicit exit 0 to ensure clean exit code even if final output fails
exit 0
