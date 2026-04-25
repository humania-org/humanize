#!/usr/bin/env bash
# validate-refine-plan-io.sh
# Validates input and output paths for the refine-plan command
# Exit codes:
#   0 - Success, all validations passed
#   1 - Input file does not exist
#   2 - Input file is empty
#   3 - Input file has no valid comment blocks or has malformed comment syntax
#   4 - Input file missing required gen-plan sections
#   5 - Output directory does not exist or is not writable, or input directory is not writable for in-place mode
#   6 - QA directory not writable
#   7 - Invalid arguments

set -e

scan_cmt_blocks() {
    local input_file="$1"

    awk '
    function trim(value) {
        sub(/^[[:space:]]+/, "", value)
        sub(/[[:space:]]+$/, "", value)
        return value
    }

    function has_non_ws(value) {
        return value ~ /[^[:space:]]/
    }

    function current_heading() {
        return nearest_heading == "" ? "Preamble" : nearest_heading
    }

    function context_excerpt(line_text, column, excerpt) {
        excerpt = substr(line_text, column)
        excerpt = trim(excerpt)
        if (excerpt == "") {
            excerpt = trim(line_text)
        }
        gsub(/[[:cntrl:]]/, " ", excerpt)
        gsub(/[[:space:]]+/, " ", excerpt)
        if (length(excerpt) > 80) {
            excerpt = substr(excerpt, 1, 77) "..."
        }
        return excerpt
    }

    function emit_error(kind, line_num, column, excerpt, heading) {
        fatal = 1
        fatal_code = 2
        heading = current_heading()

        if (kind == "nested") {
            printf "Comment parse error: nested comment block at line %d, column %d near \"%s\" (context: \"%s\")\n", line_num, column, heading, excerpt > "/dev/stderr"
        } else if (kind == "stray_end") {
            printf "Comment parse error: stray comment end marker at line %d, column %d near \"%s\" (context: \"%s\")\n", line_num, column, heading, excerpt > "/dev/stderr"
        }

        exit fatal_code
    }

    function find_comment_markers(text, start_pos,   markers, i, pos, min_pos, closest_marker, closest_pos) {
        # Initialize markers array
        markers["CMT:"] = "classic_start"
        markers["<cmt>"] = "cmt_tag_start"
        markers["<comment>"] = "comment_tag_start"
        markers["ENDCMT"] = "classic_end"
        markers["</cmt>"] = "cmt_tag_end"
        markers["</comment>"] = "comment_tag_end"
        markers["<!--"] = "html_start"
        markers["-->"] = "html_end"

        closest_marker = ""
        closest_pos = 0
        min_pos = length(text) + 1

        for (marker in markers) {
            pos = index(substr(text, start_pos), marker)
            if (pos > 0) {
                pos = start_pos + pos - 1
                if (pos < min_pos) {
                    min_pos = pos
                    closest_marker = marker
                    closest_pos = pos
                }
            }
        }

        if (closest_marker == "") {
            return ""
        } else {
            return closest_marker "|" closest_pos
        }
    }

    function get_end_marker_for_format(format) {
        if (format == "classic") return "ENDCMT"
        if (format == "cmt_tag") return "</cmt>"
        if (format == "comment_tag") return "</comment>"
        return ""
    }

    function get_marker_length(marker) {
        if (marker == "CMT:") return 4
        if (marker == "<cmt>") return 5
        if (marker == "<comment>") return 9
        if (marker == "ENDCMT") return 6
        if (marker == "</cmt>") return 6
        if (marker == "</comment>") return 10
        if (marker == "<!--") return 4
        if (marker == "-->") return 3
        return 0
    }

    BEGIN {
        count = 0
        in_fence = 0
        in_html = 0
        in_cmt = 0
        fence_marker = ""
        nearest_heading = "Preamble"
        cmt_open_line = 0
        cmt_open_col = 0
        cmt_open_heading = "Preamble"
        cmt_open_excerpt = ""
        cmt_has_text = 0
        cmt_format = ""  # Track format: "classic", "cmt_tag", "comment_tag"
        fatal = 0
        fatal_code = 0
    }

    {
        line = $0

        if (!in_fence && !in_html && !in_cmt && line ~ /^[[:space:]]*#[#]*[[:space:]]+/) {
            nearest_heading = trim(line)
        }

        if (in_fence) {
            if ((fence_marker == "```" && line ~ /^[[:space:]]*```/) || (fence_marker == "~~~" && line ~ /^[[:space:]]*~~~/)) {
                in_fence = 0
                fence_marker = ""
            }
            next
        }

        if (!in_html && !in_cmt) {
            if (line ~ /^[[:space:]]*```/) {
                in_fence = 1
                fence_marker = "```"
                next
            }
            if (line ~ /^[[:space:]]*~~~/) {
                in_fence = 1
                fence_marker = "~~~"
                next
            }
        }

        pos = 1
        line_length = length(line)
        while (pos <= line_length) {
            rest = substr(line, pos)

            if (in_html) {
                close_rel = index(rest, "-->")

                if (in_cmt && has_non_ws(rest)) {
                    cmt_has_text = 1
                }

                if (close_rel > 0) {
                    pos += close_rel + 2
                    in_html = 0
                    continue
                }

                pos = line_length + 1
                break
            }

            if (in_cmt) {
                marker_info = find_comment_markers(line, pos)
                if (marker_info == "") {
                    if (has_non_ws(rest)) {
                        cmt_has_text = 1
                    }
                    pos = line_length + 1
                    break
                }

                split(marker_info, parts, "|")
                found_marker = parts[1]
                marker_pos = parts[2]
                token_rel = marker_pos - pos + 1

                segment = substr(rest, 1, token_rel - 1)
                if (has_non_ws(segment)) {
                    cmt_has_text = 1
                }

                if (found_marker == "<!--") {
                    cmt_has_text = 1
                    in_html = 1
                    pos += token_rel + 3
                    continue
                }

                expected_end = get_end_marker_for_format(cmt_format)
                if (found_marker == expected_end) {
                    # Found correct end marker
                    if (cmt_has_text) {
                        count++
                    }

                    in_cmt = 0
                    cmt_has_text = 0
                    cmt_open_line = 0
                    cmt_open_col = 0
                    cmt_open_heading = "Preamble"
                    cmt_open_excerpt = ""
                    cmt_format = ""
                    pos += token_rel + get_marker_length(found_marker) - 1
                    continue
                }

                # Check for nested comment start
                if (found_marker == "CMT:" || found_marker == "<cmt>" || found_marker == "<comment>") {
                    emit_error("nested", NR, marker_pos, context_excerpt(line, marker_pos))
                }

                # Check for wrong end marker
                if (found_marker == "ENDCMT" || found_marker == "</cmt>" || found_marker == "</comment>") {
                    emit_error("stray_end", NR, marker_pos, context_excerpt(line, marker_pos))
                }

                pos = marker_pos + 1
                continue
            }

            # Not in comment block
            marker_info = find_comment_markers(line, pos)
            if (marker_info == "") {
                break
            }

            split(marker_info, parts, "|")
            found_marker = parts[1]
            marker_pos = parts[2]
            token_rel = marker_pos - pos + 1

            if (found_marker == "<!--") {
                in_html = 1
                pos += token_rel + 3
                continue
            }

            if (found_marker == "CMT:") {
                in_cmt = 1
                cmt_format = "classic"
                cmt_has_text = 0
                cmt_open_line = NR
                cmt_open_col = marker_pos
                cmt_open_heading = current_heading()
                cmt_open_excerpt = context_excerpt(line, marker_pos)
                pos += token_rel + 3
                continue
            }

            if (found_marker == "<cmt>") {
                in_cmt = 1
                cmt_format = "cmt_tag"
                cmt_has_text = 0
                cmt_open_line = NR
                cmt_open_col = marker_pos
                cmt_open_heading = current_heading()
                cmt_open_excerpt = context_excerpt(line, marker_pos)
                pos += token_rel + 4
                continue
            }

            if (found_marker == "<comment>") {
                in_cmt = 1
                cmt_format = "comment_tag"
                cmt_has_text = 0
                cmt_open_line = NR
                cmt_open_col = marker_pos
                cmt_open_heading = current_heading()
                cmt_open_excerpt = context_excerpt(line, marker_pos)
                pos += token_rel + 8
                continue
            }

            # Stray end markers
            if (found_marker == "ENDCMT" || found_marker == "</cmt>" || found_marker == "</comment>") {
                emit_error("stray_end", NR, marker_pos, context_excerpt(line, marker_pos))
            }

            pos = marker_pos + 1
        }
    }

    END {
        if (fatal) {
            exit fatal_code
        }

        if (in_cmt) {
            printf "Comment parse error: missing end marker for block opened at line %d, column %d near \"%s\" (context: \"%s\")\n", cmt_open_line, cmt_open_col, cmt_open_heading, cmt_open_excerpt > "/dev/stderr"
            exit 2
        }

        print count
    }
    ' "$input_file"
}

scan_sections() {
    local input_file="$1"

    awk '
    function trim(value) {
        sub(/^[[:space:]]+/, "", value)
        sub(/[[:space:]]+$/, "", value)
        return value
    }

    BEGIN {
        in_fence = 0
        in_html = 0
        in_cmt = 0
        fence_marker = ""
    }

    {
        line = $0
        visible = ""

        if (in_fence) {
            if ((fence_marker == "```" && line ~ /^[[:space:]]*```/) || (fence_marker == "~~~" && line ~ /^[[:space:]]*~~~/)) {
                in_fence = 0
                fence_marker = ""
            }
            next
        }

        if (!in_html && !in_cmt) {
            if (line ~ /^[[:space:]]*```/) {
                in_fence = 1
                fence_marker = "```"
                next
            }
            if (line ~ /^[[:space:]]*~~~/) {
                in_fence = 1
                fence_marker = "~~~"
                next
            }
        }

        pos = 1
        line_length = length(line)
        while (pos <= line_length) {
            rest = substr(line, pos)

            if (in_html) {
                close_rel = index(rest, "-->")

                if (close_rel > 0) {
                    pos += close_rel + 2
                    in_html = 0
                    continue
                }

                pos = line_length + 1
                break
            }

            if (in_cmt) {
                html_rel = index(rest, "<!--")
                classic_end_rel = index(rest, "ENDCMT")
                cmt_tag_end_rel = index(rest, "</cmt>")
                comment_tag_end_rel = index(rest, "</comment>")
                token_rel = 0
                token_type = ""

                if (html_rel > 0) {
                    token_rel = html_rel
                    token_type = "html"
                }
                if (classic_end_rel > 0 && (token_rel == 0 || classic_end_rel < token_rel)) {
                    token_rel = classic_end_rel
                    token_type = "classic_end"
                }
                if (cmt_tag_end_rel > 0 && (token_rel == 0 || cmt_tag_end_rel < token_rel)) {
                    token_rel = cmt_tag_end_rel
                    token_type = "cmt_tag_end"
                }
                if (comment_tag_end_rel > 0 && (token_rel == 0 || comment_tag_end_rel < token_rel)) {
                    token_rel = comment_tag_end_rel
                    token_type = "comment_tag_end"
                }

                if (token_rel == 0) {
                    pos = line_length + 1
                    break
                }

                if (token_type == "html") {
                    in_html = 1
                    pos += token_rel + 3
                    continue
                }

                in_cmt = 0
                if (token_type == "classic_end") {
                    pos += token_rel + 5
                } else if (token_type == "cmt_tag_end") {
                    pos += token_rel + 5
                } else if (token_type == "comment_tag_end") {
                    pos += token_rel + 9
                }
                continue
            }

            html_rel = index(rest, "<!--")
            classic_start_rel = index(rest, "CMT:")
            cmt_tag_start_rel = index(rest, "<cmt>")
            comment_tag_start_rel = index(rest, "<comment>")
            token_rel = 0
            token_type = ""

            if (html_rel > 0) {
                token_rel = html_rel
                token_type = "html"
            }
            if (classic_start_rel > 0 && (token_rel == 0 || classic_start_rel < token_rel)) {
                token_rel = classic_start_rel
                token_type = "classic_start"
            }
            if (cmt_tag_start_rel > 0 && (token_rel == 0 || cmt_tag_start_rel < token_rel)) {
                token_rel = cmt_tag_start_rel
                token_type = "cmt_tag_start"
            }
            if (comment_tag_start_rel > 0 && (token_rel == 0 || comment_tag_start_rel < token_rel)) {
                token_rel = comment_tag_start_rel
                token_type = "comment_tag_start"
            }

            if (token_rel == 0) {
                visible = visible rest
                break
            }

            visible = visible substr(rest, 1, token_rel - 1)

            if (token_type == "html") {
                in_html = 1
                pos += token_rel + 3
                continue
            }

            in_cmt = 1
            if (token_type == "classic_start") {
                pos += token_rel + 3
            } else if (token_type == "cmt_tag_start") {
                pos += token_rel + 4
            } else if (token_type == "comment_tag_start") {
                pos += token_rel + 8
            }
        }

        visible = trim(visible)
        if (visible ~ /^#[#]*[[:space:]]+/) {
            print visible
        }
    }
    ' "$input_file"
}

usage() {
    echo "Usage: $0 --input <path/to/annotated-plan.md> [--output <path/to/refined-plan.md>] [--qa-dir <path/to/qa-dir>] [--discussion|--direct]"
    echo ""
    echo "Options:"
    echo "  --input   Path to the input annotated plan file (required)"
    echo "  --output  Path to the output refined plan file (optional, defaults to --input for in-place mode)"
    echo "  --qa-dir  Directory for QA document output (optional, defaults to .humanize/plan_qa)"
    echo "  --discussion  Use discussion mode (interactive user confirmation for ambiguous classifications)"
    echo "  --direct      Use direct mode (skip user confirmation, use heuristic classifications)"
    echo "  -h, --help  Show this help message"
    exit 7
}

INPUT_FILE=""
OUTPUT_FILE=""
QA_DIR=".humanize/plan_qa"
REFINE_PLAN_MODE_DISCUSSION="false"
REFINE_PLAN_MODE_DIRECT="false"

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
        --qa-dir)
            if [[ $# -lt 2 || "$2" == --* ]]; then
                echo "ERROR: --qa-dir requires a value"
                usage
            fi
            QA_DIR="$2"
            shift 2
            ;;
        --discussion)
            REFINE_PLAN_MODE_DISCUSSION="true"
            shift
            ;;
        --direct)
            REFINE_PLAN_MODE_DIRECT="true"
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

# Validate mutually exclusive flags
if [[ "$REFINE_PLAN_MODE_DISCUSSION" == "true" && "$REFINE_PLAN_MODE_DIRECT" == "true" ]]; then
    echo "Error: --discussion and --direct are mutually exclusive"
    exit 7
fi

# Validate required arguments
if [[ -z "$INPUT_FILE" ]]; then
    echo "ERROR: --input is required"
    usage
fi

# Default output to input (in-place mode)
if [[ -z "$OUTPUT_FILE" ]]; then
    OUTPUT_FILE="$INPUT_FILE"
fi

# Get absolute paths
INPUT_FILE=$(realpath -m "$INPUT_FILE" 2>/dev/null || echo "$INPUT_FILE")
OUTPUT_FILE=$(realpath -m "$OUTPUT_FILE" 2>/dev/null || echo "$OUTPUT_FILE")
INPUT_DIR=$(dirname "$INPUT_FILE")
OUTPUT_DIR=$(dirname "$OUTPUT_FILE")

echo "=== refine-plan IO Validation ==="
echo "Input file: $INPUT_FILE"
echo "Output file: $OUTPUT_FILE"
echo "Output directory: $OUTPUT_DIR"
echo "QA directory: $QA_DIR"

# Check 1: Input file exists
if [[ ! -f "$INPUT_FILE" ]]; then
    echo "VALIDATION_ERROR: INPUT_NOT_FOUND"
    echo "The input file does not exist: $INPUT_FILE"
    echo "Please ensure the annotated plan file exists before running refine-plan."
    exit 1
fi

# Check 2: Input file is not empty
if [[ ! -s "$INPUT_FILE" ]]; then
    echo "VALIDATION_ERROR: INPUT_EMPTY"
    echo "The input file is empty: $INPUT_FILE"
    echo "Please add content to your annotated plan file before running refine-plan."
    exit 2
fi

# Check 3: Input file has at least one valid, non-empty comment block
CMT_SCAN_OUTPUT=""
if ! CMT_SCAN_OUTPUT=$(scan_cmt_blocks "$INPUT_FILE" 2>&1); then
    echo "VALIDATION_ERROR: INVALID_COMMENT_BLOCKS"
    echo "$CMT_SCAN_OUTPUT"
    echo "Please fix malformed comment blocks before running refine-plan."
    echo "Supported formats: CMT:/ENDCMT, <cmt></cmt>, <comment></comment>"
    exit 3
fi

CMT_BLOCK_COUNT=$(printf '%s' "$CMT_SCAN_OUTPUT" | tr -d '[:space:]')
if [[ "$CMT_BLOCK_COUNT" -eq 0 ]]; then
    echo "VALIDATION_ERROR: NO_COMMENT_BLOCKS"
    echo "The input file has no valid non-empty comment blocks after parsing: $INPUT_FILE"
    echo "Markers inside HTML comments or fenced code are ignored, and empty blocks do not count."
    echo "Supported formats: CMT:/ENDCMT, <cmt></cmt>, <comment></comment>"
    exit 3
fi

# Check 4: Input file has required gen-plan sections
REQUIRED_SECTIONS=(
    "## Goal Description"
    "## Acceptance Criteria"
    "## Path Boundaries"
    "## Feasibility Hints"
    "## Dependencies and Sequence"
    "## Task Breakdown"
    "## Claude-Codex Deliberation"
    "## Pending User Decisions"
    "## Implementation Notes"
)

SCANNED_SECTIONS="$(scan_sections "$INPUT_FILE")"
MISSING_SECTIONS=()
for section in "${REQUIRED_SECTIONS[@]}"; do
    if ! printf '%s\n' "$SCANNED_SECTIONS" | grep -qF -- "$section"; then
        MISSING_SECTIONS+=("$section")
    fi
done

if [[ ${#MISSING_SECTIONS[@]} -gt 0 ]]; then
    echo "VALIDATION_ERROR: MISSING_REQUIRED_SECTIONS"
    echo "The input file is missing required gen-plan sections:"
    for section in "${MISSING_SECTIONS[@]}"; do
        echo "  - $section"
    done
    echo "Please ensure the input file follows the gen-plan schema."
    exit 4
fi

# Check 5: Write target directory is writable
if [[ "$OUTPUT_FILE" != "$INPUT_FILE" ]]; then
    if [[ ! -d "$OUTPUT_DIR" ]]; then
        echo "VALIDATION_ERROR: OUTPUT_DIR_NOT_FOUND"
        echo "The output directory does not exist: $OUTPUT_DIR"
        echo "Please create the directory: mkdir -p $OUTPUT_DIR"
        exit 5
    fi
    if [[ ! -w "$OUTPUT_DIR" ]]; then
        echo "VALIDATION_ERROR: OUTPUT_DIR_NOT_WRITABLE"
        echo "The output directory is not writable: $OUTPUT_DIR"
        echo "Please check permissions: chmod u+w $OUTPUT_DIR"
        exit 5
    fi
else
    if [[ ! -w "$INPUT_DIR" ]]; then
        echo "VALIDATION_ERROR: INPUT_DIR_NOT_WRITABLE"
        echo "The input directory is not writable for in-place refine-plan mode: $INPUT_DIR"
        echo "Please check permissions: chmod u+w $INPUT_DIR"
        exit 5
    fi
fi

# Check 6: QA directory is writable (auto-create if it doesn't exist)
if [[ ! -d "$QA_DIR" ]]; then
    echo "NOTE: QA directory does not exist, will auto-create: $QA_DIR"
    mkdir -p "$QA_DIR" || {
        echo "VALIDATION_ERROR: QA_DIR_NOT_WRITABLE"
        echo "Failed to create QA directory: $QA_DIR"
        echo "Please check permissions."
        exit 6
    }
fi

if [[ ! -w "$QA_DIR" ]]; then
    echo "VALIDATION_ERROR: QA_DIR_NOT_WRITABLE"
    echo "No write permission for the QA directory: $QA_DIR"
    echo "Please check directory permissions."
    exit 6
fi

# All checks passed
INPUT_LINE_COUNT=$(wc -l < "$INPUT_FILE" | tr -d ' ')
echo "VALIDATION_SUCCESS"
echo "Input file: $INPUT_FILE ($INPUT_LINE_COUNT lines, $CMT_BLOCK_COUNT comment blocks)"
echo "Output target: $OUTPUT_FILE"
if [[ "$OUTPUT_FILE" == "$INPUT_FILE" ]]; then
    echo "Mode: in-place (atomic write with temp file)"
else
    echo "Mode: new file"
fi
echo "QA directory: $QA_DIR"
echo "IO validation passed."
exit 0
