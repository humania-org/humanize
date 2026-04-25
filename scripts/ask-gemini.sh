#!/usr/bin/env bash
#
# Ask Gemini - One-shot consultation with Gemini CLI
#
# Sends a question or task to gemini in non-interactive mode and returns
# the response.  Gemini is always instructed to leverage Google Search
# for deep web research.
#
# Usage:
#   ask-gemini.sh [--gemini-model MODEL] [--gemini-timeout SECONDS] [question...]
#
# Output:
#   stdout: Gemini's response (for Claude to read)
#   stderr: Status/debug info (model, log paths)
#
# Storage:
#   Project-local: .humanize/skill/<unique-id>/{input,output,metadata}.md
#   Cache: ~/.cache/humanize/<sanitized-path>/skill-<unique-id>/gemini-run.{cmd,out,log}
#

set -euo pipefail

# ========================================
# Source Shared Libraries
# ========================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Source portable timeout wrapper
source "$SCRIPT_DIR/portable-timeout.sh"

# Shared project-root resolver (CLAUDE_PROJECT_DIR -> git toplevel, realpath-canonical)
source "$SCRIPT_DIR/../hooks/lib/project-root.sh"

# ========================================
# Default Configuration
# ========================================

DEFAULT_GEMINI_MODEL="gemini-3.1-pro-preview"
DEFAULT_ASK_GEMINI_TIMEOUT=3600

GEMINI_MODEL="$DEFAULT_GEMINI_MODEL"
GEMINI_TIMEOUT="$DEFAULT_ASK_GEMINI_TIMEOUT"

# ========================================
# Help
# ========================================

show_help() {
    cat << 'HELP_EOF'
ask-gemini - One-shot deep-research consultation with Gemini

USAGE:
  /humanize:ask-gemini [OPTIONS] <question or task>

OPTIONS:
  --gemini-model <MODEL>
                       Gemini model name (default: gemini-3.1-pro-preview)
  --gemini-timeout <SECONDS>
                       Timeout for the Gemini query in seconds (default: 3600)
  -h, --help           Show this help message

DESCRIPTION:
  Sends a one-shot question or task to the Gemini CLI in non-interactive
  mode (-p).  The prompt is augmented with an instruction to perform web
  research via Google Search, making this ideal for deep-research tasks
  that benefit from up-to-date internet information.

  The response is saved to .humanize/skill/<unique-id>/output.md for reference.

EXAMPLES:
  /humanize:ask-gemini What are the latest best practices for Rust error handling?
  /humanize:ask-gemini --gemini-model gemini-2.5-pro Review recent CVEs for OpenSSL 3.x
  /humanize:ask-gemini --gemini-timeout 600 Compare React Server Components vs Astro Islands

ENVIRONMENT:
  HUMANIZE_GEMINI_YOLO
    Set to "true" or "1" to auto-approve all Gemini tool calls (--yolo).
    Default behaviour uses --sandbox mode.
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
        QUESTION_PARTS+=("$1")
        shift
        continue
    fi
    case $1 in
        -h|--help)
            show_help
            ;;
        --)
            OPTIONS_DONE=true
            shift
            ;;
        --gemini-model)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --gemini-model requires a MODEL argument" >&2
                exit 1
            fi
            GEMINI_MODEL="$2"
            shift 2
            ;;
        --gemini-timeout)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --gemini-timeout requires a number argument (seconds)" >&2
                exit 1
            fi
            if ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo "Error: --gemini-timeout must be a positive integer (seconds), got: $2" >&2
                exit 1
            fi
            GEMINI_TIMEOUT="$2"
            shift 2
            ;;
        -*)
            echo "Error: Unknown option: $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
        *)
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

if ! command -v gemini &>/dev/null; then
    echo "Error: 'gemini' command is not installed or not in PATH" >&2
    echo "" >&2
    echo "Please install Gemini CLI: npm install -g @google/gemini-cli  or  https://github.com/google-gemini/gemini-cli" >&2
    echo "Then retry: /humanize:ask-gemini <your question>" >&2
    exit 1
