#!/usr/bin/env bash
# plan-check-common.sh
# Shared utilities for the plan-check command.
# Deterministic only: NO agents, NO LLMs, NO user interaction.
#
# Provides:
#   - Report directory initialization
#   - findings.json schema v1.0 assembly
#   - Markdown report formatting
#   - Backup and atomic write helpers
#   - Deterministic schema validation (required core sections, AC IDs, optional
#     task tags/dependencies when Task Breakdown is present, appendix drift)
#
set -euo pipefail

# Source guard
[[ -n "${_PLAN_CHECK_COMMON_LOADED:-}" ]] && return 0 2>/dev/null || true
_PLAN_CHECK_COMMON_LOADED=1

# ========================================
# Internal Helpers
# ========================================

_plan_check_warn() {
    echo "Warning: $*" >&2
}

_plan_check_error() {
    echo "Error: $*" >&2
}

_plan_check_json_string() {
    python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "${1:-}"
}

_plan_check_json_array() {
    python3 -c 'import json, sys; print(json.dumps(sys.argv[1:]))' "$@"
}

_plan_check_build_finding() {
    local fid="$1"
    local severity="$2"
    local category="$3"
    local source_checker="$4"
    local section="$5"
    local fragment="$6"
    local evidence="$7"
    local explanation="$8"
    local suggested_resolution="$9"
    local affected_acs_json="${10:-[]}"
    local affected_tasks_json="${11:-[]}"

    python3 - "$fid" "$severity" "$category" "$source_checker" "$section" "$fragment" "$evidence" "$explanation" "$suggested_resolution" "$affected_acs_json" "$affected_tasks_json" <<'PY'
import json
import sys

(
    fid,
    severity,
    category,
    source_checker,
    section,
    fragment,
    evidence,
    explanation,
    suggested_resolution,
    affected_acs_json,
    affected_tasks_json,
) = sys.argv[1:12]

try:
    affected_acs = json.loads(affected_acs_json)
except Exception:
    affected_acs = []
try:
    affected_tasks = json.loads(affected_tasks_json)
except Exception:
    affected_tasks = []
if not isinstance(affected_acs, list):
    affected_acs = []
if not isinstance(affected_tasks, list):
    affected_tasks = []

print(json.dumps({
    "id": fid,
    "severity": severity,
    "category": category,
    "source_checker": source_checker,
    "location": {
        "section": section,
        "fragment": fragment,
    },
    "evidence": evidence,
    "explanation": explanation,
    "suggested_resolution": suggested_resolution,
    "affected_acs": affected_acs,
    "affected_tasks": affected_tasks,
}, separators=(",", ":")))
PY
}

# Global finding ID counter (incremented by _plan_check_next_fid)
_PLAN_CHECK_FID_COUNTER=0
_PLAN_CHECK_LAST_FID=""

# Generate the next finding ID.
# Increments the global counter and stores the result in _PLAN_CHECK_LAST_FID.
# Does NOT use stdout to avoid subshell issues with local+command substitution.
_plan_check_next_fid() {
    _PLAN_CHECK_FID_COUNTER=$((_PLAN_CHECK_FID_COUNTER + 1))
    _PLAN_CHECK_LAST_FID="$(printf 'F-%03d' "$_PLAN_CHECK_FID_COUNTER")"
}

# ========================================
# Report Directory
# ========================================

# Create a timestamped report directory under the given base path.
# Outputs the directory path on stdout.
plan_check_init_report_dir() {
    local base_dir="${1:-}"
    if [[ -z "$base_dir" ]]; then
        _plan_check_error "plan_check_init_report_dir requires a base directory path"
        return 1
    fi
    local ts
    ts="$(date +%Y-%m-%d_%H-%M-%S)"
    local report_dir="$base_dir/$ts"
    mkdir -p "$report_dir/backup"
    printf '%s\n' "$report_dir"
}

# ========================================
# findings.json Assembly (Schema v1.0)
# ========================================
#
# Schema:
# {
#   "version": "1.0",
#   "check_run": { "timestamp": "ISO8601", "plan_path": "...", "plan_hash": "SHA256",
#                  "model": "...", "config": {}, "exit_code": 0 },
#   "findings": [
#     { "id": "F-001", "severity": "blocker|warning|info",
#       "category": "contradiction|ambiguity|schema|dependency|appendix-drift|rewrite-risk|runtime-error",
#       "source_checker": "plan-consistency-checker|plan-ambiguity-checker|plan-schema-validator",
#       "location": { "section": "...", "fragment": "..." },
#       "evidence": "...", "explanation": "...", "suggested_resolution": "...",
#       "affected_acs": ["AC-1"], "affected_tasks": ["task1"] }
#   ],
#   "summary": { "total": 0, "blockers": 0, "warnings": 0, "infos": 0,
#                "status": "pass|fail|needs_clarification" }
# }

