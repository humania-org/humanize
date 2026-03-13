#!/bin/bash

set -euo pipefail

# ========================================
# Source Shared Libraries
# ========================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
source "$SCRIPT_DIR/lib/config-loader.sh"
source "$SCRIPT_DIR/lib/model-router.sh"

PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
MERGED_CONFIG="$(load_merged_config "$PLUGIN_ROOT" "$PROJECT_ROOT")"
BITLESSON_MODEL="$(get_config_value "$MERGED_CONFIG" "bitlesson_model")"
BITLESSON_MODEL="${BITLESSON_MODEL:-haiku}"

# Source portable timeout wrapper
source "$SCRIPT_DIR/portable-timeout.sh"

# Source shared loop library (kept for consistency with ask-codex.sh)
HOOKS_LIB_DIR="$(cd "$SCRIPT_DIR/../hooks/lib" && pwd)"
source "$HOOKS_LIB_DIR/loop-common.sh"

usage() {
    cat <<'USAGE_EOF' >&2
Usage:
  bitlesson-select.sh --task <string> --paths <comma-separated> --bitlesson-file <path>

Output (exactly):
  LESSON_IDS: <comma-separated IDs or NONE>
  RATIONALE: <one concise sentence>
USAGE_EOF
}

TASK=""
PATHS=""
BITLESSON_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --task)
            TASK="${2:-}"
            shift 2
            ;;
        --paths)
            PATHS="${2:-}"
            shift 2
            ;;
        --bitlesson-file)
            BITLESSON_FILE="${2:-}"
            shift 2
            ;;
        *)
            echo "Error: Unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$TASK" ]]; then
    echo "Error: --task is required and must be non-empty" >&2
    usage
    exit 1
fi

if [[ -z "$PATHS" ]]; then
    echo "Error: --paths is required and must be non-empty" >&2
    usage
    exit 1
fi

if [[ -z "$BITLESSON_FILE" ]]; then
    echo "Error: --bitlesson-file is required" >&2
    usage
    exit 1
fi

# ========================================
# Determine Provider from BITLESSON_MODEL
# ========================================

BITLESSON_PROVIDER="$(detect_provider "$BITLESSON_MODEL")"

# ========================================
# Conditional Dependency Check (with fallback)
# ========================================

if ! check_provider_dependency "$BITLESSON_PROVIDER" 2>/dev/null; then
    # Fall back to codex provider when the configured provider binary is missing
    BITLESSON_MODEL="$DEFAULT_CODEX_MODEL"
    BITLESSON_PROVIDER="codex"
    check_provider_dependency "$BITLESSON_PROVIDER"
fi

if [[ ! -f "$BITLESSON_FILE" ]]; then
    echo "Error: BitLesson file not found: $BITLESSON_FILE" >&2
    exit 1
fi

BITLESSON_CONTENT="$(cat "$BITLESSON_FILE")"
if [[ -z "$(printf '%s' "$BITLESSON_CONTENT" | tr -d ' \t\n\r')" ]]; then
    echo "Error: BitLesson file is empty (whitespace only): $BITLESSON_FILE" >&2
    exit 1
fi

# ========================================
# Detect Project Root (for -C)
# ========================================

BITLESSON_DIR="$(cd "$(dirname "$BITLESSON_FILE")" && pwd -P)"
if git -C "$BITLESSON_DIR" rev-parse --show-toplevel &>/dev/null; then
    CODEX_PROJECT_ROOT="$(git -C "$BITLESSON_DIR" rev-parse --show-toplevel)"
else
    CODEX_PROJECT_ROOT="$BITLESSON_DIR"
fi

# ========================================
# Build Selector Prompt
# ========================================

PROMPT="$(cat <<EOF
# BitLesson Selector

You select which lessons from the configured BitLesson file (normally \`.humanize/bitlesson.md\`) must be applied for a given sub-task.

## Input

Sub-task description:
$TASK

Related file paths (comma-separated):
$PATHS

BitLesson file content:
<<<BEGIN_BITLESSON_MD
$BITLESSON_CONTENT
<<<END_BITLESSON_MD

## Decision Rules

1. Match only lessons that are directly relevant to the sub-task scope and failure mode.
2. Prefer precision over recall: do not include weakly related lessons.
3. If nothing is relevant, return \`NONE\`.

## Output Format (Stable)

Return exactly two lines (no code blocks, no extra whitespace, no additional sections):

LESSON_IDS: <comma-separated lesson IDs or NONE>
RATIONALE: <one concise sentence>
EOF
)"

# ========================================
# Run Selector (Codex or Claude)
# ========================================

SELECTOR_TIMEOUT=120

CODEX_EXIT_CODE=0
if [[ "$BITLESSON_PROVIDER" == "codex" ]]; then
    CODEX_EXEC_ARGS=("-m" "$BITLESSON_MODEL" "-c" "model_reasoning_effort=high")

    # Determine automation flag based on environment variable (same as ask-codex.sh)
    CODEX_AUTO_FLAG="--full-auto"
    if [[ "${HUMANIZE_CODEX_BYPASS_SANDBOX:-}" == "true" ]] || [[ "${HUMANIZE_CODEX_BYPASS_SANDBOX:-}" == "1" ]]; then
        CODEX_AUTO_FLAG="--dangerously-bypass-approvals-and-sandbox"
    fi
    CODEX_EXEC_ARGS+=("$CODEX_AUTO_FLAG" "-C" "$CODEX_PROJECT_ROOT")

    RAW_OUTPUT="$(printf '%s' "$PROMPT" | run_with_timeout "$SELECTOR_TIMEOUT" codex exec "${CODEX_EXEC_ARGS[@]}" -)" || CODEX_EXIT_CODE=$?
elif [[ "$BITLESSON_PROVIDER" == "claude" ]]; then
    RAW_OUTPUT="$(printf '%s' "$PROMPT" | run_with_timeout "$SELECTOR_TIMEOUT" claude --print --model "$BITLESSON_MODEL" -)" || CODEX_EXIT_CODE=$?
fi

if [[ $CODEX_EXIT_CODE -eq 124 ]]; then
    echo "Error: BitLesson selector timed out after ${SELECTOR_TIMEOUT} seconds" >&2
    exit 124
fi

if [[ $CODEX_EXIT_CODE -ne 0 ]]; then
    echo "Error: BitLesson selector failed (exit code $CODEX_EXIT_CODE)" >&2
    exit "$CODEX_EXIT_CODE"
fi

# ========================================
# Enforce Stable Output Format
# ========================================

LESSON_IDS_VALUE="$(
    printf '%s\n' "$RAW_OUTPUT" \
        | sed -n 's/^[[:space:]]*LESSON_IDS:[[:space:]]*//p' \
        | head -n 1 \
        | tr -d '\r' \
        | sed 's/[[:space:]]*$//'
)"

RATIONALE_VALUE="$(
    printf '%s\n' "$RAW_OUTPUT" \
        | sed -n 's/^[[:space:]]*RATIONALE:[[:space:]]*//p' \
        | head -n 1 \
        | tr -d '\r' \
        | sed 's/[[:space:]]*$//'
)"

if [[ -z "$LESSON_IDS_VALUE" || -z "$RATIONALE_VALUE" ]]; then
    echo "Error: Unexpected selector output format (expected LESSON_IDS and RATIONALE lines)" >&2
    echo "" >&2
    echo "Raw output:" >&2
    printf '%s\n' "$RAW_OUTPUT" >&2
    exit 1
fi

printf 'LESSON_IDS: %s\n' "$LESSON_IDS_VALUE"
printf 'RATIONALE: %s\n' "$RATIONALE_VALUE"
