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

set -e

usage() {
    echo "Usage: $0 --input <path/to/draft.md> --output <path/to/plan.md>"
    echo ""
    echo "Options:"
    echo "  --input   Path to the input draft file (required)"
    echo "  --output  Path to the output plan file (required)"
    echo "  -h, --help  Show this help message"
    exit 6
}

INPUT_FILE=""
OUTPUT_FILE=""

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
echo "IO validation passed. Proceeding with draft analysis..."
exit 0