plan_check_assemble_findings_json() {
    local plan_path="${1:-}"
    local plan_hash="${2:-}"
    local model="${3:-}"
    local config_json="${4:-}"
    if [[ -z "$config_json" ]]; then
        config_json="{}"
    fi
    local exit_code="${5:-0}"
    local findings_json_array="${6:-[]}"

    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Count severities via JSON parsing to avoid false matches in non-severity fields
    local total blockers warnings infos status
    local severity_counts
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
print(f"{len(findings)} {blockers} {warnings} {infos}")
' "$findings_json_array")"
    total="$(printf '%s' "$severity_counts" | awk '{print $1}')"
    blockers="$(printf '%s' "$severity_counts" | awk '{print $2}')"
    warnings="$(printf '%s' "$severity_counts" | awk '{print $3}')"
    infos="$(printf '%s' "$severity_counts" | awk '{print $4}')"

    if [[ "$blockers" -gt 0 ]]; then
        status="fail"
    else
        status="pass"
    fi

    local timestamp_json plan_path_json plan_hash_json model_json status_json
    timestamp_json="$(_plan_check_json_string "$timestamp")"
    plan_path_json="$(_plan_check_json_string "$plan_path")"
    plan_hash_json="$(_plan_check_json_string "$plan_hash")"
    model_json="$(_plan_check_json_string "$model")"
    status_json="$(_plan_check_json_string "$status")"

    cat << JSON_EOF
{
  "version": "1.0",
  "check_run": {
    "timestamp": $timestamp_json,
    "plan_path": $plan_path_json,
    "plan_hash": $plan_hash_json,
    "model": $model_json,
    "config": $config_json,
    "exit_code": $exit_code
  },
  "findings": $findings_json_array,
  "summary": {
    "total": $total,
    "blockers": $blockers,
    "warnings": $warnings,
    "infos": $infos,
    "status": $status_json
  }
}
JSON_EOF
}

# Build a findings.json object that includes a resolutions array.
# Computes final status from unresolved blockers (original blockers minus resolved/answered).
# Usage: plan_check_build_resolved_json <plan_path> <plan_hash> <model> <config_json> <exit_code> <findings_array> <resolutions_array>
plan_check_build_resolved_json() {
    local plan_path="${1:-}"
    local plan_hash="${2:-}"
    local model="${3:-}"
    local config_json="${4:-}"
    if [[ -z "$config_json" ]]; then
        config_json="{}"
    fi
    local exit_code="${5:-0}"
    local findings_json_array="${6:-[]}"
    local resolutions_json_array="${7:-[]}"

    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    # Use Python for accurate resolution-aware summary computation
    python3 -c '
import json, sys

findings = json.loads(sys.argv[1])
resolutions = json.loads(sys.argv[2])
plan_path = sys.argv[3]
plan_hash = sys.argv[4]
model = sys.argv[5]
config = sys.argv[6]
exit_code = int(sys.argv[7])
timestamp = sys.argv[8]

total = len(findings)
blockers = sum(1 for f in findings if f.get("severity") == "blocker")
warnings = sum(1 for f in findings if f.get("severity") == "warning")
infos = sum(1 for f in findings if f.get("severity") == "info")

# Build map: finding_id -> category
finding_categories = {f.get("id", ""): f.get("category", "") for f in findings}

# Determine which blocker findings are resolved or answered.
# Category-aware: only contradiction findings can be cleared by contradiction_resolution,
# and only ambiguity findings by ambiguity_answer. Schema/dependency/rewrite-risk/runtime-error
# blockers remain unresolved regardless of resolution records.
valid_resolutions = {
    ("contradiction", "contradiction_resolution"),
    ("ambiguity", "ambiguity_answer"),
    ("draft-plan-drift", "drift_resolution"),
}
resolved_ids = set()
for r in resolutions:
    rid = r.get("finding_id", "")
    rtype = r.get("resolution_type", "")
    fcat = finding_categories.get(rid, "")
    if rid and (fcat, rtype) in valid_resolutions:
        resolved_ids.add(rid)

unresolved_blockers = sum(
    1 for f in findings
    if f.get("severity") == "blocker" and f.get("id", "") not in resolved_ids
)

status = "pass" if unresolved_blockers == 0 else "fail"

# Annotate each finding with its resolution state
for f in findings:
    fid = f.get("id", "")
    f["resolution_state"] = "resolved" if fid in resolved_ids else "unresolved"

output = {
    "version": "1.0",
    "check_run": {
        "timestamp": timestamp,
        "plan_path": plan_path,
        "plan_hash": plan_hash,
        "model": model,
        "config": json.loads(config),
        "exit_code": exit_code
    },
    "findings": findings,
    "resolutions": resolutions,
    "summary": {
        "total": total,
        "blockers": blockers,
        "warnings": warnings,
        "infos": infos,
        "unresolved_blockers": unresolved_blockers,
        "status": status
    }
}

print(json.dumps(output, indent=2))
' "$findings_json_array" "$resolutions_json_array" "$plan_path" "$plan_hash" "$model" "$config_json" "$exit_code" "$timestamp"
}

# ========================================
# Markdown Report Formatting
# ========================================

