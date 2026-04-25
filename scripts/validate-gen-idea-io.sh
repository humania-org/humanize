#!/usr/bin/env bash
# validate-gen-idea-io.sh
# Validates input, slug, and output paths for the gen-idea command.
# Exit codes:
#   0 - Success
#   1 - Missing idea input or empty input file
#   2 - Input looks like a path but is not readable, not .md, or does not exist
#   3 - Output parent directory does not exist (user-supplied path only)
#   4 - Output file already exists
#   5 - No write permission to output directory
#   6 - Invalid arguments (including --n out of range)
#   7 - Template file not found (plugin configuration error)

set -e

usage() {
    echo "Usage: $0 <idea-text-or-path> [--n <int>] [--output <path>]"
    echo ""
    echo "Arguments:"
    echo "  <idea-text-or-path>  Inline idea text OR path to an existing .md file (required)"
    echo "  --n                  Number of directions (default: 6; range: 2-10)"
    echo "  --output             Output draft path (default: .humanize/ideas/<slug>-<timestamp>.md)"
    echo "  -h, --help           Show this help message"
    exit 6
}

IDEA_INPUT=""
N=6
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --n)
            if [[ $# -lt 2 || "$2" == --* ]]; then
                echo "ERROR: --n requires a value"
                usage
            fi
            N="$2"
            shift 2
            ;;
        --output)
            if [[ $# -lt 2 || "$2" == --* ]]; then
                echo "ERROR: --output requires a value"
                usage
            fi
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        --*)
            echo "ERROR: Unknown option: $1"
            usage
            ;;
        *)
            if [[ -z "$IDEA_INPUT" ]]; then
                IDEA_INPUT="$1"
                shift
            else
                echo "ERROR: Unexpected positional argument: $1"
                usage
            fi
            ;;
    esac
done

if [[ -z "$IDEA_INPUT" ]]; then
    echo "VALIDATION_ERROR: MISSING_IDEA"
    echo "No idea provided. Pass inline text or a .md file path as the first argument."
    exit 1
fi

if ! [[ "$N" =~ ^[0-9]+$ ]]; then
    echo "VALIDATION_ERROR: INVALID_N"
    echo "--n must be a non-negative integer; got: $N"
    exit 6
fi
if (( N < 2 || N > 10 )); then
    echo "VALIDATION_ERROR: N_OUT_OF_RANGE"
    echo "--n must be between 2 and 10 inclusive; got: $N"
    exit 6
fi

INPUT_MODE=""
IDEA_BODY_FILE=""
SLUG=""

# Detect whether IDEA_INPUT is meant as a file path. The `-f` test below is
# the primary gate; this heuristic only matters when that test fails and we
# must decide whether to emit INPUT_NOT_FOUND (user meant a path) or treat
# the text as inline. Any whitespace disqualifies the input from path mode,
# so inline ideas that happen to mention a filename like "rename README.md"
# or that contain "/" fall through to inline. Limitation: a real path that
# contains whitespace and does not exist is silently treated as inline.
looks_like_path=false
if [[ "$IDEA_INPUT" != *[[:space:]]* ]]; then
    if [[ "$IDEA_INPUT" == *.md || "$IDEA_INPUT" == */* ]]; then
        looks_like_path=true
    fi
fi

if [[ -f "$IDEA_INPUT" ]]; then
    if [[ "$IDEA_INPUT" != *.md ]]; then
        echo "VALIDATION_ERROR: INPUT_NOT_MD"
        echo "File input must have .md extension; got: $IDEA_INPUT"
        exit 2
    fi
    if [[ ! -r "$IDEA_INPUT" ]]; then
        echo "VALIDATION_ERROR: INPUT_NOT_READABLE"
        echo "Input file is not readable: $IDEA_INPUT"
        exit 2
    fi
    if [[ ! -s "$IDEA_INPUT" ]]; then
        echo "VALIDATION_ERROR: INPUT_EMPTY"
        echo "Input file is empty: $IDEA_INPUT"
        exit 1
    fi
    INPUT_MODE="file"
    IDEA_BODY_FILE="$(realpath "$IDEA_INPUT" 2>/dev/null || echo "$IDEA_INPUT")"
    base="$(basename "$IDEA_INPUT")"
    SLUG="${base%.md}"
elif [[ "$looks_like_path" == true ]]; then
    echo "VALIDATION_ERROR: INPUT_NOT_FOUND"
    echo "Looks like a file path but does not exist: $IDEA_INPUT"
    exit 2
else
    # Inline mode emits the idea body on stdout inside a sentinel block,
    # so the caller does not need to consume an on-disk tempfile. This
    # avoids leaking user-provided text under $TMPDIR on repeated runs.
    INPUT_MODE="inline"
    if (( ${#IDEA_INPUT} < 10 )); then
        echo "WARNING: short idea (${#IDEA_INPUT} chars); proceeding"
    fi
    slug_raw="$(printf '%s' "$IDEA_INPUT" | head -c 40 | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]+/-/g' | sed -E 's/-+/-/g' | sed -E 's/^-+//; s/-+$//')"
    if [[ -z "$slug_raw" ]]; then
        slug_raw="idea"
    fi
    SLUG="$slug_raw"
fi

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

DEFAULT_OUTPUT=false
if [[ -z "$OUTPUT_FILE" ]]; then
    TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
    OUTPUT_FILE="$PROJECT_ROOT/.humanize/ideas/${SLUG}-${TIMESTAMP}.md"
    DEFAULT_OUTPUT=true
fi

OUTPUT_FILE="$(realpath -m "$OUTPUT_FILE" 2>/dev/null || echo "$OUTPUT_FILE")"
OUTPUT_DIR="$(dirname "$OUTPUT_FILE")"

if [[ "$DEFAULT_OUTPUT" == true ]]; then
    mkdir -p "$OUTPUT_DIR" 2>/dev/null || true
fi

if [[ ! -d "$OUTPUT_DIR" ]]; then
    echo "VALIDATION_ERROR: OUTPUT_DIR_NOT_FOUND"
    echo "Output directory does not exist: $OUTPUT_DIR"
    exit 3
fi

if [[ -e "$OUTPUT_FILE" ]]; then
    echo "VALIDATION_ERROR: OUTPUT_EXISTS"
    echo "Output already exists: $OUTPUT_FILE"
    exit 4
fi

if [[ ! -w "$OUTPUT_DIR" ]]; then
    echo "VALIDATION_ERROR: NO_WRITE_PERMISSION"
    echo "No write permission: $OUTPUT_DIR"
    exit 5
fi

if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
    TEMPLATE_FILE="$CLAUDE_PLUGIN_ROOT/prompt-template/idea/gen-idea-template.md"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    TEMPLATE_FILE="$SCRIPT_DIR/../prompt-template/idea/gen-idea-template.md"
fi

if [[ ! -f "$TEMPLATE_FILE" ]]; then
    echo "VALIDATION_ERROR: TEMPLATE_NOT_FOUND"
    echo "Template file missing: $TEMPLATE_FILE"
    exit 7
fi

echo "VALIDATION_SUCCESS"
echo "INPUT_MODE: $INPUT_MODE"
if [[ "$INPUT_MODE" == "file" ]]; then
    echo "IDEA_BODY_FILE: $IDEA_BODY_FILE"
fi
echo "OUTPUT_FILE: $OUTPUT_FILE"
echo "SLUG: $SLUG"
echo "TEMPLATE_FILE: $TEMPLATE_FILE"
echo "N: $N"
if [[ "$INPUT_MODE" == "inline" ]]; then
    echo "=== IDEA_BODY_BEGIN ==="
    printf '%s\n' "$IDEA_INPUT"
    echo "=== IDEA_BODY_END ==="
fi
exit 0
