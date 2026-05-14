#!/usr/bin/env bash
# validate-explore-idea-io.sh
# Validates all inputs for the explore-idea command before any dispatch side effects.
#
# Usage: validate-explore-idea-io.sh <input-path> [OPTIONS]
#
# Input:
#   <input-path>  Path to a .directions.json file, or a draft .md file with a companion
#                 .directions.json (resolved as <draft>.directions.json).
#
# Options:
#   --directions <ids>          Comma-separated direction_id or source_index values.
#                               Default: first min(6, total) by display_order.
#   --concurrency <N>           Parallel worker count. Default: 6. Max: 10.
#   --max-worker-iterations <N> Per-worker iteration cap. Default: 2. Max: 3.
#   --worker-timeout-min <N>    Worker timeout in minutes. Default: 60. Max: 60.
#   --codex-timeout-min <N>     Codex call timeout in minutes. Default: 20. Max: 20.
#
# Exit codes:
#   0 - Validation passed; structured output emitted on stdout
#   1 - Missing required input argument
#   2 - Input file not found or unreadable
#   3 - Input path is a .md file but companion .directions.json is missing
#   4 - Input is not .directions.json or .md
#   5 - Directions JSON schema validation failed
#   6 - Invalid arguments (caps exceeded, bad direction selectors, duplicate selectors)
#   7 - Git checkout state invalid (missing BASE_COMMIT or dirty-checkout hard-fail)
#   8 - Run directory already exists (collision)
#   9 - Required template file missing (plugin configuration error)
#
# On success, emits key-value pairs on stdout followed by VALIDATION_SUCCESS:
#   DIRECTIONS_JSON_FILE: <abs-path>
#   DRAFT_PATH: <abs-path or empty>
#   RUN_ID: <idea-slug>-<YYYYMMDD-HHMMSSZ>-<6hex>
#   RUN_SLUG: <idea-slug>
#   RUN_DIR: <abs-path>
#   REPORT_PATH: <abs-path>
#   FINAL_IDEA_PATH: <abs-path>
#   BASE_BRANCH: <branch>
#   BASE_COMMIT: <sha>
#   SELECTED_DIRECTION_IDS: <space-separated list>
#   EFFECTIVE_CONCURRENCY: <N>
#   MAX_WORKER_ITERATIONS: <N>
#   WORKER_TIMEOUT_MIN: <N>
#   CODEX_TIMEOUT_MIN: <N>
#   CODEX_REVIEW_MODEL: gpt-5.5
#   CODEX_REVIEW_EFFORT: xhigh
#   CODEX_REVIEW_MODEL_SPEC: gpt-5.5:xhigh
#   WORKER_PROMPT_TEMPLATE: <abs-path>
#   REPORT_TEMPLATE: <abs-path>
#   FINAL_IDEA_TEMPLATE: <abs-path>
#   VALIDATION_SUCCESS

set -euo pipefail

# ========================================
# Defaults and caps
# ========================================

DEFAULT_DIRECTIONS_COUNT=6
MAX_DIRECTIONS=10
DEFAULT_CONCURRENCY=6
MAX_CONCURRENCY=10
DEFAULT_MAX_WORKER_ITERATIONS=2
MAX_WORKER_ITERATIONS_CAP=3
DEFAULT_WORKER_TIMEOUT_MIN=60
MAX_WORKER_TIMEOUT_MIN=60
DEFAULT_CODEX_TIMEOUT_MIN=20
MAX_CODEX_TIMEOUT_MIN=20

# ========================================
# Parse arguments
# ========================================

usage() {
    cat >&2 << 'USAGE_EOF'
Usage: validate-explore-idea-io.sh <input-path> [OPTIONS]

Input:
  <input-path>  Path to a .directions.json file or a draft .md file with a
                companion .directions.json (auto-resolved).

Options:
  --directions <ids>            Comma-separated direction_id or source_index values
  --concurrency <N>             Workers in parallel (default: 6, max: 10)
  --max-worker-iterations <N>   Iterations per worker (default: 2, max: 3)
  --worker-timeout-min <N>      Worker timeout minutes (default: 60, max: 60)
  --codex-timeout-min <N>       Codex timeout minutes (default: 20, max: 20)
  -h, --help                    Show this message
USAGE_EOF
    exit 6
}

