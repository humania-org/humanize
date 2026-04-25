#!/usr/bin/env bash
#
# Session-scoped cancel helper for the Humanize Viz dashboard.
#
# Cancels a single RLCR session by id, leaving any other active
# sessions in the same project untouched. Mirrors the cancel
# mechanism in scripts/cancel-rlcr-loop.sh (touch a .cancel-requested
# signal, rename the active state file to cancel-state.md) but scoped
# to the named session directory rather than the project's most
# recent active session.
#
# Usage:
#   cancel-rlcr-session.sh --session-id <SID> [--project <path>] [--force]
#   cancel-rlcr-session.sh <SID>                                       # legacy
#
# Exit codes:
#   0 - Successfully cancelled
#   1 - No such session, or no active state file in the session dir
#   2 - Finalize phase detected, --force required
#   3 - Other error (missing arguments, unreadable directory)

set -euo pipefail

SESSION_ID=""
PROJECT_ROOT=""
FORCE="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --session-id) SESSION_ID="$2"; shift 2 ;;
        --project)    PROJECT_ROOT="$2"; shift 2 ;;
        --force)      FORCE="true"; shift ;;
        -h|--help)
            sed -n '2,/^set -euo/p' "$0" | head -n -1
            exit 0
            ;;
        --) shift ;;
        *)
            # Legacy positional: first non-flag is the session id.
            if [[ -z "$SESSION_ID" ]]; then
                SESSION_ID="$1"
            else
                echo "Error: unexpected positional argument: $1" >&2
                exit 3
            fi
            shift
            ;;
    esac
done

if [[ -z "$SESSION_ID" ]]; then
    echo "Error: --session-id is required" >&2
    echo "Usage: cancel-rlcr-session.sh --session-id <SID> [--project <path>] [--force]" >&2
    exit 3
fi

# Reject session ids that could escape the per-project rlcr directory.
# Valid ids are produced by ``setup-rlcr-loop.sh`` from
# ``date +"%Y-%m-%d_%H-%M-%S"`` (digits, dashes, underscores). Allow
# the same shape plus a handful of safe extras (alphanumerics, dots as
# non-traversal separators) and explicitly reject path separators,
# leading dots, and any parent-directory token so values like
# ``../foo`` or ``/etc/passwd`` cannot rename state files outside the
# session tree.
if [[ "$SESSION_ID" == *"/"* || "$SESSION_ID" == *"\\"* ]]; then
    echo "Error: invalid --session-id (contains path separator): $SESSION_ID" >&2
    exit 3
fi
if [[ "$SESSION_ID" == "." || "$SESSION_ID" == ".." || "$SESSION_ID" == ..* || "$SESSION_ID" == .* ]]; then
    echo "Error: invalid --session-id (leading dot or parent token): $SESSION_ID" >&2
    exit 3
fi
if [[ ! "$SESSION_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Error: invalid --session-id (allowed: alphanumerics, dot, underscore, dash): $SESSION_ID" >&2
    exit 3
fi

if [[ -z "$PROJECT_ROOT" ]]; then
    PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
fi
PROJECT_ROOT="$(cd "$PROJECT_ROOT" 2>/dev/null && pwd)" || {
    echo "Error: project directory not found: $PROJECT_ROOT" >&2
    exit 3
}

SESSION_DIR="$PROJECT_ROOT/.humanize/rlcr/$SESSION_ID"

if [[ ! -d "$SESSION_DIR" ]]; then
    echo "NO_SESSION"
    echo "No such session: $SESSION_ID under $PROJECT_ROOT/.humanize/rlcr/" >&2
    exit 1
fi

STATE_FILE="$SESSION_DIR/state.md"
FINALIZE_STATE_FILE="$SESSION_DIR/finalize-state.md"
METHODOLOGY_ANALYSIS_STATE_FILE="$SESSION_DIR/methodology-analysis-state.md"
CANCEL_SIGNAL="$SESSION_DIR/.cancel-requested"

if [[ -f "$STATE_FILE" ]]; then
    LOOP_STATE="NORMAL_LOOP"
    ACTIVE_STATE_FILE="$STATE_FILE"
elif [[ -f "$METHODOLOGY_ANALYSIS_STATE_FILE" ]]; then
    LOOP_STATE="METHODOLOGY_ANALYSIS_PHASE"
    ACTIVE_STATE_FILE="$METHODOLOGY_ANALYSIS_STATE_FILE"
elif [[ -f "$FINALIZE_STATE_FILE" ]]; then
    LOOP_STATE="FINALIZE_PHASE"
    ACTIVE_STATE_FILE="$FINALIZE_STATE_FILE"
else
    echo "NO_ACTIVE_LOOP"
    echo "Session $SESSION_ID has no active state file." >&2
    exit 1
fi

if [[ "$LOOP_STATE" == "FINALIZE_PHASE" && "$FORCE" != "true" ]]; then
    echo "FINALIZE_NEEDS_CONFIRM"
    echo "session: $SESSION_ID is in Finalize Phase. Re-run with --force to cancel anyway." >&2
    exit 2
fi

touch "$CANCEL_SIGNAL"
mv "$ACTIVE_STATE_FILE" "$SESSION_DIR/cancel-state.md"

echo "CANCELLED $SESSION_ID"
echo "Cancelled session $SESSION_ID; other active sessions in $PROJECT_ROOT are untouched."
exit 0
