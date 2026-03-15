#!/bin/bash
#
# Run RLCR stop-hook logic from non-hook environments (e.g. skill workflows).
#
# This script wraps hooks/loop-codex-stop-hook.sh so skills can reuse the same
# enforcement logic and phase transitions that the hook uses.
#
# Exit codes:
#   0   - Gate allowed (no active loop block)
#   10  - Gate blocked (follow returned reason/instructions and continue loop)
#   20  - Wrapper/runtime error
#
# Usage:
#   scripts/rlcr-stop-gate.sh [--session-id ID] [--transcript-path PATH] [--project-root PATH] [--json]
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HUMANIZE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
HOOK_SCRIPT="$HUMANIZE_ROOT/hooks/loop-codex-stop-hook.sh"

SESSION_ID="${CLAUDE_SESSION_ID:-}"
TRANSCRIPT_PATH="${CLAUDE_TRANSCRIPT_PATH:-}"
PRINT_JSON="false"
HOOK_MODEL="${CODEX_MODEL:-humanize-skill-gate}"
HOOK_PERMISSION_MODE="${CODEX_PERMISSION_MODE:-default}"

usage() {
    cat <<'EOF'
Usage: rlcr-stop-gate.sh [options]

Options:
  --session-id ID         Session ID forwarded to hook input
  --transcript-path PATH  Transcript path forwarded to hook input
  --project-root PATH     Project root (default: repo root)
  --json                  Print raw hook JSON on block
  -h, --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --session-id)
            [[ -n "${2:-}" ]] || { echo "Error: --session-id requires a value" >&2; exit 20; }
            SESSION_ID="$2"
            shift 2
            ;;
        --transcript-path)
            [[ -n "${2:-}" ]] || { echo "Error: --transcript-path requires a value" >&2; exit 20; }
            TRANSCRIPT_PATH="$2"
            shift 2
            ;;
        --project-root)
            [[ -n "${2:-}" ]] || { echo "Error: --project-root requires a value" >&2; exit 20; }
            PROJECT_ROOT="$2"
            shift 2
            ;;
        --json)
            PRINT_JSON="true"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: Unknown option: $1" >&2
            usage >&2
            exit 20
            ;;
    esac
done

if [[ ! -x "$HOOK_SCRIPT" ]]; then
    echo "Error: Hook script not found or not executable: $HOOK_SCRIPT" >&2
    exit 20
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required by rlcr-stop-gate.sh" >&2
    exit 20
fi

# Build hook input JSON while omitting empty fields.
# Include standard Stop hook fields so the underlying hook sees the same schema
# as a real Claude Code Stop event (hook_event_name, stop_hook_active, cwd).
HOOK_INPUT=$(jq -n \
    --arg session_id "$SESSION_ID" \
    --arg transcript_path "$TRANSCRIPT_PATH" \
    --arg cwd "$PROJECT_ROOT" \
    --arg model "$HOOK_MODEL" \
    --arg permission_mode "$HOOK_PERMISSION_MODE" \
    '{
        hook_event_name: "Stop",
        stop_hook_active: false,
        cwd: $cwd,
        model: $model,
        permission_mode: $permission_mode,
        last_assistant_message: null,
        session_id: ($session_id | select(length > 0)),
        transcript_path: ($transcript_path | select(length > 0))
    }')

# Capture hook exit code explicitly to map non-zero to exit 20 (wrapper error)
# instead of letting set -e propagate the raw hook exit code.
HOOK_EXIT=0
HOOK_OUTPUT="$(printf '%s' "$HOOK_INPUT" | CLAUDE_PROJECT_DIR="$PROJECT_ROOT" "$HOOK_SCRIPT")" || HOOK_EXIT=$?

if [[ $HOOK_EXIT -ne 0 ]]; then
    echo "Error: Hook script exited with code $HOOK_EXIT" >&2
    [[ -n "$HOOK_OUTPUT" ]] && printf '%s\n' "$HOOK_OUTPUT" >&2
    exit 20
fi

# No JSON response means hook allowed exit.
if [[ -z "$HOOK_OUTPUT" ]]; then
    echo "ALLOW: stop gate passed."
    exit 0
fi

if ! printf '%s' "$HOOK_OUTPUT" | jq -e '.' >/dev/null 2>&1; then
    echo "Error: Hook returned non-JSON output" >&2
    printf '%s\n' "$HOOK_OUTPUT" >&2
    exit 20
fi

DECISION="$(printf '%s' "$HOOK_OUTPUT" | jq -r '.decision // empty')"
SYSTEM_MESSAGE="$(printf '%s' "$HOOK_OUTPUT" | jq -r '.systemMessage // empty')"
REASON="$(printf '%s' "$HOOK_OUTPUT" | jq -r '.reason // empty')"

if [[ "$DECISION" == "block" ]]; then
    if [[ "$PRINT_JSON" == "true" ]]; then
        printf '%s\n' "$HOOK_OUTPUT"
    else
        [[ -n "$SYSTEM_MESSAGE" ]] && printf 'BLOCK: %s\n' "$SYSTEM_MESSAGE"
        [[ -n "$REASON" ]] && printf '%s\n' "$REASON"
    fi
    exit 10
fi

echo "Error: Unexpected hook decision: ${DECISION:-<empty>}" >&2
printf '%s\n' "$HOOK_OUTPUT" >&2
exit 20
