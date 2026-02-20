#!/bin/bash
#
# Ask Codex - One-shot consultation with Codex
#
# Sends a question or task to codex exec and returns the response.
# This is an active, one-shot skill (unlike the passive RLCR loop).
#
# Usage:
#   ask-codex.sh [--codex-model MODEL:EFFORT] [--codex-timeout SECONDS] [question...]
#
# Output:
#   stdout: Codex's response (for Claude to read)
#   stderr: Status/debug info (model, effort, log paths)
#
# Storage:
#   Project-local: .humanize/skill/<timestamp>/{input,output,metadata}.md
#   Cache: ~/.cache/humanize/<sanitized-path>/skill-<timestamp>/codex-run.{cmd,out,log}
#

set -euo pipefail

# ========================================
# Source Shared Libraries
# ========================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Source portable timeout wrapper
source "$SCRIPT_DIR/portable-timeout.sh"

# Source shared loop library for DEFAULT_CODEX_MODEL and DEFAULT_CODEX_EFFORT
HOOKS_LIB_DIR="$(cd "$SCRIPT_DIR/../hooks/lib" && pwd)"
source "$HOOKS_LIB_DIR/loop-common.sh"

# ========================================
# Default Configuration
# ========================================

DEFAULT_ASK_CODEX_TIMEOUT=600

CODEX_MODEL="$DEFAULT_CODEX_MODEL"
CODEX_EFFORT="$DEFAULT_CODEX_EFFORT"
CODEX_TIMEOUT="$DEFAULT_ASK_CODEX_TIMEOUT"

# ========================================
# Help
# ========================================

show_help() {
    cat << 'HELP_EOF'
ask-codex - One-shot consultation with Codex

USAGE:
  /humanize:ask-codex [OPTIONS] <question or task>

OPTIONS:
  --codex-model <MODEL:EFFORT>
                       Codex model and reasoning effort (default: gpt-5.3-codex:xhigh)
  --codex-timeout <SECONDS>
                       Timeout for the Codex query in seconds (default: 600)
  -h, --help           Show this help message

DESCRIPTION:
  Sends a one-shot question or task to Codex and returns the response.
  Unlike the RLCR loop, this is a single consultation without iteration.

  The response is saved to .humanize/skill/<timestamp>/output.md for reference.

EXAMPLES:
  /humanize:ask-codex How should I structure the authentication module?
  /humanize:ask-codex --codex-model gpt-5.3-codex:high What are the performance bottlenecks?
  /humanize:ask-codex --codex-timeout 300 Review the error handling in src/api/

ENVIRONMENT:
  HUMANIZE_CODEX_BYPASS_SANDBOX
    Set to "true" or "1" to bypass Codex sandbox protections.
    WARNING: This is dangerous. See README for details.
HELP_EOF
    exit 0
}

# ========================================
# Parse Arguments
# ========================================

QUESTION_PARTS=()
OPTIONS_DONE=false

while [[ $# -gt 0 ]]; do
    if [[ "$OPTIONS_DONE" == "true" ]]; then
        # After first positional token or --, all remaining args are question text
        QUESTION_PARTS+=("$1")
        shift
        continue
    fi
    case $1 in
        -h|--help)
            show_help
            ;;
        --)
            # Explicit end-of-options marker
            OPTIONS_DONE=true
            shift
            ;;
        --codex-model)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --codex-model requires a MODEL:EFFORT argument" >&2
                exit 1
            fi
            # Parse MODEL:EFFORT format (same pattern as setup-rlcr-loop.sh)
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
        -*)
            echo "Error: Unknown option: $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
        *)
            # First positional token: stop parsing options, rest is question
            QUESTION_PARTS+=("$1")
            OPTIONS_DONE=true
            shift
            ;;
    esac
done

# Join question parts into a single string
QUESTION="${QUESTION_PARTS[*]}"

# ========================================
# Validate Prerequisites
# ========================================

# Check codex is available
if ! command -v codex &>/dev/null; then
    echo "Error: 'codex' command is not installed or not in PATH" >&2
    echo "" >&2
    echo "Please install Codex CLI: https://github.com/openai/codex" >&2
    echo "Then retry: /humanize:ask-codex <your question>" >&2
    exit 1
fi

