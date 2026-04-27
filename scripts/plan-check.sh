#!/usr/bin/env bash
# plan-check.sh
# Report assembler and writer for the plan-check command.
# Deterministic only: NO agents, NO LLMs, NO user interaction.
#
# Receives structured findings from the command layer (via stdin or file)
# and assembles/writes report.md and findings.json to the report directory.
#
# Usage:
#   plan-check.sh --plan <path> --report-dir <dir> [--findings-file <path>]
#
# If --findings-file is provided, reads findings from that file.
# Otherwise reads findings JSON array from stdin.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Source shared library
source "$SCRIPT_DIR/lib/plan-check-common.sh"

usage() {
    cat << 'USAGE_EOF'
Usage: plan-check.sh --plan <path/to/plan.md> --report-dir <.report-dir> [--findings-file <path>]

Options:
  --plan          Path to the plan file that was checked (required)
  --report-dir    Directory where report.md and findings.json will be written (required)
  --findings-file Path to a file containing the findings JSON array (optional, defaults to stdin)
  -h, --help      Show this help message
USAGE_EOF
    exit 1
}

PLAN_FILE=""
REPORT_DIR=""
FINDINGS_FILE=""

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
        --report-dir)
            if [[ $# -lt 2 || "$2" == --* ]]; then
                echo "ERROR: --report-dir requires a value" >&2
                usage
            fi
            REPORT_DIR="$2"
            shift 2
            ;;
        --findings-file)
            if [[ $# -lt 2 || "$2" == --* ]]; then
                echo "ERROR: --findings-file requires a value" >&2
                usage
            fi
            FINDINGS_FILE="$2"
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

if [[ -z "$REPORT_DIR" ]]; then
    echo "ERROR: --report-dir is required" >&2
    usage
fi

# Resolve absolute paths
PLAN_FILE="$(realpath -m "$PLAN_FILE" 2>/dev/null || echo "$PLAN_FILE")"
REPORT_DIR="$(realpath -m "$REPORT_DIR" 2>/dev/null || echo "$REPORT_DIR")"

# Ensure report directory exists
if [[ ! -d "$REPORT_DIR" ]]; then
    echo "ERROR: Report directory does not exist: $REPORT_DIR" >&2
    exit 1
fi

# Read findings JSON array
if [[ -n "$FINDINGS_FILE" ]]; then
    if [[ ! -f "$FINDINGS_FILE" ]]; then
        echo "ERROR: Findings file does not exist: $FINDINGS_FILE" >&2
        exit 1
    fi
    FINDINGS_JSON="$(cat "$FINDINGS_FILE")"
else
    FINDINGS_JSON="$(cat)"
fi

# Validate findings JSON with Python: must be an array of valid finding objects.
# Malformed arrays keep valid findings and append a runtime-error diagnostic.
VALIDATED_FINDINGS="$(python3 -c '
import json, sys

raw = sys.stdin.read().strip()
if not raw:
    print("[]")
    sys.exit(0)

try:
    data = json.loads(raw)
except Exception:
    print(json.dumps([{
        "id": "F-RUNTIME-001",
        "severity": "info",
        "category": "runtime-error",
        "source_checker": "plan-schema-validator",
        "location": {"section": "", "fragment": ""},
        "evidence": "Findings input is not valid JSON.",
        "explanation": "The command layer produced malformed findings that could not be parsed. Only the deterministic schema validation results are reliable.",
        "suggested_resolution": "Review the sub-agent output and retry the check.",
        "affected_acs": [],
        "affected_tasks": []
    }]))
    sys.exit(0)

if not isinstance(data, list):
    print(json.dumps([{
        "id": "F-RUNTIME-001",
        "severity": "info",
        "category": "runtime-error",
        "source_checker": "plan-schema-validator",
        "location": {"section": "", "fragment": ""},
        "evidence": "Findings input is not a JSON array.",
        "explanation": "The command layer produced findings in an unexpected format. Expected a JSON array of finding objects.",
        "suggested_resolution": "Review the sub-agent output and retry the check.",
        "affected_acs": [],
        "affected_tasks": []
    }]))
    sys.exit(0)

valid_severities = {"blocker", "warning", "info"}
valid_categories = {"contradiction", "ambiguity", "schema", "dependency", "appendix-drift", "rewrite-risk", "runtime-error", "draft-plan-drift"}
required_fields = {"id", "severity", "category", "source_checker", "location", "evidence", "explanation", "suggested_resolution"}
primary_finding_categories = {"contradiction", "ambiguity"}
valid_checkers = {"plan-consistency-checker", "plan-ambiguity-checker", "plan-schema-validator", "draft-consistency-checker", "draft-ambiguity-checker", "draft-plan-drift-checker"}

def common_validation_error(item):
    if not isinstance(item, dict):
        return "item is not an object"
    missing = required_fields - set(item.keys())
    if missing:
        return "missing required fields: " + ", ".join(sorted(missing))
    if not isinstance(item.get("severity"), str) or item.get("severity") not in valid_severities:
        return "invalid severity"
    if not isinstance(item.get("category"), str) or item.get("category") not in valid_categories:
        return "invalid category"

    string_fields = ["id", "source_checker", "evidence", "explanation", "suggested_resolution"]
    for sf in string_fields:
        if not isinstance(item.get(sf), str):
            return "invalid scalar field: " + sf
    if item.get("source_checker") not in valid_checkers:
        return "unknown source_checker"

    if not isinstance(item.get("affected_acs"), list):
        return "affected_acs is not an array"
    if not all(isinstance(v, str) for v in item.get("affected_acs")):
        return "affected_acs contains a non-string value"
    if not isinstance(item.get("affected_tasks"), list):
        return "affected_tasks is not an array"
    if not all(isinstance(v, str) for v in item.get("affected_tasks")):
        return "affected_tasks contains a non-string value"

    loc = item.get("location")
    if not isinstance(loc, dict):
        return "location is not an object"
    if not isinstance(loc.get("section"), str):
        return "location.section is not a string"
    if not isinstance(loc.get("fragment"), str):
        return "location.fragment is not a string"

    if item.get("category") == "ambiguity":
        details = item.get("ambiguity_details")
        if not isinstance(details, dict):
            return "ambiguity_details is missing or not an object"
        interpretations = details.get("competing_interpretations")
        if not isinstance(interpretations, list):
            return "competing_interpretations is not an array"
        non_empty = [s for s in interpretations if isinstance(s, str) and s.strip()]
        if len(non_empty) < 2:
            return "fewer than 2 non-empty competing interpretations"
        if not isinstance(details.get("execution_drift_risk"), str) or not details.get("execution_drift_risk", "").strip():
            return "empty ambiguity execution_drift_risk"
        if not isinstance(details.get("clarification_question"), str) or not details.get("clarification_question", "").strip():
            return "empty ambiguity clarification_question"

    return None

finding_categories = {}
for item in data:
    if common_validation_error(item) is None and item.get("category") in primary_finding_categories:
        finding_categories[item.get("id")] = item.get("category")

valid_items = []
invalid_items = []
for idx, item in enumerate(data):
    error = common_validation_error(item)
    if error is None and item.get("category") == "draft-plan-drift":
        related_id = item.get("related_finding_id")
        if not isinstance(related_id, str) or not related_id.strip():
            error = "missing draft-plan-drift related_finding_id"
        elif finding_categories.get(related_id) not in primary_finding_categories:
            error = "draft-plan-drift related_finding_id does not reference a valid primary finding"

    if error is None:
        valid_items.append(item)
    else:
        invalid_items.append({"index": idx, "reason": error})

if invalid_items:
    used_ids = {item.get("id") for item in valid_items if isinstance(item.get("id"), str)}
    runtime_number = 1
    while True:
        runtime_id = f"F-RUNTIME-{runtime_number:03d}"
        if runtime_id not in used_ids:
            break
        runtime_number += 1
    invalid_indexes = [entry["index"] for entry in invalid_items]
    invalid_reasons = "; ".join("{}: {}".format(entry["index"], entry["reason"]) for entry in invalid_items)
    runtime_finding = {
        "id": runtime_id,
        "severity": "info",
        "category": "runtime-error",
        "source_checker": "plan-schema-validator",
        "location": {"section": "", "fragment": ""},
        "evidence": f"Findings array contains {len(invalid_items)} invalid item(s) at index(es): {invalid_indexes}.",
        "explanation": "Invalid findings were filtered out while valid findings were preserved. Reasons: " + invalid_reasons,
        "suggested_resolution": "Review the sub-agent output and ensure all findings conform to the full schema.",
        "affected_acs": [],
        "affected_tasks": []
    }
    print(json.dumps(valid_items + [runtime_finding]))
    sys.exit(0)

print(json.dumps(valid_items))
' <<< "$FINDINGS_JSON")"

FINDINGS_JSON="$VALIDATED_FINDINGS"

# Compute plan hash (SHA256)
PLAN_HASH=""
if [[ -f "$PLAN_FILE" ]]; then
    PLAN_HASH="$(sha256sum "$PLAN_FILE" 2>/dev/null | awk '{print $1}')"
fi

# Assemble findings.json
FINDINGS_JSON_OUTPUT="$(plan_check_assemble_findings_json "$PLAN_FILE" "$PLAN_HASH" "plan-schema-validator" "{}" 0 "$FINDINGS_JSON")"

# Validate the assembled output is parseable JSON before writing
if ! python3 -c 'import json,sys; json.load(sys.stdin)' <<< "$FINDINGS_JSON_OUTPUT" 2>/dev/null; then
    echo "ERROR: Assembled findings.json is not valid JSON" >&2
    exit 1
fi

# Write findings.json
printf '%s\n' "$FINDINGS_JSON_OUTPUT" > "$REPORT_DIR/findings.json"

# Assemble report.md
{
    plan_check_format_report_header "$PLAN_FILE"

    # Write findings
    if [[ "$FINDINGS_JSON" == "[]" ]]; then
        echo "No findings detected."
        echo ""
    else
        # Parse each finding and format it
        # We use a simple approach: the findings are already JSON objects in an array
        # We rely on the caller to provide well-formed findings
        echo "## Findings"
        echo ""

        # Count findings by severity for summary via JSON parsing
        severity_counts="$(python3 -c '
import json, sys
try:
    findings = json.loads(sys.argv[1])
    if not isinstance(findings, list):
        findings = []
except Exception:
    findings = []
blockers = sum(1 for f in findings if f.get("severity") == "blocker")
warnings = sum(1 for f in findings if f.get("severity") == "warning")
infos = sum(1 for f in findings if f.get("severity") == "info")
print(f"{blockers} {warnings} {infos}")
' "$FINDINGS_JSON")"
        blockers="$(printf '%s' "$severity_counts" | awk '{print $1}')"
        warnings="$(printf '%s' "$severity_counts" | awk '{print $2}')"
        infos="$(printf '%s' "$severity_counts" | awk '{print $3}')"

        echo "- Blockers: $blockers"
        echo "- Warnings: $warnings"
        echo "- Infos: $infos"
        echo ""

        # For each finding, try to extract key fields and format them
        # Since we're in bash, we do a best-effort extraction using pattern matching
        # The command layer is expected to produce well-formed findings

        # Use a temp file to iterate
        tmp_findings="$(mktemp)"
        printf '%s\n' "$FINDINGS_JSON" > "$tmp_findings"

        # Parse findings using a simple state machine
        # This is best-effort; the command layer should validate the JSON
        python3 -c "
import json, sys

try:
    findings = json.load(open('$tmp_findings'))
except:
    findings = []

for f in findings:
    fid = f.get('id', 'F-???')
    severity = f.get('severity', 'unknown')
    category = f.get('category', 'unknown')
    section = f.get('location', {}).get('section', '')
    fragment = f.get('location', {}).get('fragment', '')
    evidence = f.get('evidence', '')
    explanation = f.get('explanation', '')
    suggested = f.get('suggested_resolution', '')
    related = f.get('related_finding_id', '')

    print(f'### {fid} ({severity})')
    print(f'')
    print(f'- **Category**: {category}')
    if related:
        print(f'- **Related Finding**: {related}')
    print(f'- **Section**: {section}')
    if fragment:
        print(f'- **Fragment**: {fragment}')
    print(f'- **Evidence**: {evidence}')
    print(f'- **Explanation**: {explanation}')
    print(f'- **Suggested Resolution**: {suggested}')
    print(f'')
" 2>/dev/null || {
            # Fallback: just dump the raw JSON
            echo "Raw findings:"
            echo "\`\`\`json"
            cat "$tmp_findings"
            echo "\`\`\`"
        }

        rm -f "$tmp_findings"
    fi

    echo "---"
    echo ""
    echo "*Report generated by plan-schema-validator*"
} > "$REPORT_DIR/report.md"

echo "=== plan-check Report ==="
echo "Plan: $PLAN_FILE"
echo "Report directory: $REPORT_DIR"
echo "Findings written to: $REPORT_DIR/findings.json"
echo "Report written to: $REPORT_DIR/report.md"
exit 0