INPUT_PATH=""
DIRECTIONS_FLAG=""
CONCURRENCY="$DEFAULT_CONCURRENCY"
MAX_WORKER_ITERATIONS="$DEFAULT_MAX_WORKER_ITERATIONS"
WORKER_TIMEOUT_MIN="$DEFAULT_WORKER_TIMEOUT_MIN"
CODEX_TIMEOUT_MIN="$DEFAULT_CODEX_TIMEOUT_MIN"

slugify() {
    local raw="$1"
    local slug

    slug="$(
        printf '%s' "$raw" \
            | LC_ALL=C tr '[:upper:]' '[:lower:]' \
            | LC_ALL=C tr -c 'a-z0-9' '-' \
            | sed -e 's/-\{1,\}/-/g' -e 's/^-//' -e 's/-$//'
    )"
    slug="$(printf '%s' "$slug" | cut -c1-48 | sed -e 's/^-//' -e 's/-$//')"

    if [[ -z "$slug" ]]; then
        echo "idea"
    else
        echo "$slug"
    fi
}

random_hex6() {
    local nonce=""

    if [[ -n "${HUMANIZE_EXPLORE_RUN_NONCE:-}" ]]; then
        nonce="$(
            printf '%s' "$HUMANIZE_EXPLORE_RUN_NONCE" \
                | LC_ALL=C tr '[:upper:]' '[:lower:]' \
                | LC_ALL=C tr -cd 'a-f0-9' \
                | cut -c1-6
        )"
    fi

    if [[ ${#nonce} -ne 6 && -r /dev/urandom ]] && command -v od >/dev/null 2>&1; then
        nonce="$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n' | cut -c1-6)"
    fi

    if [[ ${#nonce} -ne 6 ]]; then
        nonce="$(printf '%s' "$$:$RANDOM:$(date -u +%s)" | cksum | awk '{ printf "%06x", $1 % 16777216 }')"
    fi

    echo "$nonce"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --directions)
            [[ $# -lt 2 || "$2" == --* ]] && { echo "ERROR: --directions requires a value" >&2; exit 6; }
            DIRECTIONS_FLAG="$2"; shift 2 ;;
        --concurrency)
            [[ $# -lt 2 || "$2" == --* ]] && { echo "ERROR: --concurrency requires a value" >&2; exit 6; }
            CONCURRENCY="$2"; shift 2 ;;
        --max-worker-iterations)
            [[ $# -lt 2 || "$2" == --* ]] && { echo "ERROR: --max-worker-iterations requires a value" >&2; exit 6; }
            MAX_WORKER_ITERATIONS="$2"; shift 2 ;;
        --worker-timeout-min)
            [[ $# -lt 2 || "$2" == --* ]] && { echo "ERROR: --worker-timeout-min requires a value" >&2; exit 6; }
            WORKER_TIMEOUT_MIN="$2"; shift 2 ;;
        --codex-timeout-min)
            [[ $# -lt 2 || "$2" == --* ]] && { echo "ERROR: --codex-timeout-min requires a value" >&2; exit 6; }
            CODEX_TIMEOUT_MIN="$2"; shift 2 ;;
        -h|--help) usage ;;
        --*)
            echo "ERROR: Unknown option: $1" >&2; exit 6 ;;
        *)
            if [[ -z "$INPUT_PATH" ]]; then
                INPUT_PATH="$1"; shift
            else
                echo "ERROR: Unexpected positional argument: $1" >&2; exit 6
            fi ;;
    esac
done

# ========================================
# Require input
# ========================================

if [[ -z "$INPUT_PATH" ]]; then
    echo "ERROR: input path is required" >&2
    echo "Use --help for usage." >&2
    exit 1
fi

# ========================================
# Numeric cap validation
# ========================================

validate_int_cap() {
    local name="$1" value="$2" max="$3"
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "ERROR: $name must be a positive integer; got: $value" >&2
        exit 6
    fi
    if (( value < 1 || value > max )); then
        echo "ERROR: $name must be between 1 and $max; got: $value" >&2
        exit 6
    fi
}

validate_int_cap "--concurrency" "$CONCURRENCY" "$MAX_CONCURRENCY"
validate_int_cap "--max-worker-iterations" "$MAX_WORKER_ITERATIONS" "$MAX_WORKER_ITERATIONS_CAP"
validate_int_cap "--worker-timeout-min" "$WORKER_TIMEOUT_MIN" "$MAX_WORKER_TIMEOUT_MIN"
validate_int_cap "--codex-timeout-min" "$CODEX_TIMEOUT_MIN" "$MAX_CODEX_TIMEOUT_MIN"

# ========================================
# Resolve directions.json input
# ========================================

DIRECTIONS_JSON_FILE=""
DRAFT_PATH=""

if [[ "$INPUT_PATH" == *.directions.json ]]; then
    # Direct .directions.json path
    if [[ ! -f "$INPUT_PATH" ]]; then
        echo "ERROR: File not found: $INPUT_PATH" >&2
        exit 2
    fi
    DIRECTIONS_JSON_FILE="$(realpath "$INPUT_PATH" 2>/dev/null || echo "$INPUT_PATH")"
elif [[ "$INPUT_PATH" == *.md ]]; then
    # Draft .md path — resolve companion
    if [[ ! -f "$INPUT_PATH" ]]; then
        echo "ERROR: Draft file not found: $INPUT_PATH" >&2
        exit 2
    fi
    DRAFT_PATH="$(realpath "$INPUT_PATH" 2>/dev/null || echo "$INPUT_PATH")"
    COMPANION="${INPUT_PATH%.md}.directions.json"
    if [[ ! -f "$COMPANION" ]]; then
        echo "ERROR: Companion directions.json not found for draft: $INPUT_PATH" >&2
        echo "  Expected companion: $COMPANION" >&2
        echo "  Please regenerate the idea draft with: /humanize:gen-idea <idea>" >&2
        exit 3
    fi
    DIRECTIONS_JSON_FILE="$(realpath "$COMPANION" 2>/dev/null || echo "$COMPANION")"
else
    echo "ERROR: Input must be a .directions.json or .md file; got: $INPUT_PATH" >&2
    exit 4
fi

# ========================================
# Locate plugin scripts and templates
# ========================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
    PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
else
    PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

SCHEMA_VALIDATOR="$PLUGIN_ROOT/scripts/validate-directions-json.sh"
WORKER_PROMPT_TEMPLATE="$PLUGIN_ROOT/prompt-template/explore/worker-prompt.md"
REPORT_TEMPLATE="$PLUGIN_ROOT/prompt-template/explore/report-template.md"
FINAL_IDEA_TEMPLATE="$PLUGIN_ROOT/prompt-template/explore/final-idea-template.md"

if [[ ! -f "$WORKER_PROMPT_TEMPLATE" ]]; then
    echo "ERROR: Worker prompt template missing: $WORKER_PROMPT_TEMPLATE" >&2
    exit 9
fi
if [[ ! -f "$REPORT_TEMPLATE" ]]; then
    echo "ERROR: Report template missing: $REPORT_TEMPLATE" >&2
    exit 9
fi

# ========================================
# Schema validation
# ========================================

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required but not installed" >&2
    exit 5
fi

if ! bash "$SCHEMA_VALIDATOR" "$DIRECTIONS_JSON_FILE" > /dev/null 2>&1; then
    echo "ERROR: Directions JSON schema validation failed: $DIRECTIONS_JSON_FILE" >&2
    echo "  The file does not conform to directions.json schema version 1." >&2
    exit 5
fi

# ========================================
# Load directions from JSON
# ========================================

TOTAL_DIRECTIONS=$(jq '.directions | length' "$DIRECTIONS_JSON_FILE")

# ========================================
# Direction selection
# ========================================

if [[ -z "$DIRECTIONS_FLAG" ]]; then
    # Default: first min(6, total) by display_order
    SELECT_COUNT=$(( TOTAL_DIRECTIONS < DEFAULT_DIRECTIONS_COUNT ? TOTAL_DIRECTIONS : DEFAULT_DIRECTIONS_COUNT ))
    SELECTED_IDS=$(jq -r '
        .directions
        | sort_by(.display_order)
        | .[:'"$SELECT_COUNT"']
        | map(.direction_id)
        | join(" ")
    ' "$DIRECTIONS_JSON_FILE")
else
    # Parse --directions: comma-separated direction_id or source_index values
    IFS=',' read -ra RAW_SELECTORS <<< "$DIRECTIONS_FLAG"

    # Check for duplicates
    DEDUPED=$(printf '%s\n' "${RAW_SELECTORS[@]}" | sort | uniq | wc -l | tr -d ' ')
    if (( DEDUPED != ${#RAW_SELECTORS[@]} )); then
        echo "ERROR: --directions contains duplicate selector values: $DIRECTIONS_FLAG" >&2
        exit 6
    fi

    # Check count cap
    if (( ${#RAW_SELECTORS[@]} > MAX_DIRECTIONS )); then
        echo "ERROR: --directions selects ${#RAW_SELECTORS[@]} directions; max is $MAX_DIRECTIONS" >&2
        exit 6
    fi

    # Resolve each selector to a direction_id
    RESOLVED_IDS=()
    for sel in "${RAW_SELECTORS[@]}"; do
        if [[ "$sel" =~ ^[0-9]+$ ]]; then
            # Numeric source_index
            RESOLVED=$(jq -r --argjson idx "$sel" '
                .directions
                | map(select(.source_index == $idx))
                | first
                | .direction_id // empty
            ' "$DIRECTIONS_JSON_FILE")
        else
            # direction_id string
            RESOLVED=$(jq -r --arg id "$sel" '
                .directions
                | map(select(.direction_id == $id))
                | first
                | .direction_id // empty
            ' "$DIRECTIONS_JSON_FILE")
        fi

        if [[ -z "$RESOLVED" ]]; then
            echo "ERROR: Unknown direction selector: $sel" >&2
            echo "  Valid direction_ids: $(jq -r '.directions | map(.direction_id) | join(", ")' "$DIRECTIONS_JSON_FILE")" >&2
            echo "  Valid source_indexes: $(jq -r '.directions | map(.source_index|tostring) | join(", ")' "$DIRECTIONS_JSON_FILE")" >&2
            exit 6
        fi
        RESOLVED_IDS+=("$RESOLVED")
    done

    # Check for duplicates after resolution (catches mixed selector forms like "1,dir-01-slug")
    RESOLVED_DEDUPED=$(printf '%s\n' "${RESOLVED_IDS[@]}" | sort | uniq | wc -l | tr -d ' ')
    if (( RESOLVED_DEDUPED != ${#RESOLVED_IDS[@]} )); then
        echo "ERROR: --directions resolves to duplicate direction_ids: $DIRECTIONS_FLAG" >&2
        exit 6
    fi

    SELECTED_IDS="${RESOLVED_IDS[*]}"
fi

# Count selected directions
read -ra SELECTED_ARRAY <<< "$SELECTED_IDS"
SELECTED_COUNT="${#SELECTED_ARRAY[@]}"

if (( SELECTED_COUNT > MAX_DIRECTIONS )); then
    echo "ERROR: Selected $SELECTED_COUNT directions; max is $MAX_DIRECTIONS" >&2
    exit 6
fi

# Effective concurrency is min(requested, selected_count)
EFFECTIVE_CONCURRENCY=$(( CONCURRENCY < SELECTED_COUNT ? CONCURRENCY : SELECTED_COUNT ))

# ========================================
# Git checkout/base-anchor checks (hard-fail)
# ========================================
#
# Worker base-anchor contract (enforced by worker-prompt.md):
# Workers are created at BASE_COMMIT in detached HEAD state.
# Do NOT run `git checkout <BASE_BRANCH>` in worker setup because the coordinator
# checkout may already have that branch checked out. Each worker asserts
# HEAD == BASE_COMMIT before creating its explore branch.
# A HEAD mismatch is a fatal worker error.
# Workers MUST run only targeted tests for the files they touched, not the full test suite.

if ! PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    echo "ERROR: Git checkout is required for explore-idea." >&2
    echo "  Workers need a real BASE_COMMIT to create anchored worktrees." >&2
    exit 7
fi

if ! BASE_COMMIT="$(git -C "$PROJECT_ROOT" rev-parse --verify HEAD 2>/dev/null)"; then
    echo "ERROR: Unable to resolve BASE_COMMIT for explore-idea." >&2
    echo "  Commit at least one revision before running explore-idea." >&2
    exit 7
fi

BASE_BRANCH="$(git -C "$PROJECT_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")"

# ========================================
# Dirty checkout check (hard-fail)
# ========================================

DIRTY_FILES="$(git -C "$PROJECT_ROOT" diff --name-only HEAD -- 2>/dev/null || true)"
if [[ -n "$DIRTY_FILES" ]]; then
    echo "ERROR: Main checkout has uncommitted tracked changes." >&2
    echo "  Commit or stash changes before running explore-idea." >&2
    echo "  Dirty files:" >&2
    printf '%s\n' "$DIRTY_FILES" | sed 's/^/    /' >&2
    exit 7
fi

if [[ ! -f "$FINAL_IDEA_TEMPLATE" ]]; then
    echo "ERROR: Final idea template missing: $FINAL_IDEA_TEMPLATE" >&2
    exit 9
fi

# ========================================
# Generate RUN_ID and check collision
# ========================================

RUN_SLUG_SOURCE=""
if [[ -n "$DRAFT_PATH" ]]; then
    RUN_SLUG_SOURCE="$(basename "$DRAFT_PATH" .md)"
fi
if [[ -z "$RUN_SLUG_SOURCE" ]]; then
    METADATA_DRAFT_PATH="$(jq -r 'if (.metadata.draft_path? | type) == "string" then .metadata.draft_path else "" end' "$DIRECTIONS_JSON_FILE")"
    if [[ -n "$METADATA_DRAFT_PATH" ]]; then
        RUN_SLUG_SOURCE="$(basename "$METADATA_DRAFT_PATH" .md)"
    fi
fi
if [[ -z "$RUN_SLUG_SOURCE" ]]; then
    DIRECTIONS_BASENAME="$(basename "$DIRECTIONS_JSON_FILE")"
    RUN_SLUG_SOURCE="${DIRECTIONS_BASENAME%.directions.json}"
fi
if [[ -z "$RUN_SLUG_SOURCE" ]]; then
    RUN_SLUG_SOURCE="$(jq -r 'if (.title | type) == "string" and (.title | length) > 0 then .title else "" end' "$DIRECTIONS_JSON_FILE")"
fi
if [[ -z "$RUN_SLUG_SOURCE" ]]; then
    RUN_SLUG_SOURCE="idea"
fi

RUN_SLUG="$(slugify "$RUN_SLUG_SOURCE")"
RUN_TIMESTAMP="${HUMANIZE_EXPLORE_RUN_TIMESTAMP:-$(date -u +%Y%m%d-%H%M%SZ)}"
RUN_NONCE="$(random_hex6)"
RUN_ID="$RUN_SLUG-$RUN_TIMESTAMP-$RUN_NONCE"
RUN_DIR="$PROJECT_ROOT/.humanize/explore/$RUN_ID"
REPORT_PATH="$RUN_DIR/explore-report.md"
FINAL_IDEA_PATH="$RUN_DIR/final-idea.md"

if [[ -e "$RUN_DIR" ]]; then
    echo "ERROR: Run directory already exists (run id collision): $RUN_DIR" >&2
    echo "  Please retry to generate a fresh random suffix." >&2
    exit 8
fi

CODEX_REVIEW_MODEL="gpt-5.5"
CODEX_REVIEW_EFFORT="xhigh"
CODEX_REVIEW_MODEL_SPEC="$CODEX_REVIEW_MODEL:$CODEX_REVIEW_EFFORT"

# ========================================
# Emit validation output
# ========================================

echo "DIRECTIONS_JSON_FILE: $DIRECTIONS_JSON_FILE"
echo "DRAFT_PATH: $DRAFT_PATH"
echo "RUN_ID: $RUN_ID"
echo "RUN_SLUG: $RUN_SLUG"
echo "RUN_DIR: $RUN_DIR"
echo "REPORT_PATH: $REPORT_PATH"
echo "FINAL_IDEA_PATH: $FINAL_IDEA_PATH"
echo "BASE_BRANCH: $BASE_BRANCH"
echo "BASE_COMMIT: $BASE_COMMIT"
echo "SELECTED_DIRECTION_IDS: $SELECTED_IDS"
echo "EFFECTIVE_CONCURRENCY: $EFFECTIVE_CONCURRENCY"
echo "MAX_WORKER_ITERATIONS: $MAX_WORKER_ITERATIONS"
echo "WORKER_TIMEOUT_MIN: $WORKER_TIMEOUT_MIN"
echo "CODEX_TIMEOUT_MIN: $CODEX_TIMEOUT_MIN"
echo "CODEX_REVIEW_MODEL: $CODEX_REVIEW_MODEL"
echo "CODEX_REVIEW_EFFORT: $CODEX_REVIEW_EFFORT"
echo "CODEX_REVIEW_MODEL_SPEC: $CODEX_REVIEW_MODEL_SPEC"
echo "WORKER_PROMPT_TEMPLATE: $WORKER_PROMPT_TEMPLATE"
echo "REPORT_TEMPLATE: $REPORT_TEMPLATE"
echo "FINAL_IDEA_TEMPLATE: $FINAL_IDEA_TEMPLATE"
echo "VALIDATION_SUCCESS"
exit 0