# Check question is not empty
if [[ -z "$QUESTION" ]]; then
    echo "Error: No question or task provided" >&2
    echo "" >&2
    echo "Usage: /humanize:ask-codex [OPTIONS] <question or task>" >&2
    echo "" >&2
    echo "For help: /humanize:ask-codex --help" >&2
    exit 1
fi

# Validate codex model for safety (alphanumeric, hyphen, underscore, dot)
if [[ ! "$CODEX_MODEL" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "Error: Codex model contains invalid characters" >&2
    echo "  Model: $CODEX_MODEL" >&2
    echo "  Only alphanumeric, hyphen, underscore, dot allowed" >&2
    exit 1
fi

# Validate codex effort for safety (alphanumeric, hyphen, underscore)
if [[ ! "$CODEX_EFFORT" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "Error: Codex effort contains invalid characters" >&2
    echo "  Effort: $CODEX_EFFORT" >&2
    echo "  Only alphanumeric, hyphen, underscore allowed" >&2
    exit 1
fi

# ========================================
# Detect Project Root
# ========================================

if git rev-parse --show-toplevel &>/dev/null; then
    PROJECT_ROOT=$(git rev-parse --show-toplevel)
else
    PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
fi

# ========================================
# Create Storage Directories
# ========================================

TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)

# Project-local storage: .humanize/skill/<timestamp>/
SKILL_DIR="$PROJECT_ROOT/.humanize/skill/$TIMESTAMP"
mkdir -p "$SKILL_DIR"

# Cache storage: ~/.cache/humanize/<sanitized-path>/skill-<timestamp>/
# Falls back to project-local .humanize/cache/ if home cache is not writable
SANITIZED_PROJECT_PATH=$(echo "$PROJECT_ROOT" | sed 's/[^a-zA-Z0-9._-]/-/g' | sed 's/--*/-/g')
CACHE_BASE="${XDG_CACHE_HOME:-$HOME/.cache}"
CACHE_DIR="$CACHE_BASE/humanize/$SANITIZED_PROJECT_PATH/skill-$TIMESTAMP"
if ! mkdir -p "$CACHE_DIR" 2>/dev/null; then
    CACHE_DIR="$SKILL_DIR/cache"
    mkdir -p "$CACHE_DIR"
    echo "ask-codex: warning: home cache not writable, using $CACHE_DIR" >&2
fi

# ========================================
# Save Input
# ========================================

cat > "$SKILL_DIR/input.md" << EOF
# Ask Codex Input

## Question

$QUESTION

## Configuration

- Model: $CODEX_MODEL
- Effort: $CODEX_EFFORT
- Timeout: ${CODEX_TIMEOUT}s
- Timestamp: $TIMESTAMP
EOF

# ========================================
# Build Codex Command
# ========================================

# Build codex exec arguments (same pattern as loop-codex-stop-hook.sh)
CODEX_EXEC_ARGS=("-m" "$CODEX_MODEL")
if [[ -n "$CODEX_EFFORT" ]]; then
    CODEX_EXEC_ARGS+=("-c" "model_reasoning_effort=${CODEX_EFFORT}")
fi

# Determine automation flag based on environment variable
CODEX_AUTO_FLAG="--full-auto"
if [[ "${HUMANIZE_CODEX_BYPASS_SANDBOX:-}" == "true" ]] || [[ "${HUMANIZE_CODEX_BYPASS_SANDBOX:-}" == "1" ]]; then
    CODEX_AUTO_FLAG="--dangerously-bypass-approvals-and-sandbox"
fi

CODEX_EXEC_ARGS+=("$CODEX_AUTO_FLAG" "-C" "$PROJECT_ROOT")

# ========================================
# Save Debug Command
# ========================================

CODEX_CMD_FILE="$CACHE_DIR/codex-run.cmd"
CODEX_STDOUT_FILE="$CACHE_DIR/codex-run.out"
CODEX_STDERR_FILE="$CACHE_DIR/codex-run.log"

{
    echo "# Codex ask-codex invocation debug info"
    echo "# Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Working directory: $PROJECT_ROOT"
    echo "# Timeout: $CODEX_TIMEOUT seconds"
    echo ""
    echo "codex exec ${CODEX_EXEC_ARGS[*]} \"<prompt>\""
    echo ""
    echo "# Prompt content:"
    echo "$QUESTION"
} > "$CODEX_CMD_FILE"

# ========================================
# Run Codex
# ========================================

echo "ask-codex: model=$CODEX_MODEL effort=$CODEX_EFFORT timeout=${CODEX_TIMEOUT}s" >&2
echo "ask-codex: cache=$CACHE_DIR" >&2
echo "ask-codex: running codex exec..." >&2

# Portable epoch-to-ISO8601 formatter (GNU date -d vs BSD date -r)
epoch_to_iso() {
    local epoch="$1"
    date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    echo "unknown"
}

START_TIME=$(date +%s)

CODEX_EXIT_CODE=0
printf '%s' "$QUESTION" | run_with_timeout "$CODEX_TIMEOUT" codex exec "${CODEX_EXEC_ARGS[@]}" - \
    > "$CODEX_STDOUT_FILE" 2> "$CODEX_STDERR_FILE" || CODEX_EXIT_CODE=$?

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo "ask-codex: exit_code=$CODEX_EXIT_CODE duration=${DURATION}s" >&2

# ========================================
# Handle Results
# ========================================

# Check for timeout
if [[ $CODEX_EXIT_CODE -eq 124 ]]; then
    echo "Error: Codex timed out after ${CODEX_TIMEOUT} seconds" >&2
    echo "" >&2
    echo "Try increasing the timeout:" >&2
    echo "  /humanize:ask-codex --codex-timeout $((CODEX_TIMEOUT * 2)) <your question>" >&2
    echo "" >&2
    echo "Debug logs: $CACHE_DIR" >&2

    # Save metadata even on timeout
    cat > "$SKILL_DIR/metadata.md" << EOF
---
model: $CODEX_MODEL
effort: $CODEX_EFFORT
timeout: $CODEX_TIMEOUT
exit_code: 124
duration: ${DURATION}s
status: timeout
started_at: $(epoch_to_iso "$START_TIME")
---
EOF
    exit 124
fi

# Check for non-zero exit
if [[ $CODEX_EXIT_CODE -ne 0 ]]; then
    echo "Error: Codex exited with code $CODEX_EXIT_CODE" >&2
    if [[ -s "$CODEX_STDERR_FILE" ]]; then
        echo "" >&2
        echo "Codex stderr (last 20 lines):" >&2
        tail -20 "$CODEX_STDERR_FILE" >&2
    fi
    echo "" >&2
    echo "Debug logs: $CACHE_DIR" >&2

    # Save metadata
    cat > "$SKILL_DIR/metadata.md" << EOF
---
model: $CODEX_MODEL
effort: $CODEX_EFFORT
timeout: $CODEX_TIMEOUT
exit_code: $CODEX_EXIT_CODE
duration: ${DURATION}s
status: error
started_at: $(epoch_to_iso "$START_TIME")
---
EOF
    exit "$CODEX_EXIT_CODE"
fi

# Check for empty stdout
if [[ ! -s "$CODEX_STDOUT_FILE" ]]; then
    echo "Error: Codex returned empty response" >&2
    if [[ -s "$CODEX_STDERR_FILE" ]]; then
        echo "" >&2
        echo "Codex stderr (last 20 lines):" >&2
        tail -20 "$CODEX_STDERR_FILE" >&2
    fi
    echo "" >&2
    echo "Debug logs: $CACHE_DIR" >&2

    cat > "$SKILL_DIR/metadata.md" << EOF
---
model: $CODEX_MODEL
effort: $CODEX_EFFORT
timeout: $CODEX_TIMEOUT
exit_code: 0
duration: ${DURATION}s
status: empty_response
started_at: $(epoch_to_iso "$START_TIME")
---
EOF
    exit 1
fi

# ========================================
# Save Output and Metadata
# ========================================

# Save Codex response to project-local storage
cp "$CODEX_STDOUT_FILE" "$SKILL_DIR/output.md"

# Save metadata
cat > "$SKILL_DIR/metadata.md" << EOF
---
model: $CODEX_MODEL
effort: $CODEX_EFFORT
timeout: $CODEX_TIMEOUT
exit_code: 0
duration: ${DURATION}s
status: success
started_at: $(epoch_to_iso "$START_TIME")
---
EOF

echo "ask-codex: response saved to $SKILL_DIR/output.md" >&2

# ========================================
# Output Response
# ========================================

# Output Codex's response to stdout (clean output for Claude to read)
cat "$CODEX_STDOUT_FILE"
