#!/usr/bin/env bash
# validate-directions-json.sh
# Validates a directions.json file against the schema version 1 contract.
#
# Usage: validate-directions-json.sh <path/to/file.directions.json>
#
# Exit codes:
#   0 - Validation passed
#   1 - Missing input file argument or file does not exist
#   2 - jq not available
#   3 - Schema validation failed (jq returned false or file is invalid JSON)

set -euo pipefail

usage() {
    echo "Usage: $0 <path/to/file.directions.json>"
    echo ""
    echo "Validates a directions.json file against schema version 1."
    exit 1
}

if [[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
fi

INPUT_FILE="$1"

if [[ ! -f "$INPUT_FILE" ]]; then
    echo "ERROR: File not found: $INPUT_FILE" >&2
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required but not installed" >&2
    exit 2
fi

# Full schema validation using a single jq -e expression.
# Returns false (exit 1) if any rule fails.
if jq -e '
  def is_int:
    if type == "number" then . == floor else false end;
  def non_empty_string:
    if type == "string" then length > 0 else false end;
  def pad2:
    tostring as $s
    | if ($s | length) == 1 then "0" + $s else $s end;

  . as $root
  |
  # schema_version must be 1
  .schema_version == 1

  # required top-level keys must be present and be strings
  and ((.title | type) == "string")
  and ((.original_idea | type) == "string")
  and ((.synthesis_notes | type) == "string")
  and has("metadata")
  and has("directions")

  # directions array: 1..10 elements
  and ((.directions | type) == "array")
  and ((.directions | length) >= 1)
  and ((.directions | length) <= 10)

  # exactly one primary direction, with explicit booleans on every direction
  and (.directions | map(has("is_primary") and ((.is_primary | type) == "boolean")) | all)
  and ((.directions | map(select(.is_primary == true)) | length) == 1)

  # direction_id: present, is a string, unique, safe as a token, and derived from source_index + dir_slug
  and (.directions | map(has("direction_id") and ((.direction_id | type) == "string")) | all)
  and (.directions | map(.direction_id) | all(test("^dir-[0-9]{2}-[a-z0-9-]+$")))
  and ((.directions | map(.direction_id) | unique | length) == (.directions | length))

  # dir_slug: present, is a string, unique, and branch/path safe (lowercase alphanumeric + internal hyphens)
  and (.directions | map(has("dir_slug") and ((.dir_slug | type) == "string")) | all)
  and ((.directions | map(.dir_slug) | unique | length) == (.directions | length))
  and (.directions | map(.dir_slug) | all(. != null and test("^[a-z0-9]+(-[a-z0-9]+)*$")))

  # source_index: present and must be an integer (not a string)
  and (.directions | map(has("source_index") and (.source_index | is_int) and (.source_index >= 0) and (.source_index < $root.metadata.n_requested)) | all)
  and ((.directions | map(.source_index) | unique | length) == (.directions | length))
  and (.directions | map(.direction_id == ("dir-" + (.source_index | pad2) + "-" + .dir_slug)) | all)

  # display_order values must be integers and sequential from 0 through K
  and (.directions | map(has("display_order") and (.display_order | is_int)) | all)
  and ((.directions | map(.display_order) | sort) == [range(0; (.directions | length))])

  # metadata must match the documented gen-idea companion contract
  and (.metadata.n_requested | is_int)
  and (.metadata.n_requested >= 1)
  and (.metadata.n_requested <= 10)
  and (.metadata.n_requested >= (.directions | length))
  and (.metadata.n_returned | is_int)
  and (.metadata.n_returned == (.directions | length))
  and (.metadata.timestamp | non_empty_string)
  and (.metadata.timestamp | test("^[0-9]{8}-[0-9]{6}$"))
  and (.metadata.draft_path | non_empty_string)

  # confidence must be high, medium, or low for each direction
  and (.directions | map(.confidence) | all(. == "high" or . == "medium" or . == "low"))

  # each direction must have all required string fields
  and (.directions | map(
        ((.name | type) == "string")
        and ((.rationale | type) == "string")
        and ((.raw_phase3_response | type) == "string")
        and ((.approach_summary | type) == "string")
        and ((.objective_evidence | type) == "array")
        and ((.known_risks | type) == "array")
        # array items must be strings
        and (.objective_evidence | map(type == "string") | all)
        and (.known_risks | map(type == "string") | all)
      ) | all)
' "$INPUT_FILE" > /dev/null 2>&1; then
    echo "VALIDATION_SUCCESS"
    exit 0
else
    echo "VALIDATION_FAILED: $INPUT_FILE does not conform to directions.json schema version 1" >&2
    exit 3
fi
