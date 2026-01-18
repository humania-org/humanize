#!/bin/bash
#
# Cancel script for cancel-pr-loop
#
# Cancels an active PR loop by creating a cancel signal file
# and renaming the state file to cancel-state.md.
#
# Usage:
#   cancel-pr-loop.sh [--force]
#
# Exit codes:
#   0 - Successfully cancelled
#   1 - No active loop found
#   2 - Reserved for future use (e.g., confirmation required)
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
cancel-pr-loop.sh - Cancel active PR loop

USAGE:
  cancel-pr-loop.sh [OPTIONS]

OPTIONS:
  --force        Force cancel (currently has no additional effect)
  -h, --help     Show this help message

EXIT CODES:
  0 - Successfully cancelled
  1 - No active loop found
  3 - Other error

DESCRIPTION:
  Cancels the active PR loop by:
  1. Finding the most recent PR loop directory
  2. Creating a .cancel-requested signal file
  3. Renaming state.md to cancel-state.md

NOTE:
  This command only affects PR loops (.humanize/pr-loop/).
  RLCR loops (.humanize/rlcr/) are not affected.
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
LOOP_BASE_DIR="$PROJECT_ROOT/.humanize/pr-loop"

# Find newest loop directory (different from RLCR - uses pr-loop instead of rlcr)
LOOP_DIR=$(ls -1d "$LOOP_BASE_DIR"/*/ 2>/dev/null | sort -r | head -1) || true

if [[ -z "$LOOP_DIR" ]]; then
    echo "NO_LOOP"
    echo "No active PR loop found."
    exit 1
fi

# ========================================
# Check Loop State
# ========================================

STATE_FILE="$LOOP_DIR/state.md"
CANCEL_SIGNAL="$LOOP_DIR/.cancel-requested"

if [[ -f "$STATE_FILE" ]]; then
    LOOP_STATE="ACTIVE"
    ACTIVE_STATE_FILE="$STATE_FILE"
else
    echo "NO_ACTIVE_LOOP"
    echo "No active PR loop found. The loop directory exists but no active state file is present."
    exit 1
fi

# ========================================
# Extract Round Info
# ========================================

# Extract current_round and max_iterations from the state file
CURRENT_ROUND=$(grep -E '^current_round:' "$ACTIVE_STATE_FILE" | sed 's/^current_round:[[:space:]]*//' | tr -d ' ')
MAX_ITERATIONS=$(grep -E '^max_iterations:' "$ACTIVE_STATE_FILE" | sed 's/^max_iterations:[[:space:]]*//' | tr -d ' ')
PR_NUMBER=$(grep -E '^pr_number:' "$ACTIVE_STATE_FILE" | sed 's/^pr_number:[[:space:]]*//' | tr -d ' ')

# Default values if not found
CURRENT_ROUND=${CURRENT_ROUND:-"?"}
MAX_ITERATIONS=${MAX_ITERATIONS:-"?"}
PR_NUMBER=${PR_NUMBER:-"?"}

# ========================================
# Perform Cancellation
# ========================================

# Create cancel signal file
touch "$CANCEL_SIGNAL"

# Rename state file to cancel-state.md
mv "$ACTIVE_STATE_FILE" "$LOOP_DIR/cancel-state.md"

# ========================================
# Output Result
# ========================================

echo "CANCELLED"
echo "Cancelled PR loop for PR #$PR_NUMBER (was at round $CURRENT_ROUND of $MAX_ITERATIONS)."
echo "State preserved as cancel-state.md"

exit 0
