#!/bin/bash
# validate-gen-plan-io.sh
# Validates input and output paths for the gen-plan command
# Exit codes:
#   0 - Success, all validations passed
#   1 - Input file does not exist
#   2 - Input file is empty
#   3 - Output directory does not exist
#   4 - Output file already exists
#   5 - No write permission to output directory
#   6 - Invalid arguments
#   7 - Plan template file not found (plugin configuration error)

set -e

usage() {
    echo "Usage: $0 --input <path/to/draft.md> --output <path/to/plan.md> [--auto-start-rlcr-if-converged]"
    echo ""
    echo "Options:"
    echo "  --input   Path to the input draft file (required)"
    echo "  --output  Path to the output plan file (required)"
    echo "  --auto-start-rlcr-if-converged  Enable direct RLCR start after converged planning"
    echo "  -h, --help  Show this help message"
    exit 6
}

INPUT_FILE=""
OUTPUT_FILE=""
AUTO_START_RLCR_IF_CONVERGED="false"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --input)
            if [[ $# -lt 2 || "$2" == --* ]]; then
                echo "ERROR: --input requires a value"
                usage
            fi
            INPUT_FILE="$2"
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
        --auto-start-rlcr-if-converged)
            AUTO_START_RLCR_IF_CONVERGED="true"
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "ERROR: Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required arguments
if [[ -z "$INPUT_FILE" ]]; then
    echo "ERROR: --input is required"
    usage
fi

if [[ -z "$OUTPUT_FILE" ]]; then
    echo "ERROR: --output is required"
    usage
fi

# Get absolute paths
INPUT_FILE=$(realpath -m "$INPUT_FILE" 2>/dev/null || echo "$INPUT_FILE")
OUTPUT_FILE=$(realpath -m "$OUTPUT_FILE" 2>/dev/null || echo "$OUTPUT_FILE")
OUTPUT_DIR=$(dirname "$OUTPUT_FILE")

echo "=== gen-plan IO Validation ==="
echo "Input file: $INPUT_FILE"
echo "Output file: $OUTPUT_FILE"
echo "Output directory: $OUTPUT_DIR"

# Check 1: Input file exists
if [[ ! -f "$INPUT_FILE" ]]; then
    echo "VALIDATION_ERROR: INPUT_NOT_FOUND"
    echo "The input file does not exist: $INPUT_FILE"
    echo "Please ensure the draft file exists before running gen-plan."
    exit 1
fi

# Check 2: Input file is not empty
if [[ ! -s "$INPUT_FILE" ]]; then
    echo "VALIDATION_ERROR: INPUT_EMPTY"
    echo "The input file is empty: $INPUT_FILE"
    echo "Please add content to your draft file before running gen-plan."
    exit 2
fi

# Check 3: Output directory exists
if [[ ! -d "$OUTPUT_DIR" ]]; then
    echo "VALIDATION_ERROR: OUTPUT_DIR_NOT_FOUND"
    echo "The output directory does not exist: $OUTPUT_DIR"
    echo "Please create the directory: mkdir -p $OUTPUT_DIR"
    exit 3
fi

# Check 4: Output path must not exist (must be a new file path)
if [[ -d "$OUTPUT_FILE" ]]; then
    echo "VALIDATION_ERROR: OUTPUT_IS_DIRECTORY"
    echo "The output path is a directory: $OUTPUT_FILE"
    echo "Please specify a file path, not a directory (e.g., $OUTPUT_FILE/plan.md)."
    exit 4
fi

if [[ -e "$OUTPUT_FILE" ]]; then
    echo "VALIDATION_ERROR: OUTPUT_EXISTS"
    echo "The output path already exists: $OUTPUT_FILE"
    echo "Please choose a different output path or remove the existing file."
    exit 4
fi

# Check 5: Write permission to output directory
if [[ ! -w "$OUTPUT_DIR" ]]; then
    echo "VALIDATION_ERROR: NO_WRITE_PERMISSION"
    echo "No write permission for the output directory: $OUTPUT_DIR"
    echo "Please check directory permissions."
    exit 5
fi

# All checks passed
INPUT_LINE_COUNT=$(wc -l < "$INPUT_FILE" | tr -d ' ')
echo "VALIDATION_SUCCESS"
echo "Input file: $INPUT_FILE ($INPUT_LINE_COUNT lines)"
echo "Output target: $OUTPUT_FILE"
echo "IO validation passed."

# Locate template file using CLAUDE_PLUGIN_ROOT (set by Claude Code plugin system)
# Fallback to script-relative path if environment variable not set
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
    TEMPLATE_FILE="$CLAUDE_PLUGIN_ROOT/prompt-template/plan/gen-plan-template.md"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    TEMPLATE_FILE="$SCRIPT_DIR/../prompt-template/plan/gen-plan-template.md"
fi

if [[ ! -f "$TEMPLATE_FILE" ]]; then
    echo "ERROR: Plan template file not found: $TEMPLATE_FILE"
    echo "This is a plugin configuration error. Please reinstall the plugin."
    exit 7
fi

# Copy template to output location
cp "$TEMPLATE_FILE" "$OUTPUT_FILE"

# Append separator and original draft content
echo "" >> "$OUTPUT_FILE"
echo "--- Original Design Draft Start ---" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"
cat "$INPUT_FILE" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"
echo "--- Original Design Draft End ---" >> "$OUTPUT_FILE"

echo "Template and draft combined at: $OUTPUT_FILE"
echo "Proceeding with draft analysis..."
exit 0