plan_check_format_report_header() {
    local plan_path="$1"
    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cat << MD_EOF
# Plan Check Report

- **Plan**: \`$plan_path\`
- **Timestamp**: $timestamp
- **Checker**: plan-schema-validator

MD_EOF
}

plan_check_format_finding_md() {
    local id="$1"
    local severity="$2"
    local category="$3"
    local section="$4"
    local fragment="$5"
    local evidence="$6"
    local explanation="$7"
    local suggested_resolution="$8"

    cat << MD_EOF
## $id ($severity)

- **Category**: $category
- **Section**: $section
- **Fragment**: $fragment
- **Evidence**: $evidence
- **Explanation**: $explanation
- **Suggested Resolution**: $suggested_resolution

MD_EOF
}

plan_check_format_resolution_report() {
    local plan_path="$1"
    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cat << MD_EOF
# Plan Check Resolution Report

- **Plan**: \`$plan_path\`
- **Timestamp**: $timestamp
- **Status**: All blockers resolved

MD_EOF
}

# ========================================
# Backup and Atomic Write
# ========================================

# Create a backup of the plan file in the report directory.
plan_check_backup_plan() {
    local plan_path="$1"
    local report_dir="$2"
    if [[ ! -f "$plan_path" ]]; then
        _plan_check_error "Cannot backup missing file: $plan_path"
        return 1
    fi
    mkdir -p "$report_dir/backup"
    local backup_path="$report_dir/backup/$(basename "$plan_path").bak"
    cp "$plan_path" "$backup_path"
    printf '%s\n' "$backup_path"
}

# Atomically write content to a file using a temp file in the same directory.
plan_check_atomic_write() {
    local target_path="$1"
    local content="$2"
    local target_dir
    target_dir="$(dirname "$target_path")"
    local tmpfile
    tmpfile="$(mktemp "$target_dir/.plan-check-write.XXXXXX")"
    if ! printf '%s\n' "$content" > "$tmpfile"; then
        rm -f "$tmpfile"
        return 1
    fi

    if [[ -e "$target_path" ]]; then
        if chmod --reference="$target_path" "$tmpfile" 2>/dev/null; then
            :
        else
            local target_mode
            target_mode="$(stat -c '%a' "$target_path" 2>/dev/null || stat -f '%Lp' "$target_path" 2>/dev/null || true)"
            if [[ -n "$target_mode" ]]; then
                chmod "$target_mode" "$tmpfile" 2>/dev/null || true
            fi
        fi
        chown --reference="$target_path" "$tmpfile" 2>/dev/null || true
    fi

    if ! mv "$tmpfile" "$target_path"; then
        rm -f "$tmpfile"
        return 1
    fi
}

# ========================================
# Schema Template Parsing
# ========================================

# Parse the canonical schema template and extract required core sections.
# Outputs one section name per line on stdout.
# Returns non-zero if the template is malformed (missing required markers).
_plan_check_parse_schema_template() {
    local template_path="$1"
    local required_markers=("Goal Description" "Acceptance Criteria" "Path Boundaries")
    local found_markers=()

    # Extract ## headings from the template
    local sections
    sections="$(sed -n -E 's/^##[[:space:]]+(.+)$/\1/p' "$template_path")"

    # Check for required markers
    for marker in "${required_markers[@]}"; do
        if printf '%s\n' "$sections" | grep -qF "$marker"; then
            found_markers+=("$marker")
        fi
    done

    # All required markers must be present; any missing heading means the template is malformed
    if [[ ${#found_markers[@]} -ne ${#required_markers[@]} ]]; then
        return 1
    fi

    printf '%s\n' "${found_markers[@]}"
    return 0
}

# Normalize a Target AC cell by extracting AC-N or AC-N.M tokens and expanding ranges.
# Outputs one AC ID per line on stdout.
_plan_check_normalize_target_acs() {
    local target_ac="$1"

    # Strip markdown bold
    target_ac="$(printf '%s' "$target_ac" | sed 's/\*\*//g')"

    # Replace commas with newlines for uniform processing
    target_ac="$(printf '%s' "$target_ac" | tr ',' '\n')"

    # Process each token
    while IFS= read -r token; do
        # Trim whitespace
        token="$(printf '%s' "$token" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -z "$token" || "$token" == "-" ]] && continue

        # Check for range pattern: "AC-N through AC-M"
        local start_ac end_ac
        if [[ "$token" =~ AC-([0-9]+)[[:space:]]+through[[:space:]]+AC-([0-9]+) ]]; then
            start_ac="${BASH_REMATCH[1]}"
            end_ac="${BASH_REMATCH[2]}"
            local i
            for ((i = start_ac; i <= end_ac; i++)); do
                printf 'AC-%d\n' "$i"
            done
        elif [[ "$token" =~ ^AC-[0-9]+(\.[0-9]+)?$ ]]; then
            printf '%s\n' "$token"
        fi
    done <<< "$target_ac"
}

# Extract defined AC IDs from the Acceptance Criteria section of a main plan body.
# Accepts bullet definitions such as `- AC-1:` / `- **AC-1**:` and sub-criteria
# such as `- AC-1.1:`. Mentions outside this section are intentionally ignored.
_plan_check_extract_defined_ac_ids() {
    local main_body="$1"

    printf '%s\n' "$main_body" \
        | awk '
            /^##[[:space:]]+Acceptance Criteria[[:space:]]*$/ { in_ac=1; next }
            in_ac && /^##[[:space:]]+/ { exit }
            in_ac { print }
        ' \
        | sed -n -E 's/^[[:space:]]*-[[:space:]]+(\*\*)?(AC-[0-9]+(\.[0-9]+)?)(\*\*)?[[:space:]]*:.*/\2/p'
}

_plan_check_is_table_separator() {
    local line="${1:-}"
    [[ "$line" == *"|"* ]] || return 1

    local cells=()
    IFS='|' read -r -a cells <<< "$line"

    local saw_cell=0
    local cell
    local trimmed
    for cell in "${cells[@]}"; do
        trimmed="$(printf '%s' "$cell" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -z "$trimmed" ]] && continue
        if [[ ! "$trimmed" =~ ^:?-{3,}:?$ ]]; then
            return 1
        fi
        saw_cell=1
    done

    [[ "$saw_cell" -eq 1 ]]
}

# Post-process ambiguity findings to assign/verify content-addressable stable IDs.
# Reads findings JSON array from stdin, outputs corrected JSON array on stdout.
plan_check_postprocess_ambiguity_ids() {
    python3 -c '
import json, hashlib, sys

raw = sys.stdin.read()
try:
    findings = json.loads(raw)
except Exception:
    sys.stdout.write(raw)
    sys.exit(0)

for f in findings:
    if f.get("category") == "ambiguity":
        section = f.get("location", {}).get("section", "")
        fragment = f.get("location", {}).get("fragment", "")
        normalized = (section + "\n" + fragment).strip()
        h = hashlib.sha256(normalized.encode("utf-8")).hexdigest()[:12]
        f["id"] = "A-" + h

json.dump(findings, sys.stdout, indent=2)
' 2>/dev/null || cat
}

# ========================================
# Deterministic Schema Validation
# ========================================

# Required core sections for a plan file (default fallback if template parsing fails).
# Task Breakdown is intentionally optional: Codex-generated gen-plan output may
# omit it, while Claude-generated plans can still include and validate it.
_PLAN_CHECK_REQUIRED_SECTIONS=(
    "Goal Description"
    "Acceptance Criteria"
    "Path Boundaries"
)

# Check if a section header exists in the plan file.
_plan_check_has_section() {
    local plan_path="$1"
    local section="$2"
    grep -qF "## $section" "$plan_path" 2>/dev/null
}

# Extract only the main plan body (before the original draft appendix).
_plan_check_extract_main_body() {
    local plan_path="$1"
    if grep -qF -- "--- Original Design Draft Start ---" "$plan_path" 2>/dev/null; then
        sed '/^--- Original Design Draft Start ---$/,$d' "$plan_path"
    else
        cat "$plan_path"
    fi
}

# Extract only the appendix content between the draft markers.
# Returns the inner byte range: content after "--- Original Design Draft Start ---\n"
# and before "\n--- Original Design Draft End ---".
# If markers are missing, returns empty string with a non-fatal info log.
_plan_check_extract_appendix() {
    local plan_path="$1"
    python3 -c '
import sys
path = sys.argv[1]
start_marker = b"--- Original Design Draft Start ---\n"
end_marker = b"\n--- Original Design Draft End ---"
try:
    content = open(path, "rb").read()
except Exception:
    sys.stderr.write("Info: could not read plan file\n")
    sys.exit(0)
s = content.find(start_marker)
e = content.find(end_marker)
if s == -1 or e == -1 or e < s:
    sys.stderr.write("Info: draft appendix markers not found in " + path + "\n")
    sys.exit(0)
inner = content[s + len(start_marker):e]
sys.stdout.buffer.write(inner)
' "$plan_path"
}

# Append a single finding JSON object to the findings file.
_plan_check_append_finding() {
    local findings_file="$1"
    local finding="$2"
    printf '%s\n' "$finding" >> "$findings_file"
}

# Validate that all required sections are present in the main plan body.
# Usage: plan_check_validate_required_sections <plan_path> <findings_file> [section1 section2 ...]
# If no sections are provided after findings_file, uses _PLAN_CHECK_REQUIRED_SECTIONS.
plan_check_validate_required_sections() {
    local plan_path="$1"
    local findings_file="$2"
    shift 2

    local sections_to_check=("$@")
    if [[ ${#sections_to_check[@]} -eq 0 ]]; then
        sections_to_check=("${_PLAN_CHECK_REQUIRED_SECTIONS[@]}")
    fi

    # Extract main body to temp file for reliable repeated scanning
    local main_body_file
    main_body_file="$(mktemp)"
    _plan_check_extract_main_body "$plan_path" > "$main_body_file"

    for section in "${sections_to_check[@]}"; do
        if ! grep -qF "## $section" "$main_body_file" 2>/dev/null; then
            _plan_check_next_fid
            local fid="$_PLAN_CHECK_LAST_FID"
            local finding
            finding="$(_plan_check_build_finding \
                "$fid" "blocker" "schema" "plan-schema-validator" \
                "$section" "" \
                "Required section '$section' is missing from the main plan body." \
                "The canonical plan template requires this section in the main plan body (before the appendix). Appendix sections do not satisfy this requirement." \
                "Add the '$section' section to the main plan body." \
                "[]" "[]")"
            _plan_check_append_finding "$findings_file" "$finding"
        fi
    done

    rm -f "$main_body_file"
}

# Extract all defined AC IDs from the Acceptance Criteria section and detect duplicates.
# Supports canonical `- AC-N:` / `- AC-N.M:` syntax and bold `- **AC-N**:` / `- **AC-N.M**:` syntax.
# Usage: plan_check_validate_ac_ids <plan_path> <findings_file>
plan_check_validate_ac_ids() {
    local plan_path="$1"
    local findings_file="$2"

    # Only check definitions in the main plan body's Acceptance Criteria section,
    # excluding the appendix and incidental AC mentions in other sections.
    local main_body
    main_body="$(_plan_check_extract_main_body "$plan_path")"

    local ac_ids
    ac_ids="$(_plan_check_extract_defined_ac_ids "$main_body" | sort)"

    if [[ -z "$ac_ids" ]]; then
        return 0
    fi

    # Find duplicates
    local duplicates
    duplicates="$(printf '%s\n' "$ac_ids" | uniq -d)"

    while IFS= read -r dup; do
        [[ -z "$dup" ]] && continue
        local count
        count="$(printf '%s\n' "$ac_ids" | grep -Fxc "$dup")"
        _plan_check_next_fid
        local fid="$_PLAN_CHECK_LAST_FID"
        local finding
        finding="$(_plan_check_build_finding \
            "$fid" "blocker" "schema" "plan-schema-validator" \
            "Acceptance Criteria" "$dup" \
            "AC ID '$dup' appears $count times in the main plan body." \
            "Duplicate acceptance criterion IDs create ambiguity about which criteria tasks must satisfy." \
            "Rename duplicate AC IDs so each is unique." \
            "[]" "[]")"
        _plan_check_append_finding "$findings_file" "$finding"
    done <<< "$duplicates"
}

# Validate that each task's Target AC references an existing AC ID.
# Usage: plan_check_validate_target_acs <plan_path> <findings_file>
plan_check_validate_target_acs() {
    local plan_path="$1"
    local findings_file="$2"

    # Extract only AC IDs defined in the Acceptance Criteria section. Incidental
    # bold mentions elsewhere must not satisfy task Target AC validation.
    local main_body
    main_body="$(_plan_check_extract_main_body "$plan_path")"

    local ac_ids
    ac_ids="$(_plan_check_extract_defined_ac_ids "$main_body" | sort -u)"

    # Extract task rows and their Target AC
    local in_task_section=0
    local in_table=0

    while IFS= read -r line; do
        if [[ "$line" =~ ^##+[[:space:]]+Task[[:space:]]+Breakdown ]]; then
            in_task_section=1
            continue
        fi
        if [[ "$in_task_section" -eq 1 && "$line" =~ ^##[[:space:]] && ! "$line" =~ ^### ]]; then
            break
        fi
        if [[ "$in_task_section" -eq 1 ]] && _plan_check_is_table_separator "$line"; then
            in_table=1
            continue
        fi
        if [[ "$in_task_section" -eq 1 && "$line" =~ Task[[:space:]]+ID ]]; then
            continue
        fi
        if [[ "$in_task_section" -eq 1 && "$in_table" -eq 1 && "$line" =~ ^\| ]]; then
            local cols
            cols="$(printf '%s' "$line" | tr '|' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            local col_array=()
            while IFS= read -r col; do
                [[ -z "$col" ]] && continue
                col_array+=("$col")
            done <<< "$cols"

            # Expected columns: Task ID, Description, Target AC, Tag, Depends On
            if [[ ${#col_array[@]} -lt 3 ]]; then
                continue
            fi

            local tid="${col_array[0]}"
            local target_ac="${col_array[2]}"

            # Normalize target AC using range expansion
            local normalized_acs
            normalized_acs="$(_plan_check_normalize_target_acs "$target_ac")"
            if [[ -z "$normalized_acs" ]]; then
                _plan_check_next_fid
                local fid="$_PLAN_CHECK_LAST_FID"
                local finding
                finding="$(_plan_check_build_finding \
                    "$fid" "blocker" "dependency" "plan-schema-validator" \
                    "Task Breakdown" "$tid" \
                    "Task '$tid' has no parsable Target AC value: '$target_ac'." \
                    "Every task must reference one or more acceptance criteria that exist in the main plan body." \
                    "Set the Target AC for task '$tid' to one or more existing AC IDs." \
                    "[]" "$(_plan_check_json_array "$tid")")"
                _plan_check_append_finding "$findings_file" "$finding"
                continue
            fi

            while IFS= read -r single_ac; do
                [[ -z "$single_ac" ]] && continue

                # Check if this AC exists
                local found=0
                local ac
                while IFS= read -r ac; do
                    [[ "$ac" == "$single_ac" ]] && found=1
                done <<< "$ac_ids"

                if [[ "$found" -eq 0 ]]; then
                    _plan_check_next_fid
                    local fid="$_PLAN_CHECK_LAST_FID"
                    local finding
                    finding="$(_plan_check_build_finding \
                        "$fid" "blocker" "dependency" "plan-schema-validator" \
                        "Task Breakdown" "$tid" \
                        "Task '$tid' targets nonexistent AC '$single_ac'." \
                        "Every task must reference an acceptance criterion that exists in the main plan body." \
                        "Create AC '$single_ac' in the Acceptance Criteria section or change the target of task '$tid'." \
                        "[]" "$(_plan_check_json_array "$tid")")"
                    _plan_check_append_finding "$findings_file" "$finding"
                fi
            done <<< "$normalized_acs"
        fi
    done <<< "$main_body"
}

# Validate task tags in the Task Breakdown table.
# Usage: plan_check_validate_task_tags <plan_path> <findings_file>
plan_check_validate_task_tags() {
    local plan_path="$1"
    local findings_file="$2"
    local main_body
    main_body="$(_plan_check_extract_main_body "$plan_path")"

    # Find the Task Breakdown section and extract table rows
    local in_task_section=0
    local in_table=0
    local task_rows=()

    while IFS= read -r line; do
        # Detect Task Breakdown section
        if [[ "$line" =~ ^##+[[:space:]]+Task[[:space:]]+Breakdown ]]; then
            in_task_section=1
            continue
        fi
        # Stop at next ## section (but not ### subsections within Task Breakdown)
        if [[ "$in_task_section" -eq 1 && "$line" =~ ^##[[:space:]] && ! "$line" =~ ^### ]]; then
            break
        fi
        # Detect table separator row
        if [[ "$in_task_section" -eq 1 ]] && _plan_check_is_table_separator "$line"; then
            in_table=1
            continue
        fi
        # Skip header row (contains "Task ID")
        if [[ "$in_task_section" -eq 1 && "$line" =~ Task[[:space:]]+ID ]]; then
            continue
        fi
        # Collect table rows
        if [[ "$in_task_section" -eq 1 && "$in_table" -eq 1 && "$line" =~ ^\| ]]; then
            task_rows+=("$line")
        fi
    done <<< "$main_body"

    # Parse each row
    for row in "${task_rows[@]}"; do
        # Split by | and trim whitespace
        local cols
        cols="$(printf '%s' "$row" | tr '|' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        local col_array=()
        while IFS= read -r col; do
            [[ -z "$col" ]] && continue
            col_array+=("$col")
        done <<< "$cols"

        # Expected columns: Task ID, Description, Target AC, Tag, Depends On
        if [[ ${#col_array[@]} -lt 4 ]]; then
            continue
        fi

        local tid="${col_array[0]}"
        local tag="${col_array[3]}"

        # Strip markdown formatting from tag
        tag="${tag//\`/}"
        tag="${tag// /}"

        if [[ "$tag" != "coding" && "$tag" != "analyze" ]]; then
            _plan_check_next_fid
            local fid="$_PLAN_CHECK_LAST_FID"
            local finding
            finding="$(_plan_check_build_finding \
                "$fid" "blocker" "schema" "plan-schema-validator" \
                "Task Breakdown" "$tid" \
                "Task '$tid' has invalid routing tag: '$tag'." \
                "Each task must carry exactly one routing tag: either 'coding' (implemented by Claude) or 'analyze' (executed via Codex)." \
                "Set the tag to 'coding' or 'analyze' for task '$tid'." \
                "[]" "$(_plan_check_json_array "$tid")")"
            _plan_check_append_finding "$findings_file" "$finding"
        fi
    done
}

# Validate task dependencies: orphaned references and circular dependencies.
# Usage: plan_check_validate_dependencies <plan_path> <findings_file>
plan_check_validate_dependencies() {
    local plan_path="$1"
    local findings_file="$2"
    local main_body
    main_body="$(_plan_check_extract_main_body "$plan_path")"

    # Extract all task IDs and their dependencies from the Task Breakdown table
    local in_task_section=0
    local in_table=0
    declare -A task_deps
    declare -A all_tasks

    while IFS= read -r line; do
        if [[ "$line" =~ ^##+[[:space:]]+Task[[:space:]]+Breakdown ]]; then
            in_task_section=1
            continue
        fi
        if [[ "$in_task_section" -eq 1 && "$line" =~ ^##[[:space:]] && ! "$line" =~ ^### ]]; then
            break
        fi
        if [[ "$in_task_section" -eq 1 ]] && _plan_check_is_table_separator "$line"; then
            in_table=1
            continue
        fi
        if [[ "$in_task_section" -eq 1 && "$line" =~ Task[[:space:]]+ID ]]; then
            continue
        fi
        if [[ "$in_task_section" -eq 1 && "$in_table" -eq 1 && "$line" =~ ^\| ]]; then
            local cols
            cols="$(printf '%s' "$line" | tr '|' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            local col_array=()
            while IFS= read -r col; do
                [[ -z "$col" ]] && continue
                col_array+=("$col")
            done <<< "$cols"

            if [[ ${#col_array[@]} -lt 5 ]]; then
                continue
            fi

            local tid="${col_array[0]}"
            local deps="${col_array[4]}"

            all_tasks["$tid"]=1
            task_deps["$tid"]="$deps"
        fi
    done <<< "$main_body"

    # Check for orphaned dependencies
    for tid in "${!task_deps[@]}"; do
        local deps="${task_deps[$tid]}"
        # Skip if deps is "-" or empty
        [[ "$deps" == "-" || -z "$deps" ]] && continue

        # Split deps by comma
        local dep_array=()
        IFS=',' read -ra dep_array <<< "$deps"
        for dep in "${dep_array[@]}"; do
            dep="$(printf '%s' "$dep" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            [[ -z "$dep" ]] && continue
            if [[ -z "${all_tasks[$dep]:-}" ]]; then
                _plan_check_next_fid
                local fid="$_PLAN_CHECK_LAST_FID"
                local finding
                finding="$(_plan_check_build_finding \
                    "$fid" "blocker" "dependency" "plan-schema-validator" \
                    "Task Breakdown" "$tid" \
                    "Task '$tid' depends on nonexistent task '$dep'." \
                    "Every task dependency must reference a task ID that exists in the Task Breakdown table." \
                    "Create task '$dep' or remove the dependency from '$tid'." \
                    "[]" "$(_plan_check_json_array "$tid")")"
                _plan_check_append_finding "$findings_file" "$finding"
            fi
        done
    done

    # Check for circular dependencies using DFS
    local visited=()
    local rec_stack=()

    _plan_check_has_cycle() {
        local node="$1"
        visited+=("$node")
        rec_stack+=("$node")

        local deps="${task_deps[$node]:-}"
        if [[ "$deps" != "-" && -n "$deps" ]]; then
            local dep_array=()
            IFS=',' read -ra dep_array <<< "$deps"
            for dep in "${dep_array[@]}"; do
                dep="$(printf '%s' "$dep" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                [[ -z "$dep" ]] && continue

                local in_visited=0
                for v in "${visited[@]}"; do
                    if [[ "$v" == "$dep" ]]; then
                        in_visited=1
                        break
                    fi
                done

                local in_rec=0
                for r in "${rec_stack[@]}"; do
                    if [[ "$r" == "$dep" ]]; then
                        in_rec=1
                        break
                    fi
                done

                if [[ "$in_visited" -eq 0 ]]; then
                    if _plan_check_has_cycle "$dep"; then
                        return 0
                    fi
                elif [[ "$in_rec" -eq 1 ]]; then
                    return 0
                fi
            done
        fi

        # Remove from rec_stack
        local new_stack=()
        for r in "${rec_stack[@]}"; do
            if [[ "$r" != "$node" ]]; then
                new_stack+=("$r")
            fi
        done
        rec_stack=("${new_stack[@]}")
        return 1
    }

    for tid in "${!all_tasks[@]}"; do
        local in_visited=0
        for v in "${visited[@]}"; do
            if [[ "$v" == "$tid" ]]; then
                in_visited=1
                break
            fi
        done
        if [[ "$in_visited" -eq 0 ]]; then
            if _plan_check_has_cycle "$tid"; then
                _plan_check_next_fid
                local fid="$_PLAN_CHECK_LAST_FID"
                local finding
                finding="$(_plan_check_build_finding \
                    "$fid" "blocker" "dependency" "plan-schema-validator" \
                    "Task Breakdown" "$tid" \
                    "Circular dependency detected starting from task '$tid'." \
                    "Tasks form a cycle in their dependency graph, making it impossible to determine an execution order." \
                    "Break the cycle by removing at least one dependency or restructuring tasks." \
                    "[]" "$(_plan_check_json_array "$tid")")"
                _plan_check_append_finding "$findings_file" "$finding"
            fi
        fi
    done
}

# Check for drift between main plan and original draft appendix.
# Usage: plan_check_check_appendix_drift <plan_path> <findings_file>
plan_check_check_appendix_drift() {
    local plan_path="$1"
    local findings_file="$2"

    # Check if appendix markers exist
    if ! grep -qF -- "--- Original Design Draft Start ---" "$plan_path" 2>/dev/null; then
        return 0
    fi

    if ! grep -qF -- "--- Original Design Draft End ---" "$plan_path" 2>/dev/null; then
        _plan_check_next_fid
        local fid="$_PLAN_CHECK_LAST_FID"
        local finding
        finding="$(_plan_check_build_finding \
            "$fid" "info" "appendix-drift" "plan-schema-validator" \
            "Appendix" "" \
            "Appendix start marker found but no end marker." \
            "The original draft appendix section is malformed, making drift detection impossible." \
            "Add the '--- Original Design Draft End ---' marker or remove the start marker." \
            "[]" "[]")"
        _plan_check_append_finding "$findings_file" "$finding"
        return 0
    fi

    # This is a simplified drift check: we just note that an appendix exists
    # A more thorough check would compare section content, but that requires
    # semantic comparison beyond the scope of deterministic validation.
    _plan_check_next_fid
    local fid="$_PLAN_CHECK_LAST_FID"
    local finding
    finding="$(_plan_check_build_finding \
        "$fid" "info" "appendix-drift" "plan-schema-validator" \
        "Appendix" "" \
        "Original draft appendix section is present." \
        "An appendix section exists. Reviewers should verify that the main plan has not diverged from the original draft in ways that invalidate design decisions." \
        "Review the appendix and main plan for inconsistencies." \
        "[]" "[]")"
    _plan_check_append_finding "$findings_file" "$finding"
}

# Main schema validation entry point.
# Outputs a comma-separated list of JSON finding objects.
# Usage: plan_check_validate_schema <plan_path> [template_path]
plan_check_validate_schema() {
    local plan_path="$1"
    local template_path="${2:-}"
    local all_findings=""

    # Reset global counter
    _PLAN_CHECK_FID_COUNTER=0

    # Check if template path is provided and readable
    if [[ -n "$template_path" && ! -f "$template_path" ]]; then
        _plan_check_next_fid
        local fid="$_PLAN_CHECK_LAST_FID"
        all_findings="$(_plan_check_build_finding \
            "$fid" "info" "runtime-error" "plan-schema-validator" \
            "" "" \
            "Canonical schema source not found: $template_path" \
            "The canonical gen-plan template is unavailable or malformed. Schema validation is skipped; only semantic review will be performed." \
            "Ensure prompt-template/plan/gen-plan-template.md exists and is readable." \
            "[]" "[]")"
        printf '%s' "$all_findings"
        return 0
    fi

    local findings_file
    findings_file="$(mktemp)"

    # Parse required sections from canonical template if available
    local parsed_sections=()
    local template_malformed=0
    if [[ -n "$template_path" && -f "$template_path" ]]; then
        local parsed
        if parsed="$(_plan_check_parse_schema_template "$template_path" 2>/dev/null)" && [[ -n "$parsed" ]]; then
            while IFS= read -r sec; do
                [[ -n "$sec" ]] && parsed_sections+=("$sec")
            done <<< "$parsed"
        else
            template_malformed=1
        fi
    fi

    # If template is malformed, emit runtime-error finding and skip deterministic schema checks
    if [[ "$template_malformed" -eq 1 ]]; then
        _plan_check_next_fid
        local fid="$_PLAN_CHECK_LAST_FID"
        local finding
        finding="$(_plan_check_build_finding \
            "$fid" "info" "runtime-error" "plan-schema-validator" \
            "" "" \
            "Canonical schema source is malformed or unparseable: $template_path" \
            "The canonical gen-plan template does not contain the required core schema markers. Deterministic schema validation is skipped; only semantic review will be performed." \
            "Ensure prompt-template/plan/gen-plan-template.md is a valid plan template with the required core sections." \
            "[]" "[]")"
        _plan_check_append_finding "$findings_file" "$finding"
    else
        # Run each validator (direct calls, no subshell, so counter increments persist)
        if [[ ${#parsed_sections[@]} -gt 0 ]]; then
            plan_check_validate_required_sections "$plan_path" "$findings_file" "${parsed_sections[@]}"
        else
            plan_check_validate_required_sections "$plan_path" "$findings_file"
        fi
        plan_check_validate_ac_ids "$plan_path" "$findings_file"
        plan_check_validate_target_acs "$plan_path" "$findings_file"
        plan_check_validate_task_tags "$plan_path" "$findings_file"
        plan_check_validate_dependencies "$plan_path" "$findings_file"
        plan_check_check_appendix_drift "$plan_path" "$findings_file"
    fi

    # Combine findings from file
    while IFS= read -r finding; do
        [[ -z "$finding" ]] && continue
        if [[ -z "$all_findings" ]]; then
            all_findings="$finding"
        else
            all_findings="$all_findings,$finding"
        fi
    done < "$findings_file"

    rm -f "$findings_file"
    printf '%s' "$all_findings"
}

# ========================================
# Config Resolution
# ========================================

# Resolve the canonical schema template path.
plan_check_resolve_schema_template() {
    local plugin_root="${1:-}"
    if [[ -n "$plugin_root" ]]; then
        local path="$plugin_root/prompt-template/plan/gen-plan-template.md"
        if [[ -f "$path" ]]; then
            printf '%s\n' "$path"
            return 0
        fi
    fi
    # Fallback to script-relative path
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
    local path="$script_dir/../../prompt-template/plan/gen-plan-template.md"
    if [[ -f "$path" ]]; then
        printf '%s\n' "$path"
        return 0
    fi
    return 1
}

# Resolve alt-language code from merged config.
plan_check_resolve_alt_language() {
    local merged_config="$1"
    if [[ -z "$merged_config" ]]; then
        printf ''
        return 0
    fi
    printf '%s' "$merged_config" | jq -r '.alternative_plan_language // empty'
}

# Resolve whether plan-check should re-run after an accepted rewrite.
plan_check_resolve_recheck() {
    local merged_config="$1"
    if [[ -z "$merged_config" ]]; then
        printf 'false'
        return 0
    fi

    printf '%s' "$merged_config" | jq -r '
        if has("plan_check_recheck") then
            .plan_check_recheck
            | if type == "boolean" then tostring
              elif type == "string" then ascii_downcase
              else "false"
              end
            | if . == "true" or . == "false" then . else "false" end
        else
            "false"
        end
    '
}