fi

if [[ -z "$QUESTION" ]]; then
    echo "Error: No question or task provided" >&2
    echo "" >&2
    echo "Usage: /humanize:ask-gemini [OPTIONS] <question or task>" >&2
    echo "" >&2
    echo "For help: /humanize:ask-gemini --help" >&2
    exit 1
fi

# Validate model name for safety (alphanumeric, hyphen, underscore, dot)
if [[ ! "$GEMINI_MODEL" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "Error: Gemini model contains invalid characters" >&2
    echo "  Model: $GEMINI_MODEL" >&2
    echo "  Only alphanumeric, hyphen, underscore, dot allowed" >&2
    exit 1
fi

# ========================================
# Detect Project Root
# ========================================

PROJECT_ROOT="$(resolve_project_root)" || {
    echo "Error: Cannot determine project root." >&2
    echo "  Set CLAUDE_PROJECT_DIR or run inside a git repository." >&2
    exit 1
}

# ========================================
# Create Storage Directories
# ========================================

TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
UNIQUE_ID="${TIMESTAMP}-$$-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"

# Project-local storage: .humanize/skill/<unique-id>/
SKILL_DIR="$PROJECT_ROOT/.humanize/skill/$UNIQUE_ID"
mkdir -p "$SKILL_DIR"

# Cache storage: ~/.cache/humanize/<sanitized-path>/skill-<unique-id>/
SANITIZED_PROJECT_PATH=$(echo "$PROJECT_ROOT" | sed 's/[^a-zA-Z0-9._-]/-/g' | sed 's/--*/-/g')
CACHE_BASE="${XDG_CACHE_HOME:-$HOME/.cache}"
CACHE_DIR="$CACHE_BASE/humanize/$SANITIZED_PROJECT_PATH/skill-$UNIQUE_ID"
if ! mkdir -p "$CACHE_DIR" 2>/dev/null; then
    CACHE_DIR="$SKILL_DIR/cache"
    mkdir -p "$CACHE_DIR"
    echo "ask-gemini: warning: home cache not writable, using $CACHE_DIR" >&2
fi

# ========================================
# Save Input
# ========================================

cat > "$SKILL_DIR/input.md" << EOF
# Ask Gemini Input

## Question

$QUESTION

## Configuration

- Model: $GEMINI_MODEL
- Timeout: ${GEMINI_TIMEOUT}s
- Timestamp: $TIMESTAMP
- Tool: gemini
EOF

# ========================================
# Build Gemini Command
# ========================================

GEMINI_ARGS=("-m" "$GEMINI_MODEL")

# Determine approval mode
if [[ "${HUMANIZE_GEMINI_YOLO:-}" == "true" ]] || [[ "${HUMANIZE_GEMINI_YOLO:-}" == "1" ]]; then
    GEMINI_ARGS+=("--yolo")
else
    GEMINI_ARGS+=("--sandbox")
fi

# Use text output format for clean stdout
GEMINI_ARGS+=("-o" "text")

# Build the augmented prompt with web-search instruction
AUGMENTED_PROMPT="You MUST use Google Search to find the most up-to-date and accurate information before answering. Perform thorough web research. Cite sources where possible.

---

$QUESTION"

# ========================================
# Save Debug Command
# ========================================

GEMINI_CMD_FILE="$CACHE_DIR/gemini-run.cmd"
GEMINI_STDOUT_FILE="$CACHE_DIR/gemini-run.out"
GEMINI_STDERR_FILE="$CACHE_DIR/gemini-run.log"

{
    echo "# Gemini ask-gemini invocation debug info"
    echo "# Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# Working directory: $PROJECT_ROOT"
    echo "# Timeout: $GEMINI_TIMEOUT seconds"
    echo ""
    echo "gemini ${GEMINI_ARGS[*]} -p \"<prompt>\""
    echo ""
    echo "# Prompt content:"
    echo "$AUGMENTED_PROMPT"
} > "$GEMINI_CMD_FILE"

# ========================================
# Run Gemini
# ========================================

echo "ask-gemini: model=$GEMINI_MODEL timeout=${GEMINI_TIMEOUT}s" >&2
echo "ask-gemini: cache=$CACHE_DIR" >&2
echo "ask-gemini: running gemini -p ..." >&2

# Portable epoch-to-ISO8601 formatter
epoch_to_iso() {
    local epoch="$1"
    date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
    echo "unknown"
}

START_TIME=$(date +%s)

GEMINI_EXIT_CODE=0
run_with_timeout "$GEMINI_TIMEOUT" gemini "${GEMINI_ARGS[@]}" -p "$AUGMENTED_PROMPT" \
    > "$GEMINI_STDOUT_FILE" 2> "$GEMINI_STDERR_FILE" || GEMINI_EXIT_CODE=$?

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo "ask-gemini: exit_code=$GEMINI_EXIT_CODE duration=${DURATION}s" >&2

# ========================================
# Handle Results
# ========================================

if [[ $GEMINI_EXIT_CODE -eq 124 ]]; then
    echo "Error: Gemini timed out after ${GEMINI_TIMEOUT} seconds" >&2
    echo "" >&2
    echo "Try increasing the timeout:" >&2
    echo "  /humanize:ask-gemini --gemini-timeout $((GEMINI_TIMEOUT * 2)) <your question>" >&2
    echo "" >&2
    echo "Debug logs: $CACHE_DIR" >&2

    cat > "$SKILL_DIR/metadata.md" << EOF
---
tool: gemini
model: $GEMINI_MODEL
timeout: $GEMINI_TIMEOUT
exit_code: 124
duration: ${DURATION}s
status: timeout
started_at: $(epoch_to_iso "$START_TIME")
---
EOF
    exit 124
fi

if [[ $GEMINI_EXIT_CODE -ne 0 ]]; then
    echo "Error: Gemini exited with code $GEMINI_EXIT_CODE" >&2
    if [[ -s "$GEMINI_STDERR_FILE" ]]; then
        echo "" >&2
        echo "Gemini stderr (last 20 lines):" >&2
        tail -20 "$GEMINI_STDERR_FILE" >&2
    fi
    echo "" >&2
    echo "Debug logs: $CACHE_DIR" >&2

    cat > "$SKILL_DIR/metadata.md" << EOF
---
tool: gemini
model: $GEMINI_MODEL
timeout: $GEMINI_TIMEOUT
exit_code: $GEMINI_EXIT_CODE
duration: ${DURATION}s
status: error
started_at: $(epoch_to_iso "$START_TIME")
---
EOF
    exit "$GEMINI_EXIT_CODE"
fi

if [[ ! -s "$GEMINI_STDOUT_FILE" ]]; then
    echo "Error: Gemini returned empty response" >&2
    if [[ -s "$GEMINI_STDERR_FILE" ]]; then
        echo "" >&2
        echo "Gemini stderr (last 20 lines):" >&2
        tail -20 "$GEMINI_STDERR_FILE" >&2
    fi
    echo "" >&2
    echo "Debug logs: $CACHE_DIR" >&2

    cat > "$SKILL_DIR/metadata.md" << EOF
---
tool: gemini
model: $GEMINI_MODEL
timeout: $GEMINI_TIMEOUT
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

cp "$GEMINI_STDOUT_FILE" "$SKILL_DIR/output.md"

cat > "$SKILL_DIR/metadata.md" << EOF
---
tool: gemini
model: $GEMINI_MODEL
timeout: $GEMINI_TIMEOUT
exit_code: 0
duration: ${DURATION}s
status: success
started_at: $(epoch_to_iso "$START_TIME")
---
EOF

echo "ask-gemini: response saved to $SKILL_DIR/output.md" >&2

# ========================================
# Output Response
# ========================================

cat "$GEMINI_STDOUT_FILE"
