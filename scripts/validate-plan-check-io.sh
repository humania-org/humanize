#!/usr/bin/env bash
# validate-plan-check-io.sh
# Validates input and output paths for the plan-check command
# Exit codes:
#   0 - Success, all validations passed
#   1 - Input file does not exist
#   2 - Input file is empty
#   3 - Report directory does not exist and cannot be created
#   4 - Report output path already exists and is not a directory
#   5 - No write permission to output directory
#   6 - Invalid arguments
#
set -e

usage() {
    cat << 'USAGE_EOF'
Usage: validate-plan-check-io.sh --plan <path/to/plan.md> [--recheck] [--alt-language <code>]

Options:
  --plan          Path to the plan file to check (required)
  --recheck       Re-run plan-check after an accepted rewrite
  --alt-language  Language code for translated report variants
  -h, --help      Show this help message
USAGE_EOF
    exit 6
}

PLAN_FILE=""
RECHECK="false"
ALT_LANGUAGE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --plan)
            if [[ $# -lt 2 || "$2" == --* ]]; then
                echo "ERROR: --plan requires a value" >&2
                usage
            fi
            PLAN_FILE="$2"
            shift 2
            ;;
        --recheck)
            RECHECK="true"
            shift
            ;;
        --alt-language)
            if [[ $# -lt 2 || "$2" == --* ]]; then
                echo "ERROR: --alt-language requires a value" >&2
                usage
            fi
            ALT_LANGUAGE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage
            ;;
    esac
done

# Validate required arguments
if [[ -z "$PLAN_FILE" ]]; then
    echo "ERROR: --plan is required" >&2
    usage
fi

# Resolve to absolute path
PLAN_FILE=$(realpath -m "$PLAN_FILE" 2>/dev/null || echo "$PLAN_FILE")
PLAN_DIR=$(dirname "$PLAN_FILE")

# Determine report output directory
if PROJECT_ROOT=$(git -C "$PLAN_DIR" rev-parse --show-toplevel 2>/dev/null); then
    REPORT_DIR="$PROJECT_ROOT/.humanize/plan-check"
else
    REPORT_DIR="$PLAN_DIR/.humanize/plan-check"
fi

echo "=== plan-check IO Validation ==="
echo "Plan file: $PLAN_FILE"
echo "Report directory: $REPORT_DIR"

# Check 1: Input file exists
if [[ ! -f "$PLAN_FILE" ]]; then
    echo "VALIDATION_ERROR: INPUT_NOT_FOUND"
    echo "The plan file does not exist: $PLAN_FILE"
    echo "Please ensure the plan file exists before running plan-check."
    exit 1
fi

# Check 2: Input file is not empty
if [[ ! -s "$PLAN_FILE" ]]; then
    echo "VALIDATION_ERROR: INPUT_EMPTY"
    echo "The plan file is empty: $PLAN_FILE"
    echo "Please add content to your plan file before running plan-check."
    exit 2
fi

# Check 3: Output path must not already exist as a non-directory
if [[ -e "$REPORT_DIR" && ! -d "$REPORT_DIR" ]]; then
    echo "VALIDATION_ERROR: OUTPUT_EXISTS"
    echo "The report output path already exists and is not a directory: $REPORT_DIR"
    echo "Please remove the file or choose a different output path."
    exit 4
fi

# Check 4: Output directory exists or can be created
if [[ ! -d "$REPORT_DIR" ]]; then
    # Try to create it
    if ! mkdir -p "$REPORT_DIR" 2>/dev/null; then
        echo "VALIDATION_ERROR: OUTPUT_DIR_NOT_FOUND"
        echo "The report directory does not exist and cannot be created: $REPORT_DIR"
        echo "Please create the directory or ensure write permission."
        exit 3
    fi
fi

# Check 5: Write permission to output directory
if [[ ! -w "$REPORT_DIR" ]]; then
    echo "VALIDATION_ERROR: NO_WRITE_PERMISSION"
    echo "No write permission for the report directory: $REPORT_DIR"
    echo "Please check directory permissions."
    exit 5
fi

# All checks passed
INPUT_LINE_COUNT=$(wc -l < "$PLAN_FILE" | tr -d ' ')
echo "VALIDATION_SUCCESS"
echo "Plan file: $PLAN_FILE ($INPUT_LINE_COUNT lines)"
echo "Report directory: $REPORT_DIR"
echo "Recheck: $RECHECK"
if [[ -n "$ALT_LANGUAGE" ]]; then
    echo "Alt language: $ALT_LANGUAGE"
fi
echo "IO validation passed."
exit 0
