#!/bin/bash
#
# Cancel script for cancel-rlcr-loop
#
# Cancels an active RLCR loop by creating a cancel signal file
# and renaming the state file to cancel-state.md.
#
# Usage:
#   cancel-rlcr-loop.sh [--force]
#
# Exit codes:
#   0 - Successfully cancelled
#   1 - No active loop found
#   2 - Finalize phase detected, confirmation required (use --force to override)
#   3 - Other error
#

set -euo pipefail

# ========================================
# Parse Arguments
# ========================================

FORCE="false"

while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE="true"
            shift
            ;;
        -h|--help)
            cat << 'HELP_EOF'
cancel-rlcr-loop - Cancel active RLCR loop

USAGE:
  cancel-rlcr-loop.sh [OPTIONS]

OPTIONS:
  --force        Force cancel even during Finalize Phase
  -h, --help     Show this help message

EXIT CODES:
  0 - Successfully cancelled
  1 - No active loop found
  2 - Finalize phase detected, confirmation required
  3 - Other error

DESCRIPTION:
  Cancels the active RLCR loop by:
  1. Finding the most recent loop directory
  2. Creating a .cancel-requested signal file
  3. Renaming state.md or finalize-state.md to cancel-state.md
HELP_EOF
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Use --help for usage information" >&2
            exit 3
            ;;
    esac
done

# ========================================
# Find Loop Directory
# ========================================

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
LOOP_BASE_DIR="$PROJECT_ROOT/.humanize/rlcr"

# Source shared loop library for find_active_loop
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/../hooks/lib/loop-common.sh"

# PRODUCT DECISION: Cancel operates globally (no session_id filtering).
#
# Cancel is invoked as a standalone Bash command via /cancel-rlcr-loop slash command.
# Unlike hooks (PreToolUse, PostToolUse, Stop) which receive JSON with session_id,
# this script has no access to the calling session's session_id.
#
# This is intentional per AC-6: cancel is an explicit user action that should always
# succeed regardless of which session invokes it. If a user types /cancel-rlcr-loop,
# they want to cancel whatever loop is running in the current project directory.
#
# Find newest active loop directory (any session) using the same lookup as hooks
LOOP_DIR=$(find_active_loop "$LOOP_BASE_DIR")

if [[ -z "$LOOP_DIR" ]]; then
    echo "NO_LOOP"
    echo "No active RLCR loop found."
    exit 1
fi

# ========================================
# Check Loop State
# ========================================

STATE_FILE="$LOOP_DIR/state.md"
FINALIZE_STATE_FILE="$LOOP_DIR/finalize-state.md"
CANCEL_SIGNAL="$LOOP_DIR/.cancel-requested"

if [[ -f "$STATE_FILE" ]]; then
    LOOP_STATE="NORMAL_LOOP"
    ACTIVE_STATE_FILE="$STATE_FILE"
elif [[ -f "$FINALIZE_STATE_FILE" ]]; then
    LOOP_STATE="FINALIZE_PHASE"
    ACTIVE_STATE_FILE="$FINALIZE_STATE_FILE"
else
    echo "NO_ACTIVE_LOOP"
    echo "No active RLCR loop found. The loop directory exists but no active state file is present."
    exit 1
fi

# ========================================
# Extract Round Info
# ========================================

# Extract current_round and max_iterations from the state file
CURRENT_ROUND=$(grep -E '^current_round:' "$ACTIVE_STATE_FILE" | sed 's/^current_round:[[:space:]]*//' | tr -d ' ')
MAX_ITERATIONS=$(grep -E '^max_iterations:' "$ACTIVE_STATE_FILE" | sed 's/^max_iterations:[[:space:]]*//' | tr -d ' ')

# Default values if not found
CURRENT_ROUND=${CURRENT_ROUND:-"?"}
MAX_ITERATIONS=${MAX_ITERATIONS:-"?"}

# ========================================
# Handle Finalize Phase
# ========================================

if [[ "$LOOP_STATE" == "FINALIZE_PHASE" && "$FORCE" != "true" ]]; then
    echo "FINALIZE_NEEDS_CONFIRM"
    echo "loop_dir: $LOOP_DIR"
    echo "current_round: $CURRENT_ROUND"
    echo "max_iterations: $MAX_ITERATIONS"
    echo ""
    echo "The loop is currently in Finalize Phase."
    echo "After this phase completes, the loop will end without returning to Codex review."
    echo ""
    echo "Use --force to cancel anyway."
    exit 2
fi

# ========================================
# Perform Cancellation
# ========================================

# Create cancel signal file
touch "$CANCEL_SIGNAL"

# Clean up any pending session_id signal file (setup may not have completed)
rm -f "$PROJECT_ROOT/.humanize/.pending-session-id"

# Rename state file to cancel-state.md
mv "$ACTIVE_STATE_FILE" "$LOOP_DIR/cancel-state.md"

# ========================================
# Output Result
# ========================================

if [[ "$LOOP_STATE" == "NORMAL_LOOP" ]]; then
    echo "CANCELLED"
    echo "Cancelled RLCR loop (was at round $CURRENT_ROUND of $MAX_ITERATIONS)."
    echo "State preserved as cancel-state.md"
else
    echo "CANCELLED_FINALIZE"
    echo "Cancelled RLCR loop during Finalize Phase (was at round $CURRENT_ROUND of $MAX_ITERATIONS)."
    echo "State preserved as cancel-state.md"
fi

exit 0
